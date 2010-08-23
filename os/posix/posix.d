module ng.os.posix.posix;

import std.path;
import std.string;
import std.ctype;

import ng.os.os;
import ng.os.posix.config;

struct OS
{
static:
	alias DefaultOS this;

	struct Config
	{
		alias PosixConfig this;
	}

	private string getPosixAppName()
	{
		string s = application.getName();
		string s2;
		foreach (c; s)
			if (isalnum(c))
				s2 ~= tolower(c);
			else
				if (!s2.endsWith('-'))
					s2 ~= '-';
		return s2;
	}

	string getAppProfile()
	{
		string path = expandTilde("~/." ~ getPosixAppName());
		if (!exists(path))
			mkdir(path);
		return path;
	}

	alias getAppProfile getLocalAppProfile;
	alias getAppProfile getRoamingAppProfile;
}
