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

SysTime lastTime;

static this()
{
	lastTime = Clock.currTime();
}

Duration elapsedTime()
{
	auto c = Clock.currTime();
	auto d = c - lastTime;
	lastTime = c;
	return d;
}

struct TimedAction
{
	string name;
	Duration duration;
}

TimedAction[] timedActions;
size_t[string] timeNameIndices;

void timeEnd(string action)
{
	// ordered
	if (action !in timeNameIndices)
	{
		timeNameIndices[action] = timedActions.length;
		timedActions ~= TimedAction(action, elapsedTime());
	}
	else
		timedActions[timeNameIndices[action]].duration += elapsedTime();
}

void timeStart()
{
	timeEnd("other");
}

void timeAction(string action, void delegate() p)
{
	timeStart();
	p();
	timeEnd(action);
}

void clearTimes()
{
	timedActions = null;
	timeNameIndices = null;
}
