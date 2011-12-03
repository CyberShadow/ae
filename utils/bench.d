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
 * Vladimir Panteleev <vladimir@thecybershadow.net>
 * Portions created by the Initial Developer are Copyright (C) 2007-2011
 * the Initial Developer. All Rights Reserved.
 *
 * Contributor(s):
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

/// Simple benchmarking/profiling code
module ae.utils.bench;

import std.datetime;

TickDuration lastTime;

static this()
{
	lastTime = TickDuration.currSystemTick();
}

TickDuration elapsedTime()
{
	auto c = TickDuration.currSystemTick();
	auto d = c - lastTime;
	lastTime = c;
	return d;
}

struct TimedAction
{
	string name;
	TickDuration duration;

	@property long ticks() { return duration.length; }
}

TimedAction[] timedActions;
size_t[string] timeNameIndices;
string currentAction = null;

void timeEnd(string action = null)
{
	if (action && currentAction && action != currentAction)
		action = currentAction ~ " / " ~ action;
	if (action is null)
		action = currentAction;
	if (action is null)
		action = "other";
	currentAction = null;

	// ordered
	if (action !in timeNameIndices)
	{
		timeNameIndices[action] = timedActions.length;
		timedActions ~= TimedAction(action, elapsedTime());
	}
	else
		timedActions[timeNameIndices[action]].duration += elapsedTime();
}


void timeStart(string action = null)
{
	timeEnd();
	currentAction = action;
}

void timeAction(string action, void delegate() p)
{
	timeStart(action);
	p();
	timeEnd(action);
}

void clearTimes()
{
	timedActions = null;
	timeNameIndices = null;
	lastTime = TickDuration.currSystemTick();
}

/// Retrieves current times and clears them.
string getTimes()()
{
	timeEnd();

	import std.string, std.array;
	string[] lines;
	int maxLength;
	foreach (action; timedActions)
		if (action.ticks)
			if (maxLength < action.name.length)
				maxLength = action.name.length;
	string fmt = format("%%%ds : %%10d (%%s)", maxLength);
	foreach (action; timedActions)
		if (action.ticks)
			lines ~= format(fmt, action.name, action.ticks, dur!"hnsecs"(action.ticks));
	clearTimes();
	return join(lines, "\n");
}

void dumpTimes()()
{
	import std.stdio;
	import ae.sys.console;
	auto times = getTimes();
	if (times.length)
		writeln(times);
}

private string[] timeStack;

void timePush(string action = null)
{
	timeStack ~= currentAction;
	timeStart(action);
}

void timePop(string action = null)
{
	timeEnd(action);
	timeStart(timeStack[$-1]);
	timeStack = timeStack[0..$-1];
}
