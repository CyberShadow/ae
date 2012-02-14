/**
 * MIME types for common extensions.
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

module ae.utils.mime;

import std.string;
import std.path;

string guessMime(string fileName, string defaultResult = null)
{
	string ext = toLower(extension(fileName));

	if (ext.endsWith("-opt"))
		ext = ext[0..$-4]; // HACK

	switch (ext)
	{
		case ".txt":
			return "text/plain";
		case ".htm":
		case ".html":
			return "text/html";
		case ".js":
			return "text/javascript";
		case ".css":
			return "text/css";
		case ".png":
			return "image/png";
		case ".gif":
			return "image/gif";
		case ".jpg":
		case ".jpeg":
			return "image/jpeg";
		case ".ico":
			return "image/vnd.microsoft.icon";

		case ".c":
			return "text/x-csrc";
		case ".h":
			return "text/x-chdr";
		case ".cpp":
		case ".c++":
		case ".cxx":
		case ".cc":
			return "text/x-c++src";
		case ".hpp":
		case ".h++":
		case ".hxx":
		case ".hh":
			return "text/x-c++hdr";
		case ".d": // by extension :P
			return "text/x-dsrc";
		case ".di":
			return "text/x-dhdr";

		default:
			return defaultResult;
	}
}
