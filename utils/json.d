/**
 * JSON encoding.
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

module ae.utils.json;

import std.string;
import std.exception;

string jsonEscape(bool UNICODE = true)(string str)
{
	static if (UNICODE)
	{
		bool hasUnicode;
		foreach (char c; str)
			if (c >= 0x80)
			{
				hasUnicode = true;
				break;
			}
		if (!hasUnicode)
			return jsonEscape!(false)(str);
	}

	static if (UNICODE)
		alias dchar CHAR_TYPE;
	else
		alias char CHAR_TYPE;

	string result;
	foreach (CHAR_TYPE c ;str)
		if (c=='\\')
			result ~= `\\`;
		else
		if (c=='\"')
			result ~= `\"`;
		else
		if (c=='\b')
			result ~= `\b`;
		else
		if (c=='\f')
			result ~= `\f`;
		else
		if (c=='\n')
			result ~= `\n`;
		else
		if (c=='\r')
			result ~= `\r`;
		else
		if (c=='\t')
			result ~= `\t`;
		else
		if (c<'\x20' || c >= '\x7F' || c=='<' || c=='>' || c=='&')
			result ~= format(`\u%04x`, c);
		else
			result ~= [cast(char)c];
	return result;
}

string toJson(T)(T v)
{
	static if (is(T == enum))
		return "\"" ~ jsonEscape(to!string(v)) ~ "\"";
	else
	static if (is(T : string))
		return "\"" ~ jsonEscape(v) ~ "\"";
	else
	static if (is(T : long))
		return to!string(v);
	else
	static if (is(T U : U[]))
	{
		string[] items;
		foreach (item; v)
			items ~= toJson(item);
		return "[" ~ join(items, ",") ~ "]";
	}
	else
	static if (is(T==struct))
	{
		string json;
		foreach (i, field; v.tupleof)
			json ~= toJson(v.tupleof[i].stringof[2..$]) ~ ":" ~ toJson(field) ~ ",";
		if(json.length>0)
			json=json[0..$-1];
		return "{" ~ json ~ "}";
	}
	else
	static if (is(typeof(T.keys)) && is(typeof(T.values)))
	{
		string json;
		foreach(key,value;v)
			json ~= toJson(key) ~ ":" ~ toJson(value) ~ ",";
		if(json.length>0)
			json=json[0..$-1];
		return "{" ~ json ~ "}";
	}
	else
	static if (is(typeof(*v)))
		return toJson(*v);
	else
		static assert(0, "Can't encode " ~ T.stringof ~ " to JSON");
}

unittest
{
	struct X { int a; string b; }
	X x = {17, "aoeu"};
	assert(toJson(x) == `{"a":17,"b":"aoeu"}`);
	int[] arr = [1,5,7];
	assert(toJson(arr) == `[1,5,7]`);
}

// -------------------------------------------------------------------------------------------

import std.ascii;
import std.utf;
import std.conv;

import ae.utils.text;

private struct JsonParser
{
	string s;
	int p;

	char next()
	{
		enforce(p < s.length);
		return s[p++];
	}

	string readN(uint n)
	{
		string r;
		for (int i=0; i<n; i++)
			r ~= next();
		return r;
	}

	char peek()
	{
		enforce(p < s.length);
		return s[p];
	}

	void skipWhitespace()
	{
		while (isWhite(peek()))
			p++;
	}

	void expect(char c)
	{
		enforce(next()==c, c ~ " expected");
	}

	T read(T)()
	{
		static if (is(T==enum))
			return readEnum!(T)();
		else
		static if (is(T==string))
			return readString();
		else
		static if (is(T==bool))
			return readBool();
		else
		static if (is(T : long))
			return readInt!(T)();
		else
		static if (is(T U : U[]))
			return readArray!(U)();
		else
		static if (is(T==struct))
			return readObject!(T)();
		else
		static if (is(typeof(T.init.keys)) && is(typeof(T.init.values)) && is(typeof(T.init.keys[0])==string))
			return readAA!(T)();
		else
		static if (is(T U : U*))
			return readPointer!(U)();
		else
			static assert(0, "Can't decode " ~ T.stringof ~ " from JSON");
	}

	string readString()
	{
		skipWhitespace();
		expect('"');
		string result;
		while (true)
		{
			auto c = next();
			if (c=='"')
				break;
			else
			if (c=='\\')
				switch (next())
				{
					case '"':  result ~= '"'; break;
					case '/':  result ~= '/'; break;
					case '\\': result ~= '\\'; break;
					case 'b':  result ~= '\b'; break;
					case 'f':  result ~= '\f'; break;
					case 'n':  result ~= '\n'; break;
					case 'r':  result ~= '\r'; break;
					case 't':  result ~= '\t'; break;
					case 'u':  result ~= toUTF8([cast(wchar)fromHex!ushort(readN(4))]); break;
					default: enforce(false, "Unknown escape");
				}
			else
				result ~= c;
		}
		return result;
	}

	bool readBool()
	{
		skipWhitespace();
		if (peek()=='t')
		{
			enforce(readN(4) == "true", "Bad boolean");
			return true;
		}
		else
		{
			enforce(readN(5) == "false", "Bad boolean");
			return false;
		}
	}

	T readInt(T)()
	{
		skipWhitespace();
		T v;
		string s;
		char c;
		while (c=peek(), c=='-' || (c>='0' && c<='9'))
			s ~= c, p++;
		static if (is(T==byte))
			return to!byte(s);
		else
		static if (is(T==ubyte))
			return to!ubyte(s);
		else
		static if (is(T==short))
			return to!short(s);
		else
		static if (is(T==ushort))
			return to!ushort(s);
		else
		static if (is(T==int))
			return to!int(s);
		else
		static if (is(T==uint))
			return to!uint(s);
		else
		static if (is(T==long))
			return to!long(s);
		else
		static if (is(T==ulong))
			return to!ulong(s);
		else
			static assert(0, "Don't know how to parse numerical type " ~ T.stringof);
	}

	T[] readArray(T)()
	{
		skipWhitespace();
		expect('[');
		skipWhitespace();
		T[] result;
		if (peek()==']')
		{
			p++;
			return result;
		}
		while(true)
		{
			result ~= read!(T)();
			skipWhitespace();
			if (peek()==']')
			{
				p++;
				return result;
			}
			else
				expect(',');
		}
	}

	T readObject(T)()
	{
		skipWhitespace();
		expect('{');
		skipWhitespace();
		T v;
		if (peek()=='}')
		{
			p++;
			return v;
		}

		while (true)
		{
			string jsonField = readString();
			skipWhitespace();
			expect(':');

			bool found;
			foreach (i, field; v.tupleof)
				if (v.tupleof[i].stringof[2..$] == jsonField)
				{
					v.tupleof[i] = read!(typeof(v.tupleof[i]))();
					found = true;
					break;
				}
			enforce(found, "Unknown field " ~ jsonField);

			skipWhitespace();
			if (peek()=='}')
			{
				p++;
				return v;
			}
			else
				expect(',');
		}
	}

	T readAA(T)()
	{
		skipWhitespace();
		expect('{');
		skipWhitespace();
		T v;
		if (peek()=='}')
		{
			p++;
			return v;
		}

		while (true)
		{
			string jsonField = readString();
			skipWhitespace();
			expect(':');

			v[jsonField] = read!(typeof(v.values[0]));

			skipWhitespace();
			if (peek()=='}')
			{
				p++;
				return v;
			}
			else
				expect(',');
		}
	}

	T readEnum(T)()
	{
		return to!T(readString());
	}
}

T jsonParse(T)(string s) { return JsonParser(s).read!(T); }

unittest
{
	enum En { one, two }
	struct S { int i; S[] arr; string[string] dic; En en; }
	S s = S(42, [S(1), S(2)], ["apple":"fruit", "pizza":"vegetable"], En.two);
	auto s2 = jsonParse!S(toJson(s));
	// assert(s == s2); // Issue 3789
	assert(s.i == s2.i && s.arr == s2.arr && s.dic == s2.dic && s.en == En.two);
}
