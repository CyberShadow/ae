module ng.os.posix.config;

import std.conv;
import std.stdio;
import std.file;
import std.conv;
import std.string;

import ng.os.os;

struct PosixConfig
{
static:
	T read(T)(string name, T defaultValue = T.init)
	{
		if (!loaded)
			load();
		auto pvalue = name in values;
		if (pvalue)
			return to!T(*pvalue);
		else
			return defaultValue;
	}

	void write(T)(string name, T value)
	{
		values[name] = to!string(value);
	}

	void save()
	{
		auto f = File(getFilename(), "wt");
		foreach (name, value; values)
			f.writefln("%s=%s", name, value);
	}

private:
	bool loaded = false;
	string[string] values;

	string getFilename()
	{
		return OS.getRoamingAppProfile() ~ "/config";
	}

	void load()
	{
		scope(success) loaded = true;
		string fn = getFilename();
		if (!exists(fn))
			return;
		foreach (line; File(fn, "rt").byLine())
			if (line.length>0 && line[0]!='#')
			{
				int p = line.indexOf('=');
				if (p>0)
					values[line[0..p].idup] = line[p+1..$].idup;
			}
	}

	~this()
	{
		if (loaded)
			save();
	}
}
