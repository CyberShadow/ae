/**
 * PID file and lock
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

module ae.sys.pidfile;

import std.conv : text;
import std.exception;
import std.file : thisExePath, tempDir;
import std.path : baseName, buildPath;
import std.process : thisProcessID;
import std.stdio : File;
import std.string : fromStringz;

version (Posix)
{
	import core.sys.posix.unistd : getlogin, geteuid;
	import std.process : environment;
}
version (Windows)
{
	import core.sys.windows.lmcons : UNLEN;
	import core.sys.windows.winbase : GetUserNameW;
	import core.sys.windows.windef : DWORD;
	import core.sys.windows.winnt : WCHAR;
	import ae.sys.windows.exception : wenforce;
}

static File pidFile;

void createPidFile(
	string name = defaultPidFileName(),
	string path = defaultPidFilePath())
{
	auto fullPath = buildPath(path, name);
	assert(!pidFile.isOpen(), "A PID file has already been created for this program / process");
	pidFile.open(fullPath, "w+b");
	scope(failure) pidFile.close();
	enforce(pidFile.tryLock(), "Failed to acquire lock on PID file " ~ fullPath ~ ". Is another instance running?");
	pidFile.write(thisProcessID);
	pidFile.flush();
}

string defaultPidFileName()
{
	version (Posix)
		auto userName = environment.get("LOGNAME", cast(string)getlogin().fromStringz);
	version (Windows)
	{
		WCHAR[UNLEN + 1] buf;
		DWORD len = buf.length;
		GetUserNameW(buf.ptr, &len).wenforce("GetUserNameW");
		auto userName = buf.ptr.fromStringz();
	}

	return text(userName, "-", thisExePath.baseName, ".pid");
}

string defaultPidFilePath()
{
	version (Posix)
	{
		if (geteuid() == 0)
			return "/var/run";
		else
			return tempDir; // /var/run and /var/lock are usually not writable for non-root processes
	}
	version (Windows)
		return tempDir;
}

unittest
{
	createPidFile();

	auto realPidFile = pidFile;
	pidFile = File.init;

	static void runForked(void delegate() code)
	{
		version (Posix)
		{
			// Since locks are per-process, we cannot test lock failures within
			// the same process. fork() is used to create a second process.
			import core.stdc.stdlib : exit;
			import core.sys.posix.sys.wait : wait;
			import core.sys.posix.unistd : fork;
			int child, status;
			if ((child = fork()) == 0)
			{
				code();
				exit(0);
			}
			else
			{
				assert(wait(&status) != -1);
				assert(status == 0, "Fork crashed");
			}
		}
		else
			code();
	}

	runForked({
		assertThrown!Exception(createPidFile);
		assert(!pidFile.isOpen);
	});
	
	realPidFile.close();

	runForked({
		createPidFile();
	});
}
