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

debug(TIMER_VERBOSE) debug = TIMER;
debug(TIMER) import std.stdio : stderr;
debug(TIMER_TRACK) import std.stdio : stderr;
debug(TIMER_TRACK) import ae.utils.exception;

/// Manages and schedules a list of timer tasks.
final class Timer
{
private:
	TimerTask head;
	TimerTask tail;
	size_t count;

	/// State to store in `TimerTask` instances.
	/// It is private to `Timer`.
	struct TimerTaskState
	{
		TimerTask prev;
		TimerTask next;

		MonoTime when;
	}

	void add(TimerTask task, TimerTask start, MonoTime when) pure
	{
		debug(TIMER_VERBOSE) stderr.writefln("Adding task %s which fires at %s.", cast(void*)task, task.state.when);
		debug(TIMER_TRACK) task.additionStackTrace = getStackTrace();

		if (start !is null)
			assert(start.owner is this);

		task.owner = this;
		task.state.prev = null;
		task.state.next = null;
		task.state.when = when;

		TimerTask tmp = start is null ? head : start;

		while (tmp !is null)
		{
			if (task.state.when < tmp.state.when)
			{
				task.state.next = tmp;
				task.state.prev = tmp.state.prev;
				if (tmp.state.prev)
					tmp.state.prev.state.next = task;
				tmp.state.prev = task;
				break;
			}
			tmp = tmp.state.next;
		}

		if (tmp is null)
		{
			if (head !is null)
			{
				tail.state.next = task;
				task.state.prev = tail;
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

		assert(head is null || head.state.prev is null);
		assert(tail is null || tail.state.next is null);
		count++;
	}

	/// Unschedule a task.
	void remove(TimerTask task) pure
	{
		debug (TIMER_VERBOSE) stderr.writefln("Removing task %s which fires at %s.", cast(void*)task, task.state.when);
		assert(task.owner is this);
		if (task is head)
		{
			if (head.state.next)
			{
				head = head.state.next;
				head.state.prev = null;
				debug (TIMER_VERBOSE) stderr.writefln("Removed current task, next task fires at %s.", head.state.when);
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
			tail = task.state.prev;
			if (tail)
				tail.state.next = null;
		}
		else
		{
			TimerTask tmp = task.state.prev;
			if (task.state.prev)
				task.state.prev.state.next = task.state.next;
			if (task.state.next)
			{
				task.state.next.state.prev = task.state.prev;
				task.state.next = tmp;
			}
		}
		task.owner = null;
		task.state.next = task.state.prev = null;
		count--;
	}

	/// Same as, and slightly more optimal than `remove` + `add` when `newTime` >= `task.state.when`.
	void restart(TimerTask task, MonoTime newTime) pure
	{
		assert(task.owner !is null, "This TimerTask is not active");
		assert(task.owner is this, "This TimerTask is not owned by this Timer");
		debug (TIMER_VERBOSE) stderr.writefln("Restarting task %s which fires at %s.", cast(void*)task, task.state.when);


		TimerTask oldPosition;
		if (newTime >= task.state.when)
		{
			// Store current position, as the new position must be after it.
			oldPosition = task.state.next !is null ? task.state.next : task.state.prev;
		}

		remove(task);
		assert(task.owner is null);

		add(task, oldPosition, newTime);
		assert(task.owner is this);
	}

public:
	/// Pretend there are no tasks scheduled.
	bool disabled;

	/// Run scheduled tasks.
	/// Returns true if any tasks ran.
	bool prod(MonoTime now)
	{
		if (disabled) return false;

		bool ran;

		if (head !is null)
		{
			while (head !is null && head.state.when <= now)
			{
				TimerTask task = head;
				remove(head);
				debug (TIMER) stderr.writefln("%s: Firing task %s that wanted to fire at %s.", now, cast(void*)task, task.state.when);
				if (task.handleTask)
					task.handleTask(this, task);
				ran = true;
			}

			debug (TIMER_VERBOSE) if (head !is null) stderr.writefln("Current task wants to fire at %s, %s remaining.", head.state.when, head.state.when - now);
		}

		return ran;
	}

	deprecated bool prod()
	{
		return prod(MonoTime.currTime());
	}

	// Add a new task to the timer, based on its `delay`.
	deprecated void add(TimerTask task)
	{
		add(task, MonoTime.currTime() + task.delay);
	}

	// Add a new task to the timer.
	void add(TimerTask task, MonoTime when) pure
	{
		debug (TIMER_VERBOSE) stderr.writefln("Adding task %s which fires at %s.", cast(void*)task, task.state.when);
		assert(task.owner is null, "This TimerTask is already active");
		add(task, null, when);
		assert(task.owner is this);
		assert(head !is null);
	}

	/// Return true if there are pending tasks scheduled.
	bool isWaiting() pure
	{
		return !disabled && head !is null;
	}

	/// Return the MonoTime of the next scheduled task, or MonoTime.max if no tasks are scheduled.
	MonoTime getNextEvent() pure
	{
		return disabled || head is null ? MonoTime.max : head.state.when;
	}

	/// Return the time until the first scheduled task, or Duration.max if no tasks are scheduled.
	Duration getRemainingTime(MonoTime now) pure
	{
		if (disabled || head is null)
			return Duration.max;

		debug(TIMER) stderr.writefln("First task is %s, due to fire in %s", cast(void*)head, head.state.when - now);
		debug(TIMER_TRACK) stderr.writefln("\tCreated:\n\t\t%-(%s\n\t\t%)\n\tAdded:\n\t\t%-(%s\n\t\t%)",
			head.creationStackTrace, head.additionStackTrace);

		if (now < head.state.when) // "when" is in the future
			return head.state.when - now;
		else
			return Duration.zero;
	}

	deprecated Duration getRemainingTime()
	{
		return getRemainingTime(MonoTime.currTime());
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
			assert(t.state.prev is null);
			int n=1;
			while (t.state.next)
			{
				assert(t.owner is this);
				auto next = t.state.next;
				assert(t is next.state.prev);
				assert(t.state.when <= next.state.when);
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
	Timer.TimerTaskState state;
	deprecated Duration _delay;

	debug(TIMER_TRACK) string[] creationStackTrace, additionStackTrace;

public:
	this(Handler handler = null) pure
	{
		handleTask = handler;
		debug(TIMER_TRACK) creationStackTrace = getStackTrace();
	} ///

	deprecated this(Duration delay, Handler handler = null)
	{
		assert(delay >= Duration.zero, "Creating TimerTask with a negative Duration");
		_delay = delay;
		this(handler);
	} ///

	/// Return whether the task is scheduled to run on a Timer.
	bool isWaiting() pure const
	{
		return owner !is null;
	}

	/// Remove this task from the scheduler.
	void cancel() pure
	{
		assert(isWaiting(), "This TimerTask is not active");
		owner.remove(this);
		assert(!isWaiting());
	}

	/// Reschedule the task to run at some other time.
	void restart(MonoTime when) pure
	{
		assert(isWaiting(), "This TimerTask is not active");
		owner.restart(this, when);
		assert(isWaiting());
	}

	/// Reschedule the task to run with the same delay from now.
	deprecated void restart()
	{
		restart(MonoTime.currTime() + delay);
	}

	/// The duration that this task is scheduled to run after.
	/// Changing the delay is only allowed for inactive tasks.
	deprecated @property Duration delay() const
	{
		return _delay;
	}

	/// ditto
	deprecated @property void delay(Duration delay)
	{
		assert(delay >= Duration.zero, "Setting TimerTask delay to a negative Duration");
		assert(owner is null, "Changing duration of an active TimerTask");
		_delay = delay;
	}

	@property MonoTime when() pure const
	{
		assert(isWaiting(), "This TimerTask is not active");
		return state.when;
	}

	/// Called when this timer task fires.
	alias Handler = void delegate(Timer timer, TimerTask task);
	Handler handleTask; /// ditto
}

/// The default timer
@property Timer mainTimer()
{
	static Timer instance;
	if (!instance)
		instance = new Timer();
	return instance;
}

// ********************************************************************************************************************

/// Convenience function to schedule and return a `TimerTask` that runs `handler` after `delay` once.
TimerTask setTimeout(Args...)(void delegate(Args) handler, Duration delay, Args args)
{
	auto task = new TimerTask((Timer /*timer*/, TimerTask task) {
		handler(args);
	});
	mainTimer.add(task, MonoTime.currTime() + delay);
	return task;
}

/// Convenience function to schedule and return a `TimerTask` that runs `handler` after `delay` repeatedly.
TimerTask setInterval(Args...)(void delegate(Args) handler, Duration delay, Args args)
{
	auto task = new TimerTask((Timer /*timer*/, TimerTask task) {
		mainTimer.add(task, MonoTime.currTime() + delay);
		handler(args);
	});
	mainTimer.add(task, MonoTime.currTime() + delay);
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

// https://issues.dlang.org/show_bug.cgi?id=7016
version(ae_unittest) static import ae.utils.array;

version(ae_unittest) unittest
{
	import core.thread : Thread;

	MonoTime[string] lastNag;
	assert( lastNag.require("cheese").throttle(10.msecs));
	assert(!lastNag.require("cheese").throttle(10.msecs));
	Thread.sleep(20.msecs);
	assert( lastNag.require("cheese").throttle(10.msecs));
	assert(!lastNag.require("cheese").throttle(10.msecs));
}
