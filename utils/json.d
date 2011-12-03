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
 * Portions created by the Initial Developer are Copyright (C) 2006-2011
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

/// JSON encoding.
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
		while (isWhite(peek))
			p++;
	}

	void expect(char c)
	{
		enforce(next==c, c ~ " expected");
	}

	T read(T)()
	{
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
		static if (is(typeof(T.keys)) && is(typeof(T.values)) && is(typeof(T.keys[0])==string))
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
			auto c = next;
			if (c=='"')
				break;
			else
			if (c=='\\')
				switch (next)
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
		if (peek=='t')
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
		while (c=peek, c=='-' || (c>='0' && c<='9'))
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
		if (peek==']')
		{
			p++;
			return [];
		}
		T[] result;
		while(true)
		{
			result ~= read!(T)();
			skipWhitespace();
			if (peek==']')
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
		if (peek=='}')
			return v;

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
			if (peek=='}')
			{
				p++;
				return v;
			}
			else
				expect(',');
		}
	}
}

T jsonParse(T)(string s) { return JsonParser(s).read!(T); }
