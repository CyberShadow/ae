/**
 * Management of timed events.
 *
 * License:
 *   This Source Code Form is subject to the terms of
 *   the Mozilla Public License, v. 2.0. If a copy of
 *   the MPL was not distributed with this file, You
 *   can obtain one at http://mozilla.org/MPL/2.0/.
 *
 * Authors:
 *   Simon Arlott
 *   Vladimir Panteleev <ae@cy.md>
 */

module ae.sys.timing;

public import core.time;

import std.exception;

/// Prototype for core.time.MonoTime (TickDuration replacement).
/// See https://github.com/D-Programming-Language/druntime/pull/711
static if (!is(core.time.MonoTime))
{
	deprecated struct MonoTime
	{
		enum max = MonoTime(ulong.max);

		static MonoTime currTime()
		{
			return MonoTime(TickDuration.currSystemTick().hnsecs);
		}

		MonoTime opBinary(string op)(Duration d) const
			if (op == "+")
		{
			return MonoTime(hnsecs + d.total!"hnsecs");
		}

		Duration opBinary(string op)(MonoTime o) const
			if (op == "-")
		{
			return dur!"hnsecs"(cast(long)(hnsecs - o.hnsecs));
		}

		int opCmp(MonoTime o) const { return hnsecs == o.hnsecs ? 0 : hnsecs > o.hnsecs ? 1 : -1; }

	private:
		ulong hnsecs;
	}
}

unittest
{
	assert(MonoTime.init < MonoTime.max);
}

// TODO: allow customization of timing mechanism (alternatives to TickDuration)?

debug(TIMER) import std.stdio : stderr;
debug(TIMER_TRACK) import std.stdio : stderr;
debug(TIMER_TRACK) import ae.utils.exception;

static this()
{
	// Bug 6631
	//enforce(TickDuration.ticksPerSec != 0, "TickDuration not available on this system");
}

/// Manages and schedules a list of timer tasks.
final class Timer
{
private:
	TimerTask head;
	TimerTask tail;
	size_t count;

	void add(TimerTask task, TimerTask start)
	{
		debug(TIMER_VERBOSE) stderr.writefln("Adding task %s which waits for %s.", cast(void*)task, task.delay);
		debug(TIMER_TRACK) task.additionStackTrace = getStackTrace();

		auto now = MonoTime.currTime();

		if (start !is null)
			assert(start.owner is this);

		task.owner = this;
		task.prev = null;
		task.next = null;
		task.when = now + task.delay;

		TimerTask tmp = start is null ? head : start;

		while (tmp !is null)
		{
			if (task.when < tmp.when)
			{
				task.next = tmp;
				task.prev = tmp.prev;
				if (tmp.prev)
					tmp.prev.next = task;
				tmp.prev = task;
				break;
			}
			tmp = tmp.next;
		}

		if (tmp is null)
		{
			if (head !is null)
			{
				tail.next = task;
				task.prev = tail;
				tail = task;
			}
			else
			{
				head = task;
				tail = task;
			}
		}
		else
		if (tmp is head)
			head = task;

		assert(head is null || head.prev is null);
		assert(tail is null || tail.next is null);
		count++;
	}

	/// Unschedule a task.
	void remove(TimerTask task)
	{
		debug (TIMER_VERBOSE) stderr.writefln("Removing task %s which waits for %s.", cast(void*)task, task.delay);
		assert(task.owner is this);
		if (task is head)
		{
			if (head.next)
			{
				head = head.next;
				head.prev = null;
				debug (TIMER_VERBOSE) stderr.writefln("Removed current task, next task is waiting for %s (next at %s).", head.delay, head.when);
			}
			else
			{
				debug (TIMER_VERBOSE) stderr.writefln("Removed last task.");
				assert(tail is task);
				head = tail = null;
			}
		}
		else
		if (task is tail)
		{
			tail = task.prev;
			if (tail)
				tail.next = null;
		}
		else
		{
			TimerTask tmp = task.prev;
			if (task.prev)
				task.prev.next = task.next;
			if (task.next)
			{
				task.next.prev = task.prev;
				task.next = tmp;
			}
		}
		task.owner = null;
		task.next = task.prev = null;
		count--;
	}

	void restart(TimerTask task)
	{
		TimerTask tmp;

		assert(task.owner !is null, "This TimerTask is not active");
		assert(task.owner is this, "This TimerTask is not owned by this Timer");
		debug (TIMER_VERBOSE) stderr.writefln("Restarting task %s which waits for %s.", cast(void*)task, task.delay);

		// Store current position, as the new position must be after it
		tmp = task.next !is null ? task.next : task.prev;

		remove(task);
		assert(task.owner is null);

		add(task, tmp);
		assert(task.owner is this);
	}

public:
	/// Pretend there are no tasks scheduled.
	bool disabled;

	/// Run scheduled tasks.
	/// Returns true if any tasks ran.
	bool prod()
	{
		if (disabled) return false;

		auto now = MonoTime.currTime();

		bool ran;

		if (head !is null)
		{
			while (head !is null && head.when <= now)
			{
				TimerTask task = head;
				remove(head);
				debug (TIMER) stderr.writefln("%s: Firing task %s that waited for %s of %s.", now, cast(void*)task, task.delay + (now - task.when), task.delay);
				if (task.handleTask)
					task.handleTask(this, task);
				ran = true;
			}

			debug (TIMER_VERBOSE) if (head !is null) stderr.writefln("Current task is waiting for %s, %s remaining.", head.delay, head.when - now);
		}

		return ran;
	}

	/// Add a new task to the timer.
	void add(TimerTask task)
	{
		debug (TIMER_VERBOSE) stderr.writefln("Adding task %s which waits for %s.", cast(void*)task, task.delay);
		assert(task.owner is null, "This TimerTask is already active");
		add(task, null);
		assert(task.owner is this);
		assert(head !is null);
	}

	/// Return true if there are pending tasks scheduled.
	bool isWaiting()
	{
		return !disabled && head !is null;
	}

	/// Return the MonoTime of the next scheduled task, or MonoTime.max if no tasks are scheduled.
	MonoTime getNextEvent()
	{
		return disabled || head is null ? MonoTime.max : head.when;
	}

	/// Return the time until the first scheduled task, or Duration.max if no tasks are scheduled.
	Duration getRemainingTime()
	{
		if (disabled || head is null)
			return Duration.max;

		auto now = MonoTime.currTime();

		debug(TIMER) stderr.writefln("First task is %s, due to fire in %s", cast(void*)head, head.when - now);
		debug(TIMER_TRACK) stderr.writefln("\tCreated:\n\t\t%-(%s\n\t\t%)\n\tAdded:\n\t\t%-(%s\n\t\t%)",
			head.creationStackTrace, head.additionStackTrace);

		if (now < head.when) // "when" is in the future
			return head.when - now;
		else
			return Duration.zero;
	}

	debug invariant()
	{
		if (head is null)
		{
			assert(tail is null);
			assert(count == 0);
		}
		else
		{
			TimerTask t = cast(TimerTask)head;
			assert(t.prev is null);
			int n=1;
			while (t.next)
			{
				assert(t.owner is this);
				auto next = t.next;
				assert(t is next.prev);
				assert(t.when <= next.when);
				t = next;
				n++;
			}
			assert(t.owner is this);
			assert(t is tail);
			assert(count == n);
		}
	}
}

/// Represents a task that needs to run at some point in the future.
final class TimerTask
{
private:
	Timer owner;
	TimerTask prev;
	TimerTask next;

	MonoTime when;
	Duration _delay;

	debug(TIMER_TRACK) string[] creationStackTrace, additionStackTrace;

public:
	this(Duration delay, Handler handler = null)
	{
		assert(delay >= Duration.zero, "Creating TimerTask with a negative Duration");
		_delay = delay;
		handleTask = handler;
		debug(TIMER_TRACK) creationStackTrace = getStackTrace();
	} ///

	/// Return whether the task is scheduled to run on a Timer.
	bool isWaiting()
	{
		return owner !is null;
	}

	/// Remove this task from the scheduler.
	void cancel()
	{
		assert(isWaiting(), "This TimerTask is not active");
		owner.remove(this);
		assert(!isWaiting());
	}

	/// Reschedule the task to run with the same delay from now.
	void restart()
	{
		assert(isWaiting(), "This TimerTask is not active");
		owner.restart(this);
		assert(isWaiting());
	}

	/// The duration that this task is scheduled to run after.
	/// Changing the delay is only allowed for inactive tasks.
	@property Duration delay()
	{
		return _delay;
	}

	/// ditto
	@property void delay(Duration delay)
	{
		assert(delay >= Duration.zero, "Setting TimerTask delay to a negative Duration");
		assert(owner is null, "Changing duration of an active TimerTask");
		_delay = delay;
	}

	/// Called when this timer task fires.
	alias Handler = void delegate(Timer timer, TimerTask task);
	Handler handleTask; /// ditto
}

/// The default timer
Timer mainTimer;

static this()
{
	mainTimer = new Timer();
}

// ********************************************************************************************************************

/// Convenience function to schedule and return a `TimerTask` that runs `handler` after `delay` once.
TimerTask setTimeout(Args...)(void delegate(Args) handler, Duration delay, Args args)
{
	auto task = new TimerTask(delay, (Timer timer, TimerTask task) { handler(args); });
	mainTimer.add(task);
	return task;
}

/// Convenience function to schedule and return a `TimerTask` that runs `handler` after `delay` repeatedly.
TimerTask setInterval(Args...)(void delegate(Args) handler, Duration delay, Args args)
{
	auto task = new TimerTask(delay, (Timer timer, TimerTask task) { mainTimer.add(task); handler(args); });
	mainTimer.add(task);
	return task;
}

/// Calls `task.cancel`.
void clearTimeout(TimerTask task)
{
	task.cancel();
}

// ********************************************************************************************************************

/// Used to throttle actions to happen no more often than a certain period.
/// If last was less that span ago, return false.
/// Otherwise, update last to the current time and return true.
bool throttle(ref MonoTime last, Duration span)
{
	MonoTime now = MonoTime.currTime();
	auto elapsed = now - last;
	if (elapsed < span)
		return false;
	else
	{
		last = now;
		return true;
	}
}

// http://d.puremagic.com/issues/show_bug.cgi?id=7016
version(unittest) static import ae.utils.array;

unittest
{
	import ae.utils.array;
	import core.thread;

	MonoTime[string] lastNag;
	assert( lastNag.getOrAdd("cheese").throttle(10.msecs));
	assert(!lastNag.getOrAdd("cheese").throttle(10.msecs));
	Thread.sleep(20.msecs);
	assert( lastNag.getOrAdd("cheese").throttle(10.msecs));
	assert(!lastNag.getOrAdd("cheese").throttle(10.msecs));
}
