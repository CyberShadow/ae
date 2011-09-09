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
 *   Simon Arlott
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

/// Logging support.
module ae.utils.log;

import std.stdio;
import std.datetime;
import std.string;
import std.file;

private string formatTime(SysTime time)
{
	return format("%04d.%02d.%02d %02d:%02d:%02d.%03d",
		time.year,
		time.month,
		time.day,
		time.hour,
		time.minute,
		time.second,
		time.fracSec.msecs
	);
}

private SysTime getLogTime()
{
	return Clock.currTime(UTC());
}

abstract class Logger
{
public:
	alias log opCall;

	this(string name)
	{
		this.name = name;
		open();
	}

	abstract Logger log(string str);

	void rename(string name)
	{
		close();
		this.name = name;
		open();
	}

	void close() {}

protected:
	string name;

	void open() {}
	void reopen() {}
}

class RawFileLogger : Logger
{
	bool timestampedFilenames;

	this(string name, bool timestampedFilenames = false)
	{
		this.timestampedFilenames = timestampedFilenames;
		super(name);
	}

	override Logger log(string str)
	{
		if (!f.isOpen) // hack
		{
			if (fileName is null)
				throw new Exception("Can't write to a closed log");
			reopen();
			RawFileLogger.log(str);
			close();
			return this;
		}
		f.rawWrite(str);
		f.writeln();
		f.flush();
		return this;
	}

protected:
	string fileName;
	File f;

	override void open()
	{
		string path = "logs/" ~ name;
		int p = path.lastIndexOf('/');
		string baseName = path[p+1..$];
		path = path[0..p];
		string[] segments = path.split("/");
		foreach (i, segment; segments)
		{
			string subpath = segments[0..i+1].join("/");
			if (!exists(subpath))
				mkdir(subpath);
		}
		auto t = getLogTime();
		string timestamp = timestampedFilenames ? format(" %02d-%02d-%02d", t.hour, t.minute, t.second) : null;
		fileName = format("%s/%04d-%02d-%02d%s - %s.log", path, t.year, t.month, t.day, timestamp, baseName);
		f = File(fileName, "at");
	}

	override void reopen()
	{
		f = File(fileName, "at");
	}
}

class FileLogger : RawFileLogger
{
	this(string name, bool timestampedFilenames = false)
	{
		super(name, timestampedFilenames);
	}

	override Logger log(string str)
	{
		auto ut = getLogTime();
		if (ut.day != currentDay)
		{
			f.writeln("\n---- (continued in next day's log) ----");
			f.close();
			open();
			f.writeln("---- (continued from previous day's log) ----\n");
		}
		super.log("[" ~ formatTime(ut) ~ "] " ~ str);
		return this;
	}

	override void close()
	{
		//assert(f !is null);
		if (f.isOpen)
			f.close();
	}

private:
	int currentDay;

protected:
	final override void open()
	{
		super.open();
		currentDay = getLogTime().day;
		f.writef("\n\n--------------- %s ---------------\n\n\n", formatTime(getLogTime()));
	}

	final override void reopen()
	{
		super.reopen();
		f.writef("\n\n--------------- %s ---------------\n\n\n", formatTime(getLogTime()));
	}
}

class ConsoleLogger : Logger
{
	this(string name)
	{
		super(name);
	}

	override Logger log(string str)
	{
		string output = name ~ ": " ~ str ~ "\n";
		stdout.rawWrite(output);
		stdout.flush();
		return this;
	}
}

class MultiLogger : Logger
{
	this(Logger[] loggers ...)
	{
		this.loggers = loggers.dup;
		super(null);
	}

	override Logger log(string str)
	{
		foreach (logger; loggers)
			logger.log(str);
		return this;
	}

	override void rename(string name)
	{
		foreach (logger; loggers)
			logger.rename(name);
	}

	override void close()
	{
		foreach (logger; loggers)
			logger.close();
	}

private:
	Logger[] loggers;
}

class FileAndConsoleLogger : MultiLogger
{
	this(string name)
	{
		super(new FileLogger(name), new ConsoleLogger(name));
	}
}
