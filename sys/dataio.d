/**
 * ae.sys.dataio
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

module ae.sys.dataio;

import ae.sys.data;

// ************************************************************************

static import std.stream;

Data readStreamData(std.stream.Stream s)
{
	auto size = s.size - s.position;
	assert(size < size_t.max);
	auto data = Data(cast(size_t)size);
	s.readExact(data.mptr, data.length);
	return data;
}

Data readData(string filename)
{
	scope file = new std.stream.File(filename);
	scope(exit) file.close();
	return readStreamData(file);
}

// ************************************************************************

static import std.stdio;

Data readFileData(ref std.stdio.File f)
{
	Data buf = Data(1024*1024);
	Data result;
	while (!f.eof())
		result ~= f.rawRead(cast(ubyte[])buf.mcontents);
	buf.deleteContents();
	return result;
}
