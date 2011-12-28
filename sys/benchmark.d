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
 * The Original Code is the ArmageddonEngine library.
 *
 * The Initial Developer of the Original Code is
 * Vladimir Panteleev <vladimir@thecybershadow.net>
 * Portions created by the Initial Developer are Copyright (C) 2011
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

/// Framework code for benchmarking individual functions.
module ae.sys.benchmark;

import win32.windows;
import std.exception;
import core.memory;

ulong rdtsc() { asm { rdtsc; } }

private ulong benchStartTime;

void benchStart()
{
	GC.collect();
	version(DOS) asm { cli; }
	benchStartTime = rdtsc();
}

ulong benchEnd()
{
	auto time = rdtsc() - benchStartTime;
	version(DOS) asm { sti; }
	return time;
}

static this()
{
	try
	{
		version(DOS)
		{}
		else
		{
			HANDLE proc = GetCurrentProcess();
			HANDLE thr  = GetCurrentThread();

			HANDLE tok;
			enforce(OpenProcessToken(proc, TOKEN_ADJUST_PRIVILEGES, &tok), "OpenProcessToken");

			LUID luid;
			enforce(LookupPrivilegeValue(null,
				"SeIncreaseBasePriorityPrivilege",
				&luid), "LookupPrivilegeValue");

			TOKEN_PRIVILEGES tp;
			tp.PrivilegeCount = 1;
			tp.Privileges[0].Luid = luid;
			tp.Privileges[0].Attributes = SE_PRIVILEGE_ENABLED;

			AdjustTokenPrivileges(tok, FALSE, &tp, tp.sizeof, null, null);
			enforce(GetLastError() == ERROR_SUCCESS, "AdjustTokenPrivileges");

			enforce(SetPriorityClass(proc, REALTIME_PRIORITY_CLASS), "SetPriorityClass");
		//	enforce(SetPriorityClass(proc, HIGH_PRIORITY_CLASS), "SetPriorityClass");
			enforce(SetThreadPriority (GetCurrentThread(), THREAD_PRIORITY_TIME_CRITICAL), "SetThreadPriority");

			enforce(SetProcessAffinityMask(proc, 1), "SetProcessAffinityMask");
		}
	}
	catch (Exception e)
	{
		import std.stdio;
		writeln("Benchmark initialization error: ", e.msg);
	}

	GC.disable();
}
