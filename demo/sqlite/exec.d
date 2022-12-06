/**
 * ae.demo.sqlite.exec
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

module ae.demo.sqlite.exec;

import std.algorithm;
import std.array;
import std.conv;
import std.datetime.stopwatch;
import std.stdio;

import ae.sys.sqlite3;
import ae.sys.console;
import ae.utils.text;

void main(string[] args)
{
	if (args.length < 2 || args.length > 3)
		return stderr.writeln("Usage: exec DATABASE [COMMAND]");

	auto db = new SQLite(args[1]);

	void exec(string sql, bool interactive)
	{
		int idx = 0;
		string[][] rows;
		StopWatch sw;
		sw.start();
		foreach (cells, columns; db.query(sql))
		{
			sw.stop();
			if (rows is null)
				rows ~= ["#"] ~ array(map!`a.idup`(columns));
			rows ~= [to!string(idx++)] ~ array(map!`a.idup`(cells));
			sw.start();
		}
		sw.stop();
		stderr.writeln("Query executed in ", sw.peek().toString().replace("μ", "u"));

		if (rows.length == 0)
			return;
		auto widths = new size_t[rows[0].length];
		foreach (row; rows)
		{
			assert(row.length == rows[0].length);
			foreach (i, cell; row)
				widths[i] = widths[i].max(cell.textWidth());
		}
		foreach (j, row; rows)
		{
			auto rowLines = row.map!splitAsciiLines().array();
			auto lineCount = rowLines.map!(line => line.length).fold!max(size_t(0));

			foreach (line; 0..lineCount)
			{
				foreach (i, lines; rowLines)
				{
					if (i) write(" │ ");
					string col = line < lines.length ? lines[line] : null;
					write(col, std.array.replicate(" ", widths[i] - std.utf.count(col)));
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

	if (args.length == 3)
		exec(args[2], false);
	else
		while (!stdin.eof())
		{
			write("sqlite> ");
			stdout.flush();
			try
				exec(readln().chomp(), true);
			catch (Exception e)
				writeln(e.msg);
		}
}

import std.utf;
import std.string;

size_t textWidth(string s) nothrow
{
	return s
		.splitAsciiLines()
		.map!(std.utf.count)
		.fold!max(size_t(0));
}
