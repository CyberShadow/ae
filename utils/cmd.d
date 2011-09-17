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

/// Simple execution of shell commands, and wrappers for common utilities.
module ae.utils.cmd;

string getTempFileName(string extension)
{
	// TODO: use proper OS directories
	import std.random;
	import std.conv;

	static int counter;
	if (!std.file.exists("data"    )) std.file.mkdir("data");
	if (!std.file.exists("data/tmp")) std.file.mkdir("data/tmp");
	return "data/tmp/run-" ~ to!string(uniform!uint()) ~ "-" ~ to!string(counter++) ~ "." ~ extension;
}

// ************************************************************************

import std.process;
import std.string;
import std.array;
import std.exception;

string run(string command, string input = null)
{
	string tempfn = getTempFileName("txt"); // HACK
	string tempfn2;
	if (input !is null)
	{
		tempfn2 = getTempFileName("txt");
		std.file.write(tempfn2, input);
		command ~= " < " ~ tempfn2;
	}
	version(Windows)
		system(`"` ~ command ~ `" 2>&1 > ` ~ tempfn);
	else
		system(command ~ " &> " ~ tempfn);
	string result = cast(string)std.file.read(tempfn);
	std.file.remove(tempfn);
	if (tempfn2) std.file.remove(tempfn2);
	return result;
}

string escapeShellArg(string s)
{
	version(Windows)
		return `"` ~ s.replace(`\`, `\\`).replace(`"`, `\"`) ~ `"`;
	else
		return `'` ~ s.replace(`'`, `'\''`) ~ `'`;
}

string run(string[] args)
{
	string[] escaped;
	foreach (ref arg; args)
		escaped ~= escapeShellArg(arg);
	return run(escaped.join(" "));
}

// ************************************************************************

static import std.uri;

string[] extraWgetOptions;
string cookieFile = "data/cookies.txt";

void enableCookies()
{
	if (!std.file.exists(cookieFile))
		std.file.write(cookieFile, "");
	extraWgetOptions ~= ["--load-cookies", cookieFile, "--save-cookies", cookieFile, "--keep-session-cookies"];
}

string download(string url)
{
	auto dataFile = getTempFileName("wget"); scope(exit) if (std.file.exists(dataFile)) std.file.remove(dataFile);
	auto result = spawnvp(P_WAIT, "wget", ["wget", "-q", "--no-check-certificate", "-O", dataFile] ~ extraWgetOptions ~ [url]);
	enforce(result==0, "wget error");
	return cast(string)std.file.read(dataFile);
}

string post(string url, string data)
{
	auto postFile = getTempFileName("txt");
	std.file.write(postFile, data);
	scope(exit) std.file.remove(postFile);

	auto dataFile = getTempFileName("wget"); scope(exit) if (std.file.exists(dataFile)) std.file.remove(dataFile);
	auto result = spawnvp(P_WAIT, "wget", ["wget", "-q", "--no-check-certificate", "-O", dataFile, "--post-file", postFile] ~ extraWgetOptions ~ [url]);
	enforce(result==0, "wget error");
	return cast(string)std.file.read(dataFile);
}

string put(string url, string data)
{
	auto putFile = getTempFileName("txt");
	std.file.write(putFile, data);
	scope(exit) std.file.remove(putFile);

	auto dataFile = getTempFileName("curl"); scope(exit) if (std.file.exists(dataFile)) std.file.remove(dataFile);
	auto result = spawnvp(P_WAIT, "curl", ["curl", "-s", "-k", "-X", "PUT", "-o", dataFile, "-d", "@" ~ putFile, url]);
	enforce(result==0, "curl error");
	return cast(string)std.file.read(dataFile);
}

string shortenURL(string url)
{
	// TODO: proper config support
	if (std.file.exists("data/bitly.txt"))
		return strip(download(format("http://api.bitly.com/v3/shorten?%s&longUrl=%s&format=txt&domain=j.mp", cast(string)std.file.read("data/bitly.txt"), std.uri.encodeComponent(url))));
	else
		return url;
}

string iconv(string data, string inputEncoding, string outputEncoding = "UTF-8")
{
	return run(format("iconv -f %s -t %s", inputEncoding, outputEncoding), data);
}

string sha1sum(void[] data)
{
	auto dataFile = getTempFileName("sha1data");
	std.file.write(dataFile, data);
	scope(exit) std.file.remove(dataFile);

	return run(["sha1sum", "-b", dataFile])[0..40];
}
