/**
 * Some simple wave generator functions.
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

module ae.utils.sound.wave;

import std.algorithm;
import std.conv;
import std.math;
import std.range;

import ae.utils.math;
import ae.utils.range;

auto squareWave(T)(real interval)
{
	return infiniteIota!size_t
		.map!(n => cast(T)(T.max + cast(int)(n * 2 / interval) % 2));
}

auto sawToothWave(T)(real interval)
{
	return infiniteIota!size_t
		.map!(n => cast(T)((n % interval * 2 - interval) * T.max / interval));
}

auto triangleWave(T)(real interval)
{
	return infiniteIota!size_t
		.map!(n => cast(T)((abs(n % interval * 2 - interval) * 2 - interval) * T.max / interval));
}

auto sineWave(T)(real interval)
{
	return infiniteIota!size_t
		.map!(n => (sin(n * 2 * PI / interval) * T.max).to!T);
}

auto whiteNoise(T)()
{
	import std.random;
	return infiniteIota!size_t
		.map!(n => cast(T)Xorshift(cast(uint)n).front);
}

auto whiteNoiseSqr(T)()
{
	import std.random;
	return infiniteIota!size_t
		.map!(n => Xorshift(cast(uint)n).front % 2 ? T.max : T.min);
}

// Fade out this wave (multiply samples by a linearly descending factor).
auto fade(W)(W w)
{
	alias T = typeof(w.front);
	sizediff_t dur = w.length;
	return dur.iota.map!(p => cast(T)(w[p] * (dur-p) / dur));
}

// Stretch a wave with linear interpolation
auto stretch(W)(W wave, real factor)
{
	static if (is(typeof(wave.length)))
	{
		auto length = cast(size_t)(wave.length * factor);
		auto baseRange = length.iota;
	}
	else
		auto baseRange = infiniteIota!size_t;
	return baseRange
		.map!((n) {
				auto p = n / factor;
				auto ip = cast(size_t)p;
				return cast(typeof(wave.front))itpl(wave[ip], wave[ip+1], p, ip, ip+1);
		});
}
