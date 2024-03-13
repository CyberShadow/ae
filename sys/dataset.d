/**
 * ae.sys.dataset
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

module ae.sys.dataset;

import std.algorithm.mutation : move;
import std.range.primitives : ElementType, front;

import ae.sys.data;
import ae.utils.array : asBytes, as;
import ae.utils.vec;

/// Copy a `Data` array's contents to a specified buffer.
T[] copyTo(R, T)(auto ref R data, T[] buffer)
if (is(ElementType!R == TData!T))
{
	size_t pos = 0;
	foreach (ref d; data)
	{
		d.enter((scope contents) {
			buffer[pos .. pos + contents.length] = contents[];
			pos += contents.length;
		});
	}
	assert(pos == buffer.length);
	return buffer;
}

deprecated void[] copyTo(R)(auto ref R data, void[] buffer)
if (is(ElementType!R == Data))
{
	return data.copyTo(cast(ubyte[])buffer);
}

/// Join an array of Data to a single Data.
TData!(DataElementType!(ElementType!R)) joinData(R)(auto ref R data)
if (is(ElementType!R == TData!T, T))
{
	alias T = DataElementType!(ElementType!R);

	if (data.length == 0)
		return TData!T();
	else
	if (data.length == 1)
		return data[0];

	size_t size = 0;
	foreach (ref d; data)
		size += d.length;
	TData!T result = TData!T(size);
	result.enter((scope T[] contents) {
		data.copyTo(contents);
	});
	return result;
}

version(ae_unittest) unittest
{
	assert(([TData!int([1]), TData!int([2])].joinData().unsafeContents) == [1, 2]);
	assert(cast(int[])([Data([1].asBytes), Data([2].asBytes)].joinData().unsafeContents) == [1, 2]);
}

/// Join an array of Data to a memory block on the managed heap.
DataElementType!(ElementType!R)[] joinToGC(R)(auto ref R data)
if (is(ElementType!R == TData!T, T))
{
	size_t size = 0;
	foreach (ref d; data)
		size += d.length;
	auto result = new DataElementType!(ElementType!R)[size];
	data.copyTo(result);
	return result;
}

version(ae_unittest) unittest
{
	assert(([TData!int([1]), TData!int([2])].joinToGC()) == [1, 2]);
	assert(cast(int[])([Data([1].asBytes), Data([2].asBytes)].joinToGC()) == [1, 2]);
}

deprecated @property void[] joinToHeap(R)(auto ref R data)
if (is(ElementType!R == Data))
{ return data.joinToGC(); }

version(ae_unittest) deprecated unittest
{
	assert(cast(int[])([Data([1].asBytes), Data([2].asBytes)].joinToHeap()) == [1, 2]);
}

/// A vector of `Data` with deterministic lifetime.
alias DataVec = Vec!Data;

/// Remove and return the specified number of bytes from the given `Data` array.
DataVec shift(ref DataVec data, size_t amount)
{
	auto bytes = data.bytes;
	auto result = bytes[0..amount];
	data = bytes[amount..bytes.length];
	return result;
}

/// Return a type that's indexable to access individual bytes,
/// and sliceable to get an array of `Data` over the specified
/// byte range. No actual `Data` concatenation is done.
@property DataSetBytes bytes(Data[] data) { return DataSetBytes(data); }
@property DataSetBytes bytes(ref DataVec data) { return DataSetBytes(data[]); } /// ditto

/// ditto
struct DataSetBytes
{
	Data[] data; /// Underlying `Data[]`.

	ubyte opIndex(size_t offset)
	{
		size_t index = 0;
		while (index < data.length && data[index].length <= offset)
		{
			offset -= data[index].length;
			index++;
		}
		return data[index].asDataOf!ubyte[offset];
	} ///

	DataVec opSlice()
	{
		return DataVec(data);
	} ///

	DataVec opSlice(size_t start, size_t end)
	{
		auto range = DataVec(data);
		while (range.length && range[0].length <= start)
		{
			start -= range[0].length;
			end   -= range[0].length;
			range.popFront();
		}
		if (range.length==0)
		{
			assert(start==0, "Range error");
			return range;
		}

		size_t endIndex = 0;
		while (endIndex < range.length && range[endIndex].length < end)
		{
			end -= range[endIndex].length;
			endIndex++;
		}
		range.length = endIndex + 1;
		range[$-1] = range[$-1][0..end];
		range[0  ] = range[0  ][start..range[0].length];
		return range;
	} ///

	@property
	size_t length()
	{
		size_t result = 0;
		foreach (ref d; data)
			result += d.length;
		return result;
	} ///

	size_t opDollar(size_t pos)()
	{
		static assert(pos == 0);
		return length;
	} ///
}

version(ae_unittest) unittest
{
	DataVec ds;
	string s;

	ds = DataVec(
		Data("aaaaa".asBytes),
	);
	s = ds.joinToGC().as!string;
	assert(s == "aaaaa");
	s = ds.bytes[].joinToGC().as!string;
	assert(s == "aaaaa");
	s = ds.bytes[1..4].joinToGC().as!string;
	assert(s == "aaa");

	ds = DataVec(
		Data("aaaaa".asBytes),
		Data("bbbbb".asBytes),
		Data("ccccc".asBytes),
	);
	auto dsb = ds.bytes;
	assert(dsb.length == 15);
	assert(dsb.length == 15);
	assert(dsb[ 4]=='a');
	assert(dsb[ 5]=='b');
	assert(dsb[ 9]=='b');
	assert(dsb[10]=='c');
	s = dsb[ 3..12].joinToGC().as!string;
	assert(s == "aabbbbbcc");
	s = ds.joinToGC().as!string;
	assert(s == "aaaaabbbbbccccc", s);
	s = dsb[ 0.. 6].joinToGC().as!string;
	assert(s == "aaaaab");
	s = dsb[ 9..15].joinToGC().as!string;
	assert(s == "bccccc");
	s = dsb[ 0.. 0].joinToGC().as!string;
	assert(s == "");
	s = dsb[15..15].joinToGC().as!string;
	assert(s == "");
}
