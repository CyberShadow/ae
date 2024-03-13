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
 *   Vladimir Panteleev <ae@cy.md>
 */

module ae.sys.pidfile;

import std.conv : text;
import std.exception;
import std.file : thisExePath, tempDir;
import std.path : baseName, buildPath;
import std.process : thisProcessID;
import std.stdio : File;

import ae.sys.process : getCurrentUser;

version (Posix) import core.sys.posix.unistd : geteuid;

static File pidFile; /// The PID file. Kept open and locked while the program is running.

/// Create and lock a PID file.
/// If the PID file exists and is locked, an exception is thrown.
/// To use, simply call this function at the top of `main` to prevent multiple instances.
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

/// The default `name` argument for `createPidFile`.
/// Returns a file name containing the username and program name.
string defaultPidFileName()
{
	return text(getCurrentUser(), "-", thisExePath.baseName, ".pid");
}

/// The default `path` argument for `createPidFile`.
/// Returns "/var/run" if running as root on POSIX,
/// or the temporary directory otherwise.
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

version(ae_unittest) unittest
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
			import core.sys.posix.sys.wait : wait;
			import core.sys.posix.unistd : fork, _exit;
			int child, status;
			if ((child = fork()) == 0)
			{
				code();
				_exit(0);
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
