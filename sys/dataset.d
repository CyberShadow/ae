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
import std.range.primitives : ElementType;

import ae.sys.data;
import ae.utils.vec;

/// Copy a `Data` array's contents to a specified buffer.
void[] copyTo(R)(auto ref R data, void[] buffer)
if (is(ElementType!R == Data))
{
	size_t pos = 0;
	foreach (ref d; data)
	{
		buffer[pos .. pos + d.length] = d.contents[];
		pos += d.length;
	}
	assert(pos == buffer.length);
	return buffer;
}

/// Join an array of Data to a single Data.
Data joinData(R)(auto ref R data)
if (is(ElementType!R == Data))
{
	if (data.length == 0)
		return Data();
	else
	if (data.length == 1)
		return data[0];

	size_t size = 0;
	foreach (ref d; data)
		size += d.length;
	Data result = Data(size);
	data.copyTo(result.mcontents);
	return result;
}

unittest
{
	assert(cast(int[])([Data([1]), Data([2])].joinData().contents) == [1, 2]);
}

/// Join an array of Data to a memory block on the managed heap.
@property
void[] joinToHeap(R)(auto ref R data)
if (is(ElementType!R == Data))
{
	size_t size = 0;
	foreach (ref d; data)
		size += d.length;
	auto result = new void[size];
	data.copyTo(result);
	return result;
}

unittest
{
	assert(cast(int[])([Data([1]), Data([2])].joinToHeap()) == [1, 2]);
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
		return (cast(ubyte[])data[index].contents)[offset];
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

unittest
{
	DataVec ds;
	string s;

	ds = DataVec(
		Data("aaaaa"),
	);
	s = cast(string)(ds.joinToHeap);
	assert(s == "aaaaa");
	s = cast(string)(ds.bytes[].joinToHeap);
	assert(s == "aaaaa");
	s = cast(string)(ds.bytes[1..4].joinToHeap);
	assert(s == "aaa");

	ds = DataVec(
		Data("aaaaa"),
		Data("bbbbb"),
		Data("ccccc"),
	);
	auto dsb = ds.bytes;
	assert(dsb.length == 15);
	assert(dsb.length == 15);
	assert(dsb[ 4]=='a');
	assert(dsb[ 5]=='b');
	assert(dsb[ 9]=='b');
	assert(dsb[10]=='c');
	s = cast(string)(dsb[ 3..12].joinToHeap);
	assert(s == "aabbbbbcc");
	s = cast(string)(ds.joinToHeap);
	assert(s == "aaaaabbbbbccccc", s);
	s = cast(string)(dsb[ 0.. 6].joinToHeap);
	assert(s == "aaaaab");
	s = cast(string)(dsb[ 9..15].joinToHeap);
	assert(s == "bccccc");
	s = cast(string)(dsb[ 0.. 0].joinToHeap);
	assert(s == "");
	s = cast(string)(dsb[15..15].joinToHeap);
	assert(s == "");
}
