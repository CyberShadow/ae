/**
 * Color type and operations.
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

module ae.utils.graphics.color;

import std.traits;

import ae.utils.math;
import ae.utils.meta;

/// Instantiates to a color type.
/// FieldTuple is the color specifier, as parsed by
/// the FieldList template from ae.utils.meta.
/// By convention, each field's name indicates its purpose:
/// - x: padding
/// - a: alpha
/// - l: lightness (or grey, for monochrome images)
/// - others (r, g, b, etc.): color information

// TODO: figure out if we need alll these methods in the color type itself
// - code such as gamma conversion needs to create color types
//   - ReplaceType can't copy methods
//   - even if we move out all conventional methods, that still leaves operator overloading

struct Color(FieldTuple...)
{
	alias Spec = FieldTuple;
	mixin FieldList!FieldTuple;

	// A "dumb" type to avoid cyclic references.
	private struct Fields { mixin FieldList!FieldTuple; }

	/// Whether or not all channel fields have the same base type.
	// Only "true" supported for now, may change in the future (e.g. for 5:6:5)
	enum homogenous = isHomogenous!Fields();

	/// The number of fields in this color type.
	enum channels = Fields.init.tupleof.length;

	static if (homogenous)
	{
		alias ChannelType = typeof(Fields.init.tupleof[0]);
		enum channelBits = valueBits!ChannelType;
	}

	/// Return a Color instance with all fields set to "value".
	static typeof(this) monochrome(ChannelType value)
	{
		typeof(this) r;
		foreach (i, f; r.tupleof)
			static if (__traits(identifier, r.tupleof[i]) == "a")
				r.tupleof[i] = typeof(r.tupleof[i]).max;
			else
				r.tupleof[i] = value;
		return r;
	}

	static if (is(ChannelType:uint))
	{
		enum typeof(this) black = monochrome(0);
		enum typeof(this) white = monochrome(ChannelType.max);
	}

	/// Interpolate between two colors.
	/// See also: Gradient
	static typeof(this) itpl(P)(typeof(this) c0, typeof(this) c1, P p, P p0, P p1)
	{
		alias TryExpandNumericType!(ChannelType, P.sizeof*8) U;
		typeof(this) r;
		foreach (i, f; r.tupleof)
			static if (r.tupleof[i].stringof != "r.x") // skip padding
				r.tupleof[i] = cast(ChannelType).itpl(cast(U)c0.tupleof[i], cast(U)c1.tupleof[i], p, p0, p1);
		return r;
	}

	/// Alpha-blend two colors.
	static typeof(this) blend()(typeof(this) c0, typeof(this) c1)
		if (is(typeof(a)))
	{
		alias A = typeof(c0.a);
		A a = flipBits(cast(A)(c0.a.flipBits * c1.a.flipBits / A.max));
		if (!a)
			return typeof(this).init;
		A x = cast(A)(c1.a * A.max / a);

		typeof(this) r;
		foreach (i, f; r.tupleof)
			static if (r.tupleof[i].stringof == "r.x")
				{} // skip padding
			else
			static if (r.tupleof[i].stringof == "r.a")
				r.a = a;
			else
			{
				auto v0 = c0.tupleof[i];
				auto v1 = c1.tupleof[i];
				auto vr = .blend(v1, v0, x);
				r.tupleof[i] = vr;
			}
		return r;
	}

	/// Alpha-blend a color with an alpha channel on top of one without.
	static typeof(this) blend(C)(typeof(this) c0, C c1)
		if (!is(typeof(a)) && is(typeof(c1.a)))
	{
		alias A = typeof(c1.a);
		if (!c1.a)
			return c0;
		//A x = cast(A)(c1.a * A.max / a);

		typeof(this) r;
		foreach (i, ref f; r.tupleof)
		{
			enum name = __traits(identifier, r.tupleof[i]);
			static if (name == "x")
				{} // skip padding
			else
			static if (name == "a")
				static assert(false);
			else
			{
				auto v0 = __traits(getMember, c0, name);
				auto v1 = __traits(getMember, c1, name);
				f = .blend(v1, v0, c1.a);
			}
		}
		return r;
	}

	/// Construct an RGB color from a typical hex string.
	static if (is(typeof(this.r) == ubyte) && is(typeof(this.g) == ubyte) && is(typeof(this.b) == ubyte))
	{
		static typeof(this) fromHex(in char[] s)
		{
			import std.conv;
			import std.exception;

			enforce(s.length == 6 || (is(typeof(this.a) == ubyte) && s.length == 8), "Invalid color string");
			typeof(this) c;
			c.r = s[0..2].to!ubyte(16);
			c.g = s[2..4].to!ubyte(16);
			c.b = s[4..6].to!ubyte(16);
			static if (is(typeof(this.a) == ubyte))
			{
				if (s.length == 8)
					c.a = s[6..8].to!ubyte(16);
				else
					c.a = ubyte.max;
			}
			return c;
		}

		string toHex() const
		{
			import std.string;
			return format("%02X%02X%02X", r, g, b);
		}
	}

	/// Warning: overloaded operators preserve types and may cause overflows
	typeof(this) opUnary(string op)()
		if (op=="~" || op=="-")
	{
		typeof(this) r;
		foreach (i, f; r.tupleof)
			static if(r.tupleof[i].stringof != "r.x") // skip padding
				r.tupleof[i] = cast(typeof(r.tupleof[i])) unary!(op[0])(this.tupleof[i]);
		return r;
	}

	/// ditto
	typeof(this) opOpAssign(string op)(int o)
	{
		foreach (i, f; this.tupleof)
			static if(this.tupleof[i].stringof != "this.x") // skip padding
				this.tupleof[i] = cast(typeof(this.tupleof[i])) mixin(`this.tupleof[i]` ~ op ~ `=o`);
		return this;
	}

	/// ditto
	typeof(this) opOpAssign(string op, T)(T o)
		if (is(T==struct) && structFields!T == structFields!Fields)
	{
		foreach (i, f; this.tupleof)
			static if(this.tupleof[i].stringof != "this.x") // skip padding
				this.tupleof[i] = cast(typeof(this.tupleof[i])) mixin(`this.tupleof[i]` ~ op ~ `=o.tupleof[i]`);
		return this;
	}

	/// ditto
	typeof(this) opBinary(string op, T)(T o)
		if (op != "~")
	{
		auto r = this;
		mixin("r" ~ op ~ "=o;");
		return r;
	}

	/// Apply a custom operation for each channel. Example:
	/// COLOR.op!q{(a + b) / 2}(colorA, colorB);
	static typeof(this) op(string expr, T...)(T values)
	{
		static assert(values.length <= 10);

		string genVars(string channel)
		{
			string result;
			foreach (j, Tj; T)
			{
				static if (is(Tj == struct)) // TODO: tighter constraint (same color channels)?
					result ~= "auto " ~ cast(char)('a' + j) ~ " = values[" ~ cast(char)('0' + j) ~ "]." ~  channel ~ ";\n";
				else
					result ~= "auto " ~ cast(char)('a' + j) ~ " = values[" ~ cast(char)('0' + j) ~ "];\n";
			}
			return result;
		}

		typeof(this) r;
		foreach (i, f; r.tupleof)
			static if(r.tupleof[i].stringof != "r.x") // skip padding
			{
				mixin(genVars(r.tupleof[i].stringof[2..$]));
				r.tupleof[i] = mixin(expr);
			}
		return r;
	}

	T opCast(T)() const
	if (is(T==struct) && structFields!T == structFields!Fields)
	{
		static if (is(T == typeof(this)))
			return this;
		else
		{
			T t;
			foreach (i, f; this.tupleof)
				t.tupleof[i] = cast(typeof(t.tupleof[i])) this.tupleof[i];
			return t;
		}
	}

	/// Sum of all channels
	ExpandIntegerType!(ChannelType, ilog2(nextPowerOfTwo(channels))) sum()
	{
		typeof(return) result;
		foreach (i, f; this.tupleof)
			static if (this.tupleof[i].stringof != "this.x") // skip padding
				result += this.tupleof[i];
		return result;
	}

	static @property Color min()
	{
		Color result;
		foreach (ref v; result.tupleof)
			static if (is(typeof(typeof(v).min)))
				v = typeof(v).min;
			else
			static if (is(typeof(typeof(v).max)))
				v = -typeof(v).max;
		return result;
	}

	static @property Color max()
	{
		Color result;
		foreach (ref v; result.tupleof)
			static if (is(typeof(typeof(v).max)))
				v = typeof(v).max;
		return result;
	}
}

// The "x" has the special meaning of "padding" and is ignored in some circumstances
alias Color!(ubyte  , "r", "g", "b"     ) RGB    ;
alias Color!(ushort , "r", "g", "b"     ) RGB16  ;
alias Color!(ubyte  , "r", "g", "b", "x") RGBX   ;
alias Color!(ushort , "r", "g", "b", "x") RGBX16 ;
alias Color!(ubyte  , "r", "g", "b", "a") RGBA   ;
alias Color!(ushort , "r", "g", "b", "a") RGBA16 ;

alias Color!(ubyte  , "b", "g", "r"     ) BGR    ;
alias Color!(ubyte  , "b", "g", "r", "x") BGRX   ;
alias Color!(ubyte  , "b", "g", "r", "a") BGRA   ;

alias Color!(ubyte  , "l"               ) L8     ;
alias Color!(ushort , "l"               ) L16    ;
alias Color!(ubyte  , "l", "a"          ) LA     ;
alias Color!(ushort , "l", "a"          ) LA16   ;

alias Color!(byte   , "l"               ) S8     ;
alias Color!(short  , "l"               ) S16    ;

alias Color!(float  , "r", "g", "b"     ) RGBf   ;
alias Color!(double , "r", "g", "b"     ) RGBd   ;

unittest
{
	static assert(RGB.sizeof == 3);
	RGB[2] arr;
	static assert(arr.sizeof == 6);

	RGB hex = RGB.fromHex("123456");
	assert(hex.r == 0x12 && hex.g == 0x34 && hex.b == 0x56);

	BGRA hex2 = BGRA.fromHex("12345678");
	assert(hex2.r == 0x12 && hex2.g == 0x34 && hex2.b == 0x56 && hex2.a == 0x78);

	assert(RGB(1, 2, 3) + RGB(4, 5, 6) == RGB(5, 7, 9));

	RGB c = RGB(1, 1, 1);
	c += 1;
	assert(c == RGB(2, 2, 2));
	c += c;
	assert(c == RGB(4, 4, 4));
}

static assert(RGB.min == RGB(  0,   0,   0));
static assert(RGB.max == RGB(255, 255, 255));

unittest
{
	import std.conv;

	L8 r;

	r = L8.itpl(L8(100), L8(200), 15, 10, 20);
	assert(r ==  L8(150), text(r));
}

unittest
{
	import std.conv;

	LA r;

	r = LA.blend(LA(123,   0),
	             LA(111, 222));
	assert(r ==  LA(111, 222), text(r));

	r = LA.blend(LA(123, 213),
	             LA(111, 255));
	assert(r ==  LA(111, 255), text(r));

	r = LA.blend(LA(  0, 255),
	             LA(255, 100));
	assert(r ==  LA(100, 255), text(r));
}

unittest
{
	import std.conv;

	L8 r;

	r = L8.blend(L8(123),
	             LA(231, 0));
	assert(r ==  L8(123), text(r));

	r = L8.blend(L8(123),
	             LA(231, 255));
	assert(r ==  L8(231), text(r));

	r = L8.blend(L8(  0),
	             LA(255, 100));
	assert(r ==  L8(100), text(r));
}

unittest
{
	Color!(real, "r", "g", "b") c;
}

unittest
{
	const RGB c;
	RGB x = cast(RGB)c;
}

/// Obtains the type of each channel for homogenous colors.
template ChannelType(T)
{
	static if (is(T == struct))
		alias ChannelType = T.ChannelType;
	else
		alias ChannelType = T;
}

/// Resolves to a Color instance with a different ChannelType.
template ChangeChannelType(COLOR, T)
	if (isNumeric!COLOR)
{
	alias ChangeChannelType = T;
}

/// ditto
template ChangeChannelType(COLOR, T)
	if (is(COLOR : Color!Spec, Spec...))
{
	static assert(COLOR.homogenous, "Can't change ChannelType of non-homogenous Color");
	alias ChangeChannelType = Color!(T, COLOR.Spec[1..$]);
}

static assert(is(ChangeChannelType!(RGB, ushort) == RGB16));
static assert(is(ChangeChannelType!(int, ushort) == ushort));

/// Wrapper around ExpandNumericType to only expand numeric types.
template ExpandIntegerType(T, size_t bits)
{
	static if (is(T:real))
		alias ExpandIntegerType = T;
	else
		alias ExpandIntegerType = ExpandNumericType!(T, bits);
}

alias ExpandChannelType(COLOR, int BYTES) =
	ChangeChannelType!(COLOR,
		ExpandNumericType!(ChannelType!COLOR, BYTES * 8));

static assert(is(ExpandChannelType!(RGB, 1) == RGB16));

unittest
{
	alias RGBf = ChangeChannelType!(RGB, float);
	auto rgb = RGB(1, 2, 3);
	import std.conv : to;
	auto rgbf = rgb.to!RGBf();
	assert(rgbf.r == 1f);
	assert(rgbf.g == 2f);
	assert(rgbf.b == 3f);
}

// ***************************************************************************

/// Calculate an interpolated color on a gradient with multiple points
struct Gradient(Value, Color)
{
	struct Point
	{
		Value value;
		Color color;
	}
	Point[] points;

	Color get(Value value) const
	{
		assert(points.length, "Gradient must have at least one point");

		if (value <= points[0].value)
			return points[0].color;

		for (int i = 0; i < points.length - 1; i++)
		{
			assert(points[i].value <= points[i+1].value,
				"Gradient values are not in ascending order");
			if (value < points[i+1].value)
				return Color.itpl(points[i].color, points[i+1].color, value, points[i].value, points[i+1].value);
		}

		return points[$-1].color;
	}
}

unittest
{
	Gradient!(int, L8) grad;
	grad.points = [
		grad.Point(0, L8(0)),
		grad.Point(10, L8(100)),
	];

	assert(grad.get(-5) == L8(  0));
	assert(grad.get( 0) == L8(  0));
	assert(grad.get( 5) == L8( 50));
	assert(grad.get(10) == L8(100));
	assert(grad.get(15) == L8(100));
}

unittest
{
	Gradient!(float, L8) grad;
	grad.points = [
		grad.Point(0.0f, L8( 0)),
		grad.Point(0.5f, L8(10)),
		grad.Point(1.0f, L8(30)),
	];

	assert(grad.get(0.00f) == L8(  0));
	assert(grad.get(0.25f) == L8(  5));
	assert(grad.get(0.50f) == L8( 10));
	assert(grad.get(0.75f) == L8( 20));
	assert(grad.get(1.00f) == L8( 30));
}

// ***************************************************************************

// TODO: deprecate
T blend(T)(T f, T b, T a) if (is(typeof(f*a+flipBits(b)))) { return cast(T) ( ((f*a) + (b*flipBits(a))) / T.max ); }
