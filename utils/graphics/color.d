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
 *   Vladimir Panteleev <ae@cy.md>
 */

module ae.utils.graphics.color;

import std.meta : AliasSeq;
import std.traits;

import ae.utils.math;
import ae.utils.meta;

/// Represents a tuple of samples, usually used to represent
/// a single color in some color space.
/// This helper type allows manipulating such tuples more easily,
/// and has special behavior for common color representations
/// (e.g. special treatment of the "a" field as an alpha channel,
/// and construction from hex strings for R/G/B colors).
/// `FieldTuple` is a field spec, as parsed by `ae.utils.meta.FieldList`.
/// By convention, each field's name indicates its purpose:
/// - `x`: padding
/// - `a`: alpha
/// - `l`: lightness (or grey, for monochrome images)
/// - others (`r`, `g`, `b`, etc.): color information

// TODO: figure out if we need alll these methods in the color type itself
// - code such as gamma conversion needs to create color types
//   - ReplaceType can't copy methods
//   - even if we move out all conventional methods, that still leaves operator overloading

struct Color(FieldTuple...)
{
	alias Spec = FieldTuple; ///
	mixin FieldList!FieldTuple;

	// A "dumb" type to avoid cyclic references.
	private struct Fields { mixin FieldList!FieldTuple; }

	/// Whether or not all channel fields have the same base type.
	// Only "true" supported for now, may change in the future (e.g. for 5:6:5)
	enum homogeneous = isHomogeneous!Fields();
	deprecated alias homogenous = homogeneous;

	/// The number of fields in this color type.
	enum channels = Fields.init.tupleof.length;

	/// Additional properties for homogeneous colors.
	static if (homogeneous)
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

	/// Additional properties for integer colors.
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
				auto vr = ._blend(v1, v0, x);
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
				f = ._blend(v1, v0, c1.a);
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
		if (op != "~" && op != "in")
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

	/// Implements conversion to a similar color type.
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

	/// Returns an instance of this color type
	/// with all fields set at their minimum values.
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

	/// Returns an instance of this color type
	/// with all fields set at their maximum values.
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

/// Definitions for common color types.
version(all)
{
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
}

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

/// Obtains the type of each channel for homogeneous colors.
template ChannelType(T)
{
	///
	static if (is(T == struct))
		alias ChannelType = T.ChannelType;
	else
		alias ChannelType = T;
}

private template TransformSpec(alias Transformer, Spec...)
{
	static if (Spec.length == 0)
		alias TransformSpec = Spec;
	else
	static if (is(typeof(Spec[0]) == string))
		alias TransformSpec = AliasSeq!(Spec[0], TransformSpec!(Transformer, Spec[1 .. $]));
	else
		alias TransformSpec = AliasSeq!(Transformer!(Spec[0]), TransformSpec!(Transformer, Spec[1 .. $]));
}

/// Resolves to a Color instance with a different ChannelType.
template TransformChannelType(COLOR, alias Transformer)
	if (isNumeric!COLOR)
{
	alias TransformChannelType = Transformer!COLOR;
}

/// ditto
template TransformChannelType(COLOR, alias Transformer)
	if (is(COLOR : Color!Spec, Spec...))
{
	static if (is(COLOR : Color!Spec, Spec...))
		alias TransformChannelType = Color!(TransformSpec!(Transformer, Spec));
}

/// ditto
template ChangeChannelType(COLOR, T)
{
	alias Transformer(_) = T;
	alias ChangeChannelType = TransformChannelType!(COLOR, Transformer);
}

static assert(is(ChangeChannelType!(RGB, ushort) == RGB16));
static assert(is(ChangeChannelType!(int, ushort) == ushort));

/// Wrapper around ExpandNumericType to only expand integer types.
template ExpandIntegerType(T, size_t bits)
{
	///
	static if (is(T:real))
		alias ExpandIntegerType = T;
	else
		alias ExpandIntegerType = ExpandNumericType!(T, bits);
}

/// Resolves to a Color instance with its ChannelType expanded by BYTES bytes.
alias ExpandChannelType(COLOR, int BYTES) =
	ChangeChannelType!(COLOR,
		ExpandNumericType!(ChannelType!COLOR, BYTES * 8));

/// Resolves to a Color instance with its ChannelType expanded by BYTES bytes and made signed.
alias ExpandChannelTypeSigned(COLOR, int BYTES) =
	ChangeChannelType!(COLOR,
		Signed!(ExpandNumericType!(ChannelType!COLOR, BYTES * 8)));

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

/// Implements conversion to a similar color type.
auto channelMap(T, alias expr = a => a, COLOR)(COLOR color)
if (is(T == struct) && is(COLOR == struct))
{
	T result;
	foreach (i, f; color.tupleof)
	{
		enum name = __traits(identifier, color.tupleof[i]);
		static assert(__traits(hasMember, result, name),
			"No matching field `" ~ name ~ "` in `" ~ T.stringof ~ "` when mapping from `" ~ COLOR.stringof ~ "`");
		__traits(getMember, result, name) = expr(__traits(getMember, color, name));
	}
	foreach (i, f; result.tupleof)
	{
		enum name = __traits(identifier, result.tupleof[i]);
		static assert(__traits(hasMember, color, name),
			"No matching field `" ~ name ~ "` in `" ~ COLOR.stringof ~ "` when mapping to `" ~ T.stringof ~ "`");
	}
	return result;
}

/// ditto
auto channelMap(alias expr, COLOR)(COLOR c)
if (is(COLOR == struct) && !is(expr == struct))
{
	alias Transformer(C) = typeof({ C v = void; return expr(v); }());
	alias T = TransformChannelType!(typeof(c), Transformer);
	return c.channelMap!(T, expr);
}

///
unittest
{
	// Effortlessly reordering channels with no modification.
	assert(RGB(1, 2, 3).channelMap!BGR == BGR(3, 2, 1));

	// Perform per-channel transformations.
	assert(RGB(1, 2, 3).channelMap!(v => cast(ubyte)(v + 1)) == RGB(2, 3, 4));

	// Perform per-channel transformations with a different resulting type, implicitly.
	assert(RGB(1, 2, 3).channelMap!(v => cast(ushort)(v + 1)) == RGB16(2, 3, 4));

	// Perform per-channel transformations with a different resulting type, explicitly.
	assert(RGB(1, 2, 3).channelMap!(RGB16, v => cast(ubyte)(v + 1)) == RGB16(2, 3, 4));
}

// ***************************************************************************

/// Color storage unit for as-is storage.
alias PlainStorageUnit(Color) = Color[1];

/// Color storage unit description for packed bit colors
/// (1-bit, 2-bit, 4-bit etc.)
struct BitStorageUnit(ValueType, size_t valueBits, StorageType, bool bigEndian)
{
	StorageType storageValue; /// Raw value.

	/// Array operations.
	enum length = StorageType.sizeof * 8 / valueBits;
	static assert(length * valueBits == StorageType.sizeof * 8, "Slack bits?");

	ValueType opIndex(size_t index) const
	{
		static if (bigEndian)
			index = length - 1 - index;
		auto shift = index * valueBits;
		return cast(ValueType)((storageValue >> shift) & valueMask);
	} /// ditto

	ValueType opIndexAssign(ValueType value, size_t index)
	{
		static if (bigEndian)
			index = length - 1 - index;
		auto shift = index * valueBits;
		StorageType mask = flipBits(cast(StorageType)(valueMask << shift));
		storageValue = (storageValue & mask) | cast(StorageType)(cast(StorageType)value << shift);
		return value;
	} /// ditto
private:
	enum StorageType valueMask = ((cast(StorageType)1) << valueBits) - 1;
}

/// 8 monochrome bits packed into a byte, in the usual big-endian order.
alias OneBitStorageBE = BitStorageUnit!(bool, 1, ubyte, true);
/// As above, but in little-endian order.
alias OneBitStorageLE = BitStorageUnit!(bool, 1, ubyte, false);

/// Get the color value of a storage unit type.
alias StorageColor(StorageType) = typeof(StorageType.init[0]);

/// The number of bits that one individual color takes up.
enum size_t storageColorBits(StorageType) = StorageType.sizeof * 8 / StorageType.length;

/// True when we can take the address of an individual color within a storage unit.
enum bool isStorageColorLValue(StorageType) = is(typeof({ StorageType s = void; return &s[0]; }()));

/// Construct a `StorageType` with all colors set to the indicated value.
StorageType solidStorageUnit(StorageType)(StorageColor!StorageType color)
{
	StorageType s;
	foreach (i; 0 .. StorageType.length)
		s[i] = color;
	return s;
}

// ***************************************************************************

/// Calculate an interpolated color on a gradient with multiple points
struct Gradient(Value, Color)
{
	/// Gradient points.
	struct Point
	{
		Value value; /// Distance along the gradient.
		Color color; /// Color at this point.
	}
	Point[] points; /// ditto

	/// Obtain the value at the given position.
	/// If `value` is before the first point, the first point's color is returned.
	/// If `value` is after the last point, the last point's color is returned.
	Color get(Value value) const
	{
		assert(points.length, "Gradient must have at least one point");

		if (value <= points[0].value)
			return points[0].color;

		for (size_t i = 1; i < points.length; i++)
		{
			assert(points[i-1].value <= points[i].value,
				"Gradient values are not in ascending order");
			if (value < points[i].value)
				return Color.itpl(
					points[i-1].color, points[i].color, value,
					points[i-1].value, points[i].value);
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

T _blend(T)(T f, T b, T a) if (is(typeof(f*a+flipBits(b)))) { return cast(T) ( ((f*a) + (b*flipBits(a))) / T.max ); }
deprecated alias blend = _blend;
