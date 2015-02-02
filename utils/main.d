/**
 * A sensible main() function.
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
mixin template main(alias realMain)
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

	int main(string[] args)
	{
		debug
			return run(args);
		else
		{
			try
				return run(args);
			catch (Throwable e)
			{
				version (Windows)
				{
					import core.sys.windows.windows;
					auto h = GetStdHandle(STD_ERROR_HANDLE);
					if (!h || h == INVALID_HANDLE_VALUE)
					{
						import ae.sys.windows : messageBox;
						messageBox(e.msg, "Fatal error", MB_ICONERROR);
						return 1;
					}
				}

				import std.stdio;
				stderr.writefln("Fatal error: %s", e.msg);
				return 1;
			}
		}
	}
}
