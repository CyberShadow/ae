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
 * Portions created by the Initial Developer are Copyright (C) 2007-2011
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

/// Number stuff
module ae.utils.math;

public import std.algorithm : min, max, abs, swap;
public import std.math;
import std.traits : Signed, Unsigned;

typeof(Ta+Tb+Tc) bound(Ta, Tb, Tc)(Ta a, Tb b, Tc c) { return a<b?b:a>c?c:a; }
bool between(T)(T point, T a, T b) { return a <= point && point <= b; } /// Assumes points are sorted (was there a faster way?)
auto sqr(T)(T x) { return x*x; }

void sort2(T)(ref T x, ref T y) { if (x > y) { T z=x; x=y; y=z; } }

T itpl(T, U)(T low, T high, U r, U rLow, U rHigh)
{
	return cast(T)(low + (cast(Signed!T)high-cast(Signed!T)low) * (cast(Signed!U)r - cast(Signed!U)rLow) / (cast(Signed!U)rHigh - cast(Signed!U)rLow));
}

byte sign(T)(T x) { return x<0 ? -1 : x>0 ? 1 : 0; }

auto op(string OP, T...)(T args)
{
	auto result = args[0];
	foreach (arg; args[1..$])
		mixin("result" ~ OP ~ "=arg;");
	return result;
}

auto sum(T...)(T args) { return op!"+"(args); }
auto average(T...)(T args) { return sum(args) / args.length; }

T bswap(T)(T b)
{
	static if (b.sizeof == 1)
		return b;
	else
	static if (b.sizeof == 2)
		return cast(T)((b >> 8) | (b << 8));
	else
	static if (b.sizeof == 4)
		return core.bitop.bswap(b);
	else
		static assert(false, "Don't know how to bswap " ~ T.stringof);
}
