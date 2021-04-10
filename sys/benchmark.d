/**
 * Framework code for benchmarking individual functions.
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

module ae.sys.benchmark;
version(Windows):

import std.exception;
import core.memory;

import ae.sys.windows.imports;
mixin(importWin32!q{windows});

ulong rdtsc() { asm { rdtsc; } } /// Returns the result of the RDTSC instruction.

private ulong benchStartTime;

/// Begin benchmarking.
void benchStart()
{
	GC.collect();
	version(DOS) asm { cli; }
	benchStartTime = rdtsc();
}

/// Finish benchmarking, and return the elapsed ticks.
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
