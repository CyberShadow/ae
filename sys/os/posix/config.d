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

module ae.sys.os.posix.config;

import std.conv;
import std.stdio;
import std.file;
import std.conv;
import std.string;

import ae.sys.os.os;

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
