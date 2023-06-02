/**
 * ae.ui.timer.thread.timer
 *
 * License:
 *   This Source Code Form is subject to the terms of
 *   the Mozilla Public License, v. 2.0. If a copy of
 *   the MPL was not distributed with this file, You
 *   can obtain one at http://mozilla.org/MPL/2.0/.
 *
 * Authors:
 *   Vladimir Panteleev <ae@cy.md>
 */

module ae.ui.timer.thread.timer;

import core.thread;
import core.sync.semaphore;

public import ae.ui.timer.timer;
import ae.ui.app.application;
import ae.sys.timing;

private alias ae.sys.timing.Timer SysTimer;
private alias ae.ui.timer.timer.Timer Timer;

/// A simple thread-based `Timer` implementation.
final class ThreadTimer : Timer
{
    this()
    {
    	sysTimer = new SysTimer;
    	semaphore = new Semaphore;
		auto thread = new Thread(&threadProc);
		thread.isDaemon = true;
		thread.start();
    } ///

protected:
    SysTimer sysTimer;
    Semaphore semaphore;
    shared bool prodding;

	override TimerEvent setTimeout (AppCallback fn, uint ms) { return new ThreadTimerEvent(fn, ms, false); }
	override TimerEvent setInterval(AppCallback fn, uint ms) { return new ThreadTimerEvent(fn, ms, true ); }

private:
	void threadProc()
	{
		while (true)
		{
			Duration remainingTime;

			synchronized(sysTimer)
			{
                auto now = MonoTime.currTime();
				prodding = true;
				sysTimer.prod(now);
				prodding = false;

                now = MonoTime.currTime();
				remainingTime = sysTimer.getRemainingTime(now);
			}

			if (remainingTime == Duration.max)
				semaphore.wait();
			else
				semaphore.wait(remainingTime);
		}
	}

	final class ThreadTimerEvent : TimerEvent
	{
		AppCallback fn;
		bool recurring;
		TimerTask task;
        uint ms;

		this(AppCallback fn, uint ms, bool recurring)
		{
			auto now = MonoTime.currTime();
			this.fn = fn;
            this.ms = ms;
			this.recurring = recurring;
			this.task = new TimerTask(&taskCallback);
            synchronized(sysTimer)
				sysTimer.add(task, now + ms.msecs);
		}

		void taskCallback(SysTimer timer, TimerTask task)
		{
			if (recurring)
            {
                auto now = MonoTime.currTime();
				timer.add(task, now + ms.msecs);
            }
			fn.call();
		}

		override void cancel()
		{
			if (prodding) // cancel called from timer event handler, synchronization would cause a deadlock
				task.cancel();
			else
			synchronized(sysTimer)
				task.cancel();
		}
	}
}
