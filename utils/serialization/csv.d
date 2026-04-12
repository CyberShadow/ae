/**
 * CSV/TSV serialization source and sink.
 *
 * Source/sink protocol adapters for CSV (Comma-Separated Values) and
 * TSV (Tab-Separated Values) data. The parser (source) reads CSV text
 * and emits events into any sink; the writer (sink) accepts events and
 * produces CSV text.
 *
 * With a header row, data rows are emitted as objects (field names from
 * the header). Without, rows are emitted as arrays of strings.
 *
 * All values are emitted as strings — use `TypeCoercer` filter for
 * automatic type coercion (string → numeric/boolean).
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

module ae.utils.serialization.csv;

import std.exception;
import std.traits;

import ae.utils.serialization.serialization;

/// Options controlling CSV parsing/writing behavior.
struct CsvOptions
{
	/// Field delimiter character.
	char delimiter = ',';

	/// Whether the first row contains field names.
	bool hasHeader = true;
}

// ---------------------------------------------------------------------------
// CsvParser — source that reads CSV text
// ---------------------------------------------------------------------------

/// CSV source that parses CSV text and emits events into a sink.
///
/// With `hasHeader`, the first row provides field names and subsequent
/// rows become objects. Without, the output is an array of arrays of
/// strings.
struct CsvParser(C = immutable(char), CsvOptions csvOptions = CsvOptions.init)
{
	C[] s;
	size_t p;

	C[] readField()
	{
		if (p >= s.length || s[p] == '\n' || s[p] == '\r')
			return null;

		if (p < s.length && s[p] == '"')
		{
			// Quoted field (RFC 4180)
			p++; // skip opening quote
			size_t start = p;
			C[] buf;
			while (p < s.length)
			{
				if (s[p] == '"')
				{
					if (p + 1 < s.length && s[p + 1] == '"')
					{
						// Escaped quote
						buf ~= s[start .. p];
						buf ~= '"';
						p += 2;
						start = p;
					}
					else
					{
						buf ~= s[start .. p];
						p++; // skip closing quote
						// skip delimiter
						if (p < s.length && s[p] == csvOptions.delimiter)
							p++;
						return buf;
					}
				}
				else
					p++;
			}
			buf ~= s[start .. p];
			return buf;
		}
		else
		{
			size_t start = p;
			while (p < s.length && s[p] != csvOptions.delimiter && s[p] != '\n' && s[p] != '\r')
				p++;
			auto result = s[start .. p];
			if (p < s.length && s[p] == csvOptions.delimiter)
				p++;
			return result;
		}
	}

	void skipNewline()
	{
		while (p < s.length && (s[p] == '\n' || s[p] == '\r'))
			p++;
	}

	bool atEndOfLine()
	{
		return p >= s.length || s[p] == '\n' || s[p] == '\r';
	}

	C[][] readRow()
	{
		C[][] fields;
		while (!atEndOfLine())
			fields ~= readField();
		skipNewline();
		return fields;
	}

	/// Parse and emit events into sink.
	void read(Sink)(Sink sink)
	{
		import ae.utils.serialization.serialization : Array;

		static if (csvOptions.hasHeader)
		{
			auto headers = readRow();
			OuterReaderWithHeaders!(typeof(this)) outerReader = {headers: headers, parser: &this};
			sink.handle(Array!(typeof(outerReader))(outerReader));
		}
		else
		{
			OuterReaderNoHeaders!(typeof(this)) outerReader = {parser: &this};
			sink.handle(Array!(typeof(outerReader))(outerReader));
		}
	}
}

private struct OuterReaderWithHeaders(Parser)
{
	immutable(char)[][] headers;
	Parser* parser;

	void opCall(Sink)(Sink sink)
	{
		import ae.utils.serialization.serialization : Map;

		while (parser.p < parser.s.length)
		{
			auto row = parser.readRow();
			if (row.length == 0) continue;
			RowObjectReader rowReader = {row: row, headers: headers};
			sink.handle(Map!(typeof(rowReader))(rowReader));
		}
	}
}

private struct OuterReaderNoHeaders(Parser)
{
	Parser* parser;

	void opCall(Sink)(Sink sink)
	{
		import ae.utils.serialization.serialization : Array;

		while (parser.p < parser.s.length)
		{
			auto row = parser.readRow();
			if (row.length == 0) continue;
			RowArrayReader rowReader = {row: row};
			sink.handle(Array!(typeof(rowReader))(rowReader));
		}
	}
}

private struct RowObjectReader
{
	immutable(char)[][] row;
	immutable(char)[][] headers;

	void opCall(Sink)(Sink sink)
	{
		import ae.utils.serialization.serialization : Field;

		foreach (i, header; headers)
		{
			if (i >= row.length) break;
			auto value = row[i];
			CsvStringReader nr = {s: header};
			CsvStringReader vr = {s: value};
			sink.handle(Field!(typeof(nr), typeof(vr))(nr, vr));
		}
	}
}

private struct RowArrayReader
{
	immutable(char)[][] row;

	void opCall(Sink)(Sink sink)
	{
		import ae.utils.serialization.serialization : String;

		foreach (field; row)
			sink.handle(String!(typeof(field))(field));
	}
}

private struct CsvStringReader
{
	immutable(char)[] s;
	void opCall(Sink)(Sink sink)
	{
		import ae.utils.serialization.serialization : String;
		sink.handle(String!(typeof(s))(s));
	}
}

// ---------------------------------------------------------------------------
// CsvWriter — sink that produces CSV text
// ---------------------------------------------------------------------------

/// CSV sink that writes CSV text from serialization events.
///
/// Expects an array of objects (with header) or an array of arrays
/// (without header) at the top level.
struct CsvWriter(Output, CsvOptions csvOptions = CsvOptions.init)
{
	Output output;

	void handle(V)(V v)
	{
		import ae.utils.serialization.serialization : isProtocolArray;

		static if (isProtocolArray!V)
		{
			static if (csvOptions.hasHeader)
			{
				CsvRowCollector collector = {csvOptions: csvOptions};
				v.reader(&collector);

				// Write header
				if (collector.headerNames.length > 0)
				{
					foreach (i, h; collector.headerNames)
					{
						if (i > 0) output.put(csvOptions.delimiter);
						writeField(h);
					}
					output.put('\n');
				}

				// Write rows
				foreach (ref row; collector.rows)
				{
					foreach (i, ref val; row)
					{
						if (i > 0) output.put(csvOptions.delimiter);
						writeField(val);
					}
					output.put('\n');
				}
			}
			else
			{
				CsvArrayCollector ac = {csvOptions: csvOptions};
				v.reader(&ac);
				foreach (ref row; ac.rows)
				{
					foreach (i, ref val; row)
					{
						if (i > 0) output.put(csvOptions.delimiter);
						writeField(val);
					}
					output.put('\n');
				}
			}
		}
		else
			static assert(false, "CsvWriter: expected Array at top level, got " ~ V.stringof);
	}

	private void writeField(const(char)[] field)
	{
		bool needsQuoting = false;
		foreach (c; field)
			if (c == csvOptions.delimiter || c == '"' || c == '\n' || c == '\r')
			{
				needsQuoting = true;
				break;
			}

		if (needsQuoting)
		{
			output.put('"');
			foreach (c; field)
			{
				if (c == '"') output.put(`""`);
				else output.put(c);
			}
			output.put('"');
		}
		else
			output.put(field);
	}

}

/// Collects rows from an array-of-objects stream for header-mode CSV.
private struct CsvRowCollector
{
	import std.conv : to;

	CsvOptions csvOptions;
	string[] headerNames;
	string[][] rows;
	bool headersCollected;

	void handle(V)(V v)
	{
		import ae.utils.serialization.serialization : isProtocolMap;

		static if (isProtocolMap!V)
		{
			CsvFieldCollector fc;
			v.reader(&fc);

			if (!headersCollected)
			{
				headerNames = fc.names;
				headersCollected = true;
			}

			// Build row aligned to header order
			string[] row;
			row.length = headerNames.length;
			foreach (i, ref h; headerNames)
			{
				foreach (j, ref n; fc.names)
					if (n == h)
					{
						row[i] = fc.values[j];
						break;
					}
			}
			rows ~= row;
		}
		// Ignore non-object elements
	}
}

private struct CsvFieldCollector
{
	import std.conv : to;

	string[] names;
	string[] values;

	void handle(V)(V v)
	{
		import ae.utils.serialization.serialization : isProtocolField;

		static if (isProtocolField!V)
		{
			import ae.utils.serialization.filter : NameCaptureSink;

			NameCaptureSink nc;
			v.nameReader(&nc);
			names ~= nc.name;

			CsvValueCapture vc;
			v.valueReader(&vc);
			values ~= vc.value;
		}
		else
			static assert(false, "CsvFieldCollector: expected Field, got " ~ V.stringof);
	}
}

private struct CsvValueCapture
{
	import std.conv : to;

	string value;

	void handle(V)(V v)
	{
		import ae.utils.serialization.serialization : isProtocolNull, isProtocolBoolean,
			isProtocolNumeric, isProtocolString, isProtocolArray, isProtocolMap;

		static if (isProtocolNull!V)
			value = "";
		else static if (isProtocolBoolean!V)
			value = v.value ? "true" : "false";
		else static if (isProtocolNumeric!V)
			value = v.text.to!string;
		else static if (isProtocolString!V)
			value = v.text.to!string;
		else static if (isProtocolArray!V)
			value = "";
		else static if (isProtocolMap!V)
			value = "";
		else
			static assert(false, "CsvValueCapture: unsupported type " ~ V.stringof);
	}
}

// ---------------------------------------------------------------------------
// Convenience functions
// ---------------------------------------------------------------------------

/// Parse CSV text into a D value.
T parseCsv(T, CsvOptions csvOptions = CsvOptions.init, C = immutable(char))(C[] text)
{
	auto parser = CsvParser!(C, csvOptions)(text, 0);
	T result;
	auto sink = deserializer(&result);
	parser.read(sink);
	return result;
}

/// Serialize a D value to CSV text.
string toCsv(CsvOptions csvOptions = CsvOptions.init, T)(auto ref T value)
{
	import ae.utils.textout : StringBuilder;
	CsvWriter!(StringBuilder, csvOptions) writer;
	Serializer.Impl!Object.read(&writer, value);
	return writer.output.get();
}

// ---------------------------------------------------------------------------
// Unit tests
// ---------------------------------------------------------------------------


// CSV with header -> array of structs
debug(ae_unittest) unittest
{
	auto csv = "name,age,city\nJohn,30,NYC\nJane,25,LA\n";

	static struct Person
	{
		string name;
		string age;
		string city;
	}

	auto result = parseCsv!(Person[])(csv);
	assert(result.length == 2);
	assert(result[0].name == "John");
	assert(result[0].age == "30");
	assert(result[0].city == "NYC");
	assert(result[1].name == "Jane");
}

// CSV without header -> array of arrays
debug(ae_unittest) unittest
{
	enum opts = CsvOptions(',', false);
	auto csv = "John,30,NYC\nJane,25,LA\n";
	auto result = parseCsv!(string[][], opts)(csv);

	assert(result.length == 2);
	assert(result[0] == ["John", "30", "NYC"]);
	assert(result[1] == ["Jane", "25", "LA"]);
}

// Quoted fields
debug(ae_unittest) unittest
{
	auto csv = "name,value\n\"hello, world\",42\n\"has \"\"quotes\"\"\",7\n";
	auto result = parseCsv!(string[string][])(csv);

	assert(result.length == 2);
	assert(result[0]["name"] == "hello, world");
	assert(result[1]["name"] == `has "quotes"`);
}

// TSV (tab-delimited)
debug(ae_unittest) unittest
{
	enum opts = CsvOptions('\t');
	auto tsv = "name\tage\nJohn\t30\n";
	auto result = parseCsv!(string[string][], opts)(tsv);

	assert(result.length == 1);
	assert(result[0]["name"] == "John");
	assert(result[0]["age"] == "30");
}

// CSV with TypeCoercer for type conversion
debug(ae_unittest) unittest
{
	import ae.utils.serialization.filter : typeCoercer;

	auto csv = "name,age,active\nJohn,30,true\nJane,25,false\n";
	auto parser = CsvParser!(immutable(char))(csv, 0);

	static struct Person
	{
		string name;
		int age;
		bool active;
	}

	Person[] result;
	auto sink = deserializer(&result);
	auto coercer = typeCoercer(sink, true, true, false);
	parser.read(&coercer);

	assert(result.length == 2);
	assert(result[0].name == "John");
	assert(result[0].age == 30);
	assert(result[0].active == true);
	assert(result[1].name == "Jane");
	assert(result[1].age == 25);
	assert(result[1].active == false);
}

// Round-trip: D struct array -> CSV -> D struct array
debug(ae_unittest) unittest
{
	static struct Item
	{
		string name;
		string value;
	}

	Item[] original = [Item("hello", "world"), Item("foo", "bar")];
	auto csv = toCsv(original);
	auto result = parseCsv!(string[string][])(csv);

	assert(result.length == 2);
	assert(result[0]["name"] == "hello");
	assert(result[0]["value"] == "world");
	assert(result[1]["name"] == "foo");
	assert(result[1]["value"] == "bar");
}

// CSV writer: quoting fields with special characters
debug(ae_unittest) unittest
{
	static struct Item
	{
		string name;
		string desc;
	}

	Item[] original = [Item("hello", "has, comma"), Item("test", `has "quotes"`)];
	auto csv = toCsv(original);

	// Verify it round-trips
	auto result = parseCsv!(string[string][])(csv);
	assert(result[0]["desc"] == "has, comma");
	assert(result[1]["desc"] == `has "quotes"`);
}

// Empty CSV
debug(ae_unittest) unittest
{
	auto csv = "name,age\n";
	auto result = parseCsv!(string[string][])(csv);
	assert(result.length == 0);
}
