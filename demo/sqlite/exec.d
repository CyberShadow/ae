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
 * Portions created by the Initial Developer are Copyright (C) 2009-2011
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

module ae.demo.sqlite.exec;

import std.stdio;
import std.algorithm;
import std.array;
import std.conv;

import ae.sys.sqlite3;
import ae.sys.console;

void main(string[] args)
{
	if (args.length != 3)
		return stderr.writeln("Usage: exec DATABASE COMMAND");
	auto db = new SQLite(args[1]);
	int idx = 0;
	string[][] rows;
	foreach (cells, columns; db.query(args[2]))
	{
		if (rows is null)
			rows ~= ["#"] ~ array(map!`a.idup`(columns));
		rows ~= [to!string(idx++)] ~ array(map!`a.idup`(cells));
	}
	if (rows.length == 0)
		return;
	auto widths = new int[rows[0].length];
	foreach (row; rows)
	{
		assert(row.length == rows[0].length);
		foreach (i, cell; row)
			widths[i] = max(widths[i], textWidth(cell));
	}
	foreach (j, row; rows)
	{
		auto rowLines = array(map!textLines(row));
		auto lineCount = reduce!max(map!`a.length`(rowLines));

		foreach (line; 0..lineCount)
		{
			foreach (i, lines; rowLines)
			{
				if (i) write(" │ ");
				string col = line < lines.length ? lines[line] : null;
				write(col, std.array.replicate(" ", widths[i]-col.length));
			}
			writeln();
		}
		if (j==0)
		{
			foreach (i, w; widths)
			{
				if (i) write("─┼─");
				write(std.array.replicate("─", w));
			}
			writeln();
		}
	}
	writeln();
}

import std.utf;
import std.string;

size_t textWidth(string s)
{
	try
	{
		auto lines = splitLines(s);
		size_t w = 0;
		foreach (line; lines)
			w = max(w, std.utf.count(line));
		return w;
	}
	catch (Exception e)
		return s.length;
}

string[] textLines(string s)
{
	try
		return splitLines(s);
	catch (Exception e)
		return [s];
}
