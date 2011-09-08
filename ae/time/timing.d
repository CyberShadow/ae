/* ***** BEGIN LICENSE BLOCK *****
 * Version: MPL 1.1/GPL 3.0
 *
 * The contents of this file are subject to the Mozilla Public License Version
 * 1.1 (the "License"); you may not use this file except in compliance with
 * the License. You may obtain a copy of the License at
 * http://www.mozilla.org/MPL/
 *
 * Software distributed under the License is distributed on an "AS IS" basis,
 * WITHOUT WARRANTY OF ANY KIND, either express or implied. See the License
 * for the specific language governing rights and limitations under the
 * License.
 *
 * The Original Code is the Team15 library.
 *
 * The Initial Developer of the Original Code is
 * Simon Arlott
 * Portions created by the Initial Developer are Copyright (C) 2007-2010
 * the Initial Developer. All Rights Reserved.
 *
 * Contributor(s):
 *   Vladimir Panteleev <vladimir@thecybershadow.net>
 *
 * Alternatively, the contents of this file may be used under the terms of the
 * GNU General Public License Version 3 (the "GPL") or later, in which case
 * the provisions of the GPL are applicable instead of those above. If you
 * wish to allow use of your version of this file only under the terms of the
 * GPL, and not to allow others to use your version of this file under the
 * terms of the MPL, indicate your decision by deleting the provisions above
 * and replace them with the notice and other provisions required by the GPL.
 * If you do not delete the provisions above, a recipient may use your version
 * of this file under the terms of either the MPL or the GPL.
 *
 * ***** END LICENSE BLOCK ***** */

/// Management of timed events.
module ae.time.timing;

import std.exception;
import core.time;

// TODO: allow customization of timing mechanism (alternatives to TickDuration)?

public import core.time : TickDuration;

static this()
{
	enforce(TickDuration.ticksPerSec != 0, "TickDuration not available on this system");
}

final class Timer
{
private:
	TimerTask head;
	TimerTask tail;
	size_t count;

	this() {}

	void add(TimerTask task, TimerTask start)
	{
		auto now = TickDuration.currSystemTick();

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

public:
	/// Run scheduled tasks.
	void prod()
	{
		auto now = TickDuration.currSystemTick();

		if (head !is null)
		{
			while (head !is null && head.when <= now)
			{
				TimerTask task = head;
				remove(head);
				debug (TIMER) writefln("%d: Firing a task that waited for %d of %d tick%s.", now, head.delay + (now - head.when), task.delay, task.delay.length==1?"":"s");
				if (task.handleTask)
					task.handleTask(this, task);
			}

			debug (TIMER_VERBOSE) if (head !is null) writefln("Current task is waiting for %d tick%s, %d remaining.", head.delay, head.delay==1?"":"s", head.when - now);
		}
	}

	/// Add a new task to the timer.
	void add(TimerTask task)
	{
		debug (TIMER_VERBOSE) writefln("Adding a task which waits for %d tick%s.", task.delay, task.delay==1?"":"s");
		assert(task.owner is null);
		add(task, null);
		assert(task.owner is this);
		assert(head !is null);
	}

	/// Reschedule a task to run with the same delay from now.
	void restart(TimerTask task)
	{
		TimerTask tmp;

		assert(task.owner is this);
		debug (TIMER_VERBOSE) writefln("Restarting a task which waits for %d tick%s.", task.delay, task.delay==1?"":"s");

		// Store current position, as the new position must be after it
		tmp = task.next !is null ? task.next : task.prev;

		remove(task);
		assert(task.owner is null);

		add(task, tmp);
		assert(task.owner is this);
	}

	/// Unschedule a task.
	void remove(TimerTask task)
	{
		debug (TIMER_VERBOSE) writefln("Removing a task which waits for %d tick%s.", task.delay, task.delay==1?"":"s");
		assert(task.owner is this);
		if (task is head)
		{
			if (head.next)
			{
				head = head.next;
				head.prev = null;
				debug (TIMER_VERBOSE) writefln("Removed current task, next task is waiting for %d tick%s, %d remaining.", head.delay, head.delay==1?"":"s", head.remaining);
			}
			else
			{
				debug (TIMER_VERBOSE) writefln("Removed last task.");
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

	/// Return true if there are pending tasks scheduled.
	bool isWaiting()
	{
		return head !is null;
	}

	/// Return the time until the first scheduled task, or TickDuration(long.max) if no tasks are scheduled.
	TickDuration getRemainingTime()
	{
		if (head is null)
			return TickDuration(long.max);

		auto now = TickDuration.currSystemTick();
		if (now < head.when)
			return head.when - now;
		else
			return TickDuration(0);
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
			TimerTask t = head;
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

final class TimerTask
{
private:
	Timer owner;
	TimerTask prev;
	TimerTask next;

	TickDuration when;
	TickDuration _delay;

	alias void delegate(Timer timer, TimerTask task) Handler;

public:
	this(TickDuration delay, Handler handler = null)
	{
		assert(delay.length >= 0);
		_delay = delay;
		handleTask = handler;
	}

	/// Return whether the task is scheduled to run on a Timer.
	bool isWaiting()
	{
		return owner !is null;
	}

	@property TickDuration delay()
	{
		return _delay;
	}

	@property void delay(TickDuration delay)
	{
		assert(delay.length >= 0);
		assert(owner is null);
		_delay = delay;
	}

	Handler handleTask;
}

/// The default timer
Timer mainTimer;

static this()
{
	mainTimer = new Timer();
}
