/**
 * ae.utils.sound.wave
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

auto squareWave(T)(real interval)
{
	return iota(size_t.max)
		.map!(n => cast(T)(T.max + cast(int)(n * 2 / interval) % 2));
}

auto sawToothWave(T)(real interval)
{
	return iota(size_t.max)
		.map!(n => cast(T)((n % interval * 2 - interval) * T.max / interval));
}

auto triangleWave(T)(real interval)
{
	return iota(size_t.max)
		.map!(n => cast(T)((abs(n % interval * 2 - interval) * 2 - interval) * T.max / interval));
}

auto sineWave(T)(real interval)
{
	return iota(size_t.max)
		.map!(n => (sin(n * 2 * PI / interval) * T.max).to!T);
}
