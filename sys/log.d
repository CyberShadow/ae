/**
 * Logging support.
 *
 * License:
 *   This Source Code Form is subject to the terms of
 *   the Mozilla Public License, v. 2.0. If a copy of
 *   the MPL was not distributed with this file, You
 *   can obtain one at http://mozilla.org/MPL/2.0/.
 *
 * Authors:
 *   Vladimir Panteleev <ae@cy.md>
 *   Simon Arlott
 */

module ae.sys.log;

import std.datetime;
import std.file;
import std.path;
import std.stdio;
import std.string;

import ae.sys.file;

import ae.utils.meta.rcclass;
import ae.utils.textout;
import ae.utils.time;

/// Directory where log files will be saved.
/// The default is "logs".
string logDir;

private void init()
{
	if (!logDir)
		logDir = getcwd().buildPath("logs");
}

shared static this() { init(); }
static this() { init(); }

/// Default time format used for timestamps.
enum TIME_FORMAT = "Y-m-d H:i:s.u";

private SysTime getLogTime()
{
	return Clock.currTime(UTC());
}

/// Base logger class.
abstract class CLogger
{
public:
	this(string name)
	{
		this.name = name;
		open();
	} ///

	/// Log a line.
	abstract void log(in char[] str);
	alias opCall = log; /// ditto

	/// Change the output (rotate) the log file.
	void rename(string name)
	{
		close();
		this.name = name;
		open();
	}

	/// Close the log ifel.
	void close() {}

protected:
	string name;

	void open() {}
	void reopen() {}
}
alias Logger = RCClass!CLogger; /// ditto

/// File logger without formatting.
class CRawFileLogger : CLogger
{
	bool timestampedFilenames; /// Whether to include the current time in the log file name.

	this(string name, bool timestampedFilenames = false)
	{
		this.timestampedFilenames = timestampedFilenames;
		super(name);
	} ///

	private final void logStartLine()
	{
	/+
		if (!f.isOpen) // hack
		{
			if (fileName is null)
				throw new Exception("Can't write to a closed log");
			reopen();
			RawFileLogger.log(str);
			close();
		}
	+/
	}

	private final void logFragment(in char[] str)
	{
		f.write(str);
	}

	private final void logEndLine()
	{
		f.writeln();
		f.flush();
	}

	override void log(in char[] str)
	{
		logStartLine();
		logFragment(str);
		logEndLine();
	} ///

protected:
	string fileName;
	File f;

	override void open()
	{
		// name may contain directory separators
		string path = buildPath(logDir, name);
		auto base = path.baseName();
		auto dir = path.dirName();

		auto t = getLogTime();
		string timestamp = timestampedFilenames ? format(" %02d-%02d-%02d", t.hour, t.minute, t.second) : null;
		fileName = buildPath(dir, format("%04d-%02d-%02d%s - %s.log", t.year, t.month, t.day, timestamp, base));
		ensurePathExists(fileName);
		f = File(fileName, "ab");
	}

	override void reopen()
	{
		f = File(fileName, "ab");
	}
}
alias RawFileLogger = RCClass!CRawFileLogger; /// ditto
alias rawFileLogger = rcClass!CRawFileLogger; /// ditto

/// Basic file logger.
class CFileLogger : CRawFileLogger
{
	this(string name, bool timestampedFilenames = false)
	{
		super(name, timestampedFilenames);
	} ///

	override void log(in char[] str)
	{
		auto ut = getLogTime();
		if (ut.day != currentDay)
		{
			f.writeln("\n---- (continued in next day's log) ----");
			f.close();
			open();
			f.writeln("---- (continued from previous day's log) ----\n");
		}

		enum TIMEBUFSIZE = 1 + timeFormatSize(TIME_FORMAT) + 2;
		static char[TIMEBUFSIZE] buf = "[";
		auto writer = BlindWriter!char(buf.ptr+1);
		putTime!TIME_FORMAT(writer, ut);
		writer.put(']');
		writer.put(' ');

		super.logStartLine();
		super.logFragment(buf[0..writer.ptr-buf.ptr]);
		super.logFragment(str);
		super.logEndLine();
	} ///

	override void close()
	{
		//assert(f !is null);
		if (f.isOpen)
			f.close();
	} ///

private:
	int currentDay;

protected:
	final override void open()
	{
		super.open();
		currentDay = getLogTime().day;
		f.writef("\n\n--------------- %s ---------------\n\n\n", getLogTime().formatTime!(TIME_FORMAT)());
		f.flush();
	}

	final override void reopen()
	{
		super.reopen();
		f.writef("\n\n--------------- %s ---------------\n\n\n", getLogTime().formatTime!(TIME_FORMAT)());
		f.flush();
	}
}
alias FileLogger = RCClass!CFileLogger; /// ditto
alias fileLogger = rcClass!CFileLogger; /// ditto

/// Logs to the console (standard error).
class CConsoleLogger : CLogger
{
	this(string name)
	{
		super(name);
	} ///

	override void log(in char[] str)
	{
		stderr.write(name, ": ", str, "\n");
		stderr.flush();
	} ///
}
alias ConsoleLogger = RCClass!CConsoleLogger; /// ditto
alias consoleLogger = rcClass!CConsoleLogger; /// ditto

/// Logs to nowhere.
class CNullLogger : CLogger
{
	this() { super(null); } ///
	override void log(in char[] str) {} ///
}
alias NullLogger = RCClass!CNullLogger; /// ditto
alias nullLogger = rcClass!CNullLogger; /// ditto

/// Logs to several other loggers.
class CMultiLogger : CLogger
{
	this(Logger[] loggers ...)
	{
		this.loggers = loggers.dup;
		super(null);
	} ///

	override void log(in char[] str)
	{
		foreach (logger; loggers)
			logger.log(str);
	} ///

	override void rename(string name)
	{
		foreach (logger; loggers)
			logger.rename(name);
	} ///

	override void close()
	{
		foreach (logger; loggers)
			logger.close();
	} ///

private:
	Logger[] loggers;
}
alias MultiLogger = RCClass!CMultiLogger; /// ditto
alias multiLogger = rcClass!CMultiLogger; /// ditto

/// Logs to a file and the console.
class CFileAndConsoleLogger : CMultiLogger
{
	this(string name)
	{
		Logger f, c;
		f = fileLogger(name);
		c = consoleLogger(name);
		super(f, c);
	} ///
}
alias FileAndConsoleLogger = RCClass!CFileAndConsoleLogger; /// ditto
alias fileAndConsoleLogger = rcClass!CFileAndConsoleLogger; /// ditto

bool quiet; /// True if "-q" or ~--quiet" is present on the command line.

shared static this()
{
	import core.runtime : Runtime;
	foreach (i, arg; Runtime.args)
		if (i > 0 && (arg == "-q" || arg == "--quiet"))
			quiet = true;
}

/// Create a logger depending on whether -q or --quiet was passed on the command line.
Logger createLogger(string name)
{
	Logger result;
	debug (ae_unittest)
		result = consoleLogger(name);
	else
	{
		if (quiet)
			result = fileLogger(name);
		else
			result = fileAndConsoleLogger(name);
	}
	return result;
}

/// Create a logger using a user-supplied log directory or transport.
Logger createLogger(string name, string target)
{
	Logger result;
	switch (target)
	{
		case "/dev/stderr":
			result = consoleLogger(name);
			break;
		case "/dev/null":
			result = nullLogger();
			break;
		default:
			result = fileLogger(target.buildPath(name));
			break;
	}
	return result;
}

/// Asynchronous logger that queues log operations to a background thread.
/// This prevents the main thread from blocking on slow I/O operations.
class CAsyncLogger : CLogger
{
	import std.concurrency : Tid, send, spawn, thisTid, receive, receiveOnly;

	private Logger underlyingLogger;
	private Tid workerTid;
	private Tid mainThreadTid;
	private bool closed;

	this(Logger logger)
	{
		this.underlyingLogger = logger;
		this.closed = false;
		this.mainThreadTid = thisTid;
		// Pass the logger to the worker thread.
		// We cast to shared and then back in the worker thread.
		// This is safe because:
		// 1. The main thread only sends messages, never calls logger methods
		// 2. The worker thread has exclusive access to the logger for method calls
		// 3. The parent keeps a reference so it won't be destroyed
		CLogger classRef = this.underlyingLogger;  // Get class ref via alias this
		auto sharedClassRef = cast(shared)classRef;  // class refs are pointers in D

		// Spawn worker thread
		this.workerTid = spawn(&workerThreadFunc, sharedClassRef, this.mainThreadTid);

		super(logger.name);
	} ///

	override void log(in char[] str)
	{
		assert(!closed, "AsyncLogger is already closed");
		// Make a copy of str since it may be stack-allocated
		// and won't be valid when the background thread processes it
		immutable string strCopy = str.idup;
		send(workerTid, immutable LogMessage(strCopy));
	} ///

	override void rename(string name)
	{
		assert(!closed, "AsyncLogger is already closed");
		// Note: rename is asynchronous and returns immediately
		send(workerTid, immutable RenameMessage(name));
	} ///

	override void close()
	{
		if (!closed)
		{
			closed = true;
			// Check if the Tid is still valid before trying to send
			if (workerTid != Tid.init)
			{
				try
				{
					send(workerTid, immutable ShutdownMessage());
					// Wait for confirmation that the thread has finished
					receiveOnly!ShutdownComplete();
				}
				catch (Throwable e)
				{
					// Thread may have already terminated, ignore
				}
			}
			// Now close the underlying logger to release file descriptors
			underlyingLogger.close();
		}
	} ///

	~this()
	{
		close();
	}

private:
	static struct LogMessage { string text; }
	static struct RenameMessage { string name; }
	static struct ShutdownMessage {}
	static struct ShutdownComplete {}

	static void workerThreadFunc(shared(CLogger) loggerPtr, Tid mainThreadTid)
	{
		// Cast back to get access to the logger
		// This is safe because this thread has exclusive access for method calls
		CLogger logger = cast()loggerPtr;
		bool done = false;
		while (!done)
		{
			receive(
				(immutable LogMessage msg) {
					logger.log(msg.text);
				},
				(immutable RenameMessage msg) {
					logger.rename(msg.name);
				},
				(immutable ShutdownMessage msg) {
					cast(void) msg;
					done = true;
				},
			);
		}
		// Send confirmation back to main thread
		send(mainThreadTid, ShutdownComplete());
	}
}
alias AsyncLogger = RCClass!CAsyncLogger; /// ditto
alias asyncLogger = rcClass!CAsyncLogger; /// ditto
