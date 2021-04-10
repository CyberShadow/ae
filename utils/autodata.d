/**
 * Automatic struct/class comparison/hashing/serialization
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

module ae.utils.autodata;

import ae.utils.digest;
import std.traits;
public import std.conv;

/// Returns a string mixin for processing the field with the name `name`.
string addAutoField(string name, bool reverseSort = false)
{
	return `mixin(typeof(handler).getMixin!(typeof(` ~ name ~ `), "` ~ name ~ `", ` ~ (reverseSort ? "true" : "false") ~`));`;
}

/// Automatically implements `opCmp`, `opEquals`, and `toHash` using `processData`
template AutoCompare()
{
	///
	static if (is(typeof(this)==class))
	{
		alias typeof(this) _AutoDataTypeReference;
		alias Object _AutoDataOtherTypeReference;

		override hash_t toHash() const { try { return _AutoDataHash(); } catch(object.Exception e) { assert(0, e.msg); } }
		override bool opEquals(Object o) const { return _AutoDataEquals(o); }
		override int opCmp(Object o) const { return _AutoDataCmp(o); }
	}
	else // struct
	{
		alias const(typeof(this)*) _AutoDataTypeReference;
		alias const(typeof(this)*) _AutoDataOtherTypeReference;

		hash_t toHash() const { return _AutoDataHash(); }
		bool opEquals(ref const typeof(this) s) const { return _AutoDataEquals(&s); }
		int opCmp(ref const typeof(this) s) const { return _AutoDataCmp(&s); }
	}

	@trusted private hash_t _AutoDataHash() const
	{
		_HashDataHandler handler;
		handler.hasher.Begin();
		processData!(void, q{}, q{})(handler);
		return handler.hasher.End();
	}

	private bool _AutoDataEquals(_AutoDataOtherTypeReference other) const
	{
		auto handler = _EqualsDataHandler!_AutoDataTypeReference(cast(_AutoDataTypeReference) other);
		if (handler.other is null)
			return false;
		return processData!(bool, q{auto _AutoDataOther = handler.other;}, q{return true;})(handler);
	}

	private int _AutoDataCmp(_AutoDataOtherTypeReference other) const
	{
		auto handler = _CmpDataHandler!_AutoDataTypeReference(cast(_AutoDataTypeReference) other);
		if (handler.other is null)
			return false;
		return processData!(int, q{auto _AutoDataOther = handler.other;}, "return 0;")(handler);
	}
}

/// Automatically implements `toString` using `processData`
template AutoToString()
{
	///
	static if (is(typeof(this)==class))
		override string toString() const { return _AutoDataToString(); }
	else // struct
		string toString() const { return _AutoDataToString(); }

	string _AutoDataToString() const
	{
		_ToStringDataHandler handler;
		return processData!(string, "string _AutoDataResult;", "return _AutoDataResult;")(handler);
	}
}

/// Automatically implements `processData` which processes all fields.
template ProcessAllData()
{
	///
	R processData(R, string prolog, string epilog, H)(ref H handler) const
	{
		mixin(prolog);
		foreach (i, T; this.tupleof)
			mixin(addAutoField(this.tupleof[i].stringof[5..$])); // remove "this."
		mixin(epilog);
	}
}

/// For data handlers that only need to look at the raw data (currently only _HashDataHandler)
template _RawDataHandlerWrapper()
{
	template getMixin(T, string name, bool reverseSort)
	{
		enum getMixin = getMixinRecursive!(T, "this." ~ name, "");
	}

	template getMixinRecursive(T, string name, string loopDepth)
	{
		static if (is(T U : U[]))
			enum getMixinRecursive =
				"{ bool _AutoDataNullTest = " ~ name ~ " is null; " ~ getRawMixin!("&_AutoDataNullTest", "bool.sizeof") ~ "}" ~
				(!hasAliasing!(U) ?
					getRawMixin!(name ~ ".ptr", name ~ ".length")
				:
					"foreach (ref _AutoDataArrayItem" ~ loopDepth ~ "; " ~ name ~ ") {" ~ getMixinRecursive!(U, "_AutoDataArrayItem" ~ loopDepth, loopDepth~"Item") ~ "}"
				);
		else
		static if (!hasAliasing!(T))
			enum getMixinRecursive = getRawMixin!("&" ~ name, name ~ ".sizeof");
		else
		static if (is(T==struct))
			enum getMixinRecursive = name ~ ".processData!(void, ``, ``)(handler);";
		else
		static if (is(T==class))
			enum getMixinRecursive = "if ("~name~" !is null) " ~ name ~ ".processData!(void, ``, ``)(handler);";
		else
			static assert(0, "Don't know how to process type: " ~ T.stringof);
	}
}

struct _HashDataHandler
{
	mixin _RawDataHandlerWrapper;

	MurmurHash2A hasher;

	template getRawMixin(string ptr, string len)
	{
		enum getRawMixin = "handler.hasher.Add(" ~ ptr ~ ", to!int(" ~ len ~ "));";
	}
}

struct _EqualsDataHandler(O)
{
	O other;

	template nullCheck(T, string name)
	{
		static if (is(typeof(T.init is null)))
			enum nullCheck = "if ((this." ~ name ~ " is null) != (_AutoDataOther." ~ name ~ " is null)) return false;";
		else
			enum nullCheck = "";
	}

	template getMixin(T, string name, bool reverseSort)
	{
		enum getMixin = nullCheck!(T, name) ~ "if (this." ~ name ~ " != _AutoDataOther." ~ name ~ ") return false;";
	}
}

struct _CmpDataHandler(O)
{
	O other;

	template getMixin(T, string name, bool reverseSort)
	{
		enum getMixin = getMixinComposite!(T, name, reverseSort).code;
	}

	template nullCheck(T, string name, string reverseStr)
	{
		static if (is(typeof(T.init is null)))
			enum nullCheck = "
				if (this."~name~" is null && _AutoDataOther."~name~" is null)
					{ /* skip */ }
				else
				if (this."~name~" is null && _AutoDataOther."~name~" !is null)
					return " ~ reverseStr ~ "(-1);
				else
				if (this."~name~" !is null && _AutoDataOther."~name~" is null)
					return " ~ reverseStr ~ "( 1);
				else";
		else
			enum nullCheck = "";
	}

	template getMixinComposite(T, string name, bool reverseSort)
	{
		enum reverseStr = reverseSort ? "-" : "";
		static if (is(T U : U[]))
			enum arrCode = "{ int _AutoDataCmp = cast(int)(this." ~ name ~ " !is null) - cast(int)(_AutoDataOther." ~ name ~ " !is null); if (_AutoDataCmp != 0) return " ~ reverseStr ~ "_AutoDataCmp; }";
		else
			enum arrCode = "";

		static if (is(T == string) && is(std.string.cmp))
			enum dataCode = "{ int _AutoDataCmp = std.string.cmp(this." ~ name ~ ", _AutoDataOther." ~ name ~ "); if (_AutoDataCmp != 0) return " ~ reverseStr ~ "_AutoDataCmp; }";
		else
		static if (is(T == int))
			enum dataCode = "{ int _AutoDataCmp = this." ~ name ~ " - _AutoDataOther." ~ name ~ "; if (_AutoDataCmp != 0) return " ~ reverseStr ~ "_AutoDataCmp; }"; // TODO: use long?
		else
		static if (is(typeof(T.opCmp)))
			enum dataCode = nullCheck!(T, name, reverseStr)
			              ~ "{ int _AutoDataCmp = this." ~ name ~ ".opCmp(_AutoDataOther." ~ name ~ "); if (_AutoDataCmp != 0) return " ~ reverseStr ~ "_AutoDataCmp; }";
		else
			enum dataCode = "if (this." ~ name ~ " < _AutoDataOther." ~ name ~ ") return " ~ reverseStr ~ "(-1);" ~
			                "if (this." ~ name ~ " > _AutoDataOther." ~ name ~ ") return " ~ reverseStr ~ "( 1);";
		enum code = arrCode ~ dataCode;
	}
}

struct _ToStringDataHandler
{
	template getMixinSingle(T, string name)
	{
/*
		enum getMixinSingle = "
				static if (is(typeof(_AutoDataResult ~= " ~ name ~ ".toString())))
					_AutoDataResult ~= " ~ name ~ ".toString();
				else
					_AutoDataResult ~= to!string(" ~ name ~ ");
		";
*/
		static if (is(typeof(T.init.toString())))
			enum getMixinSingle = "_AutoDataResult ~= " ~ name ~ ".toString();";
		else
			enum getMixinSingle = "_AutoDataResult ~= to!string(" ~ name ~ ");";
	}

	template getMixinBody(T, string name)
	{
		// TODO: arrays of arrays
		static if (is(T U : U[]))
		{
			enum getMixinBody = "
				_AutoDataResult ~= ` [ `;
				foreach (_AutoDataArrayIndex, _AutoDataArrayItem; " ~ name ~ ")
				{
					if (_AutoDataArrayIndex) _AutoDataResult ~= ` , `;
					" ~ getMixinSingle!(U, "_AutoDataArrayItem") ~ "
				}
				_AutoDataResult ~= ` ] `;
			";
		}
		else
			enum getMixinBody = getMixinSingle!(T, name);
	}

	template getMixin(T, string name, bool reverseSort)
	{
		enum getMixin =
			"_AutoDataResult ~= `" ~ name ~ " = `;" ~
			getMixinBody!(T, name) ~
			"_AutoDataResult ~= ` `;";
	}
}
