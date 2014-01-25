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
 *   Vladimir Panteleev <vladimir@thecybershadow.net>
 */

module ae.ui.timer.thread.timer;

import core.thread;
import core.sync.semaphore;

public import ae.ui.timer.timer;
import ae.ui.app.application;
import ae.sys.timing;

alias ae.sys.timing.Timer SysTimer;
alias ae.ui.timer.timer.Timer Timer;

final class ThreadTimer : Timer
{
    SysTimer sysTimer;
    Semaphore semaphore;
    shared bool prodding;

    this()
    {
    	sysTimer = new SysTimer;
    	semaphore = new Semaphore;
		auto thread = new Thread(&threadProc);
		thread.isDaemon = true;
		thread.start();
    }

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
				prodding = true;
				sysTimer.prod();
				prodding = false;
				remainingTime = sysTimer.getRemainingTime();
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

		this(AppCallback fn, uint ms, bool recurring)
		{
			this.fn = fn;
			this.recurring = recurring;
			this.task = new TimerTask(ms.msecs, &taskCallback);
			synchronized(sysTimer)
				sysTimer.add(task);
		}

		void taskCallback(SysTimer timer, TimerTask task)
		{
			if (recurring)
				timer.add(task);
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
