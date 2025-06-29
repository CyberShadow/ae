﻿/**
 * A sensible main() function.
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

module ae.utils.main;

/**
 * Mix in a main function, which should be adequate
 * for most end-user programs.
 *
 * In debug mode (-debug), this is a pass-through.
 * Otherwise, this will catch uncaught exceptions,
 * and display only the message (sans stack trace)
 * to the user - on standard error, or, for Windows
 * GUI programs, in a message box.
 */
mixin template main(alias realMain, bool printStackTrace = isDebug)
{
	version (unittest_only)
	{
		shared static this()
		{
			import core.runtime : Runtime, UnitTestResult;
			Runtime.extendedModuleUnitTester = {
				foreach (m; ModuleInfo)
					if (m)
						if (auto fp = m.unitTest)
							fp();
				return UnitTestResult();
			};
		}
	}
	else
	int main(string[] args)
	{
		int run(string[] args)
		{
			static if (is(typeof(realMain())))
				static if (is(typeof(realMain()) == void))
					{ realMain(); return 0; }
				else
					return realMain();
			else
				static if (is(typeof(realMain(args)) == void))
					{ realMain(args); return 0; }
				else
					return realMain(args);
		}

		int runCatchingException(E, string message)(string[] args)
		{
			try
				return run(args);
			catch (E e)
			{
				version (Windows)
				{
					import core.sys.windows.windows;
					auto h = GetStdHandle(STD_ERROR_HANDLE);
					if (!h || h == INVALID_HANDLE_VALUE)
					{
						import ae.sys.windows : messageBox;
						messageBox(e.msg, message, MB_ICONERROR);
						return 1;
					}
				}

				import std.stdio : stderr;
				stderr.writefln("%s: %s", message, e.msg);
				return 1;
			}
		}

		static if (printStackTrace)
			static if (is(std.getopt.GetOptException))
				return runCatchingException!(std.getopt.GetOptException, "Usage error")(args);
			else
				return run(args);
		else
			return runCatchingException!(Throwable, "Fatal error")(args);
	}
}

debug
	private enum isDebug = true;
else
	private enum isDebug = false;
