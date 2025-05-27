/**
 * ae.utils.rangeassoc
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

module ae.utils.rangeassoc;

import std.algorithm.comparison : min, max;
import std.container.rbtree;
import std.conv : to;
import std.exception : enforce;
import std.range : chain;
import std.traits : arity, Parameters;
import std.typecons;

/**
   Implements an associative array like type, which allows associating
   a value with a continuous range instead of a single key.
*/
struct IntervalAssocArray(K, V)
{
private:
	/// A pair of coordinates.
	/// Used as the result of a slice operation.
	struct Interval { K start, end; }

	/// The structure stored in the `RedBlackTree`.
	static struct Span
	{
		K start, end;

		// TODO: Remove * when https://github.com/dlang/phobos/pull/10755 is in all supported D versions
		V* value;
	}

	static int cmp(K a, K b) pure @safe nothrow @nogc { return a < b ? -1 : a > b ? 1 : 0; }

	// Comparison in done in multiple contexts:
	// 1. When sorting RedBlackTree nodes into an ordered tree.
	// 2. When searching for an element or range in the tree (using lowerBound/equalRange/upperBound).
	// The exact behavior we want depends on the context.
	// Because RedBlackTree doesn't allow a per-search "less" predicate,
	// we do a dirty trick and cast the entire tree temporarily to one which behaves how we want in that situation.

	// TODO: Remove template parameter when https://github.com/dlang/phobos/pull/10792 is in all supported D versions
	static int compareForStorage(A, B)(const ref A a, const ref B b) pure @safe nothrow @nogc
	{
		// Comparing two tree nodes.
		assert(a.value !is null && b.value !is null); // All stored nodes have a value
		assert(a is b || a.start >= b.end || a.end <= b.start); // Spans of tree nodes do not overlap.
		return cmp(a.start, b.start);
	}

	static int compareForPointSearch(A, B)(const ref A a, const ref B b) pure @safe nothrow @nogc
	{
		if (a.value is null)
		{
			assert(b.value !is null);
			return -compareForPointSearch(b, a);
		}
		assert(a.value !is null);
		if (b.value !is null)
			return compareForStorage(a, b);

		// We want to check if the sought point (b.start) is inside the node.
		auto p = b.start;
		return
			p < a.start ? 1 :
			p >= a.end ? -1 :
			0;
	}

	static int compareForIntersection(A, B)(const ref A a, const ref B b) pure @safe nothrow @nogc
	{
		if (a.value is null)
		{
			assert(b.value !is null);
			return -compareForIntersection(b, a);
		}
		assert(a.value !is null);
		if (b.value !is null)
			return compareForStorage(a, b);

		// We want to check if the sought range (in b) intersects with the node.
		return
			b.end <= a.start ? 1 :
			b.start >= a.end ? -1 :
			0;
	}

	// TODO: Revisit when https://github.com/dlang/phobos/pull/10792 is in all supported D versions
	template lessComparator(alias intComparator)
	{
		static bool lessComparator(A, B)(A a, B b) pure @safe nothrow @nogc
		{
			return intComparator(a, b) < 0;
		}
	}

	alias SpanTree = RedBlackTree!(Span, lessComparator!compareForStorage); // Default allowDuplicates = false
	SpanTree tree;

	ref auto treeWithComparison(alias comparator, bool allowDuplicates = false)() inout pure @trusted nothrow @nogc
	{
		// This is a hard cast which swaps the visible comparison predicate.
		// This is still memory-safe because the memory layout remains the same.
		return *cast(RedBlackTree!(Span, lessComparator!comparator, allowDuplicates)*)&tree;
	}

	alias treeWithPointComparison = treeWithComparison!compareForPointSearch;
	alias treeWithIntersectionComparison = treeWithComparison!(compareForIntersection, true);

	// Slow invariant, only enabled for ae unittests.
	debug(ae_unittest) invariant
	{
		if (!tree || tree.empty)
			return;

		bool first = true;
		K lastEnd;
		const(V)* lastValue;
		foreach (ref node; tree)
		{
			assert(first || node.start >= lastEnd, "Tree is not ordered");
			assert(node.value !is null, "Tree contains null value");
			assert(node.value !is lastValue, "Tree contains duplicate value pointers");
			first = false;
			lastEnd = node.end;
			lastValue = node.value;
		}
	}

	static struct ValueHolder { V value; }
	static V* copyValue(ref V value) pure @safe nothrow { return &(new ValueHolder(value)).value; }

	void needTree() pure @safe nothrow
	{
		if (!tree)
			tree = new SpanTree;
	}

	/// Ensure that the tree is fragmented at `key`.
	/// Helper, called before some internal operations.
	void fragment(ref K key) pure @safe nothrow
	{
		auto r = treeWithPointComparison.equalRange(Span(key));
		if (r.empty)
			return;

		assert(r.front.start <= key && key < r.front.end);
		if (r.front.start == key)
			return;

		tree.remove(r);
		tree.insert(Span(r.front.start, key, r.front.value));
		tree.insert(Span(key, r.front.end, copyValue(*r.front.value)));
	}

	/// Represents a continuous slice of this `IntervalAssocArray`.
	/// If `isFullSlice` is true, then this simply covers the entire array;
	/// otherwise, it is some subset between two points.
	struct Slice(bool isFullSlice)
	{
	private:
		SpanTree tree;

		// TODO: this is ugly
		inout(IntervalAssocArray) intervalAssocArray() inout
		{
			return inout(IntervalAssocArray)(tree);
		}

		static if (!isFullSlice)
		{
			K start, end;

			invariant
			{
				assert(start <= end);
			}

			void fragmentTree() pure @safe nothrow
			{
				if (tree)
				{
					intervalAssocArray.fragment(start);
					intervalAssocArray.fragment(end);
				}
			}
		}

	public:
		// Further slicing

		inout(typeof(this)) opIndex() inout pure @safe nothrow
		{
			return this;
		}

		Interval opSlice(size_t dim: 0)(K start, K end) pure @safe nothrow @nogc
		in (start <= end)
		{
			static if (!isFullSlice)
				assert(this.start <= start && end <= this.end, "Slice out of bounds");
			return Interval(start, end);
		}

		inout(PartialSlice) opIndex(Interval i) inout pure @safe nothrow
		{
			return inout(PartialSlice)(tree, i.start, i.end);
		}

		/// Get value at a certain point
		ref const(V) opIndex(K point) const pure @safe nothrow @nogc
		{
			static if (!isFullSlice)
			{
				if (point < start || point >= end)
					assert(false, "Index out of bounds");
			}

			if (!tree)
				assert(false, "IntervalAssocArray is empty");

			auto r = intervalAssocArray
				.treeWithPointComparison
				.equalRange(Span(point));

			if (r.empty)
				assert(false, "Index not found");

			return *r.front.value;
		}

		/// Check if a certain point is within this slice
		const(V)* opBinaryRight(string op : "in")(K key) const pure @safe nothrow @nogc
		{
			static if (!isFullSlice)
			{
				if (key < start || key >= end)
					return null;
			}

			if (!tree)
				return null;

			auto r = intervalAssocArray
				.treeWithPointComparison
				.equalRange(Span(key));

			if (r.empty)
				return null;

			return r.front.value;
		}

		private int opApplyImpl(this This, Dg)(scope Dg dg)
		{
			if (!tree)
				return 0;

			alias ValueParameter = Parameters!Dg[$-1];
			enum isConst = is(ValueParameter == const);
			enum mustFragment = {
				if (isFullSlice)
					return false; // we always scan the whole tree, fragmentation is not necessary
				else if (isConst)
					return false; // user cannot modify the value, it's safe to not fragment
				else
					return true; // user asked for mutable ref and specified a range, fragmentation is necessary
			}();

			static if (mustFragment)
				fragmentTree();

			static if (isFullSlice)
				alias iterExpr = tree;
			else
				auto iterExpr = intervalAssocArray
					.treeWithIntersectionComparison
					.equalRange(Span(start, end));

			foreach (ref span; iterExpr)
			{
				static if (arity!Dg == 3)
				{
					static if (isFullSlice)
						auto ret = dg(span.start, span.end, *span.value);
					else
					{
						auto start = max(span.start, this.start);
						auto end = min(span.end, this.end);
						auto ret = dg(start, end, *span.value);
					}
				}
				else
					auto ret = dg(*span.value);

				if (ret)
					return ret;
			}
			return 0;
		}

		// Note: we enumerate all overload combinations instead of using a function template to enable type inference for foreach variables

		// Note: ideally we would also allow iterating with a const variable over a non-const object,
		// as a simple way to indicate that fragmenting is not necessary,
		// however, due to limitations of D's function overloading,
		// it's not possible to have overload which differ only in delegate argument types.

		int opApply(scope int delegate(                ref const V value)                          dg) const                          { return opApplyImpl(dg); }
		int opApply(scope int delegate(                ref const V value)                    @nogc dg) const                    @nogc { return opApplyImpl(dg); }
		int opApply(scope int delegate(                ref const V value)            nothrow       dg) const            nothrow       { return opApplyImpl(dg); }
		int opApply(scope int delegate(                ref const V value)            nothrow @nogc dg) const            nothrow @nogc { return opApplyImpl(dg); }
		int opApply(scope int delegate(                ref const V value)      @safe               dg) const      @safe               { return opApplyImpl(dg); }
		int opApply(scope int delegate(                ref const V value)      @safe         @nogc dg) const      @safe         @nogc { return opApplyImpl(dg); }
		int opApply(scope int delegate(                ref const V value)      @safe nothrow       dg) const      @safe nothrow       { return opApplyImpl(dg); }
		int opApply(scope int delegate(                ref const V value)      @safe nothrow @nogc dg) const      @safe nothrow @nogc { return opApplyImpl(dg); }
		int opApply(scope int delegate(                ref const V value) pure                     dg) const pure                     { return opApplyImpl(dg); }
		int opApply(scope int delegate(                ref const V value) pure               @nogc dg) const pure               @nogc { return opApplyImpl(dg); }
		int opApply(scope int delegate(                ref const V value) pure       nothrow       dg) const pure       nothrow       { return opApplyImpl(dg); }
		int opApply(scope int delegate(                ref const V value) pure       nothrow @nogc dg) const pure       nothrow @nogc { return opApplyImpl(dg); }
		int opApply(scope int delegate(                ref const V value) pure @safe               dg) const pure @safe               { return opApplyImpl(dg); }
		int opApply(scope int delegate(                ref const V value) pure @safe         @nogc dg) const pure @safe         @nogc { return opApplyImpl(dg); }
		int opApply(scope int delegate(                ref const V value) pure @safe nothrow       dg) const pure @safe nothrow       { return opApplyImpl(dg); }
		int opApply(scope int delegate(                ref const V value) pure @safe nothrow @nogc dg) const pure @safe nothrow @nogc { return opApplyImpl(dg); }

		int opApply(scope int delegate(                ref       V value)                          dg)                                { return opApplyImpl(dg); }
		int opApply(scope int delegate(                ref       V value)                    @nogc dg)                                { return opApplyImpl(dg); }
		int opApply(scope int delegate(                ref       V value)            nothrow       dg)                  nothrow       { return opApplyImpl(dg); }
		int opApply(scope int delegate(                ref       V value)            nothrow @nogc dg)                  nothrow       { return opApplyImpl(dg); }
		int opApply(scope int delegate(                ref       V value)      @safe               dg)            @safe               { return opApplyImpl(dg); }
		int opApply(scope int delegate(                ref       V value)      @safe         @nogc dg)            @safe               { return opApplyImpl(dg); }
		int opApply(scope int delegate(                ref       V value)      @safe nothrow       dg)            @safe nothrow       { return opApplyImpl(dg); }
		int opApply(scope int delegate(                ref       V value)      @safe nothrow @nogc dg)            @safe nothrow       { return opApplyImpl(dg); }
		int opApply(scope int delegate(                ref       V value) pure                     dg)       pure                     { return opApplyImpl(dg); }
		int opApply(scope int delegate(                ref       V value) pure               @nogc dg)       pure                     { return opApplyImpl(dg); }
		int opApply(scope int delegate(                ref       V value) pure       nothrow       dg)       pure       nothrow       { return opApplyImpl(dg); }
		int opApply(scope int delegate(                ref       V value) pure       nothrow @nogc dg)       pure       nothrow       { return opApplyImpl(dg); }
		int opApply(scope int delegate(                ref       V value) pure @safe               dg)       pure @safe               { return opApplyImpl(dg); }
		int opApply(scope int delegate(                ref       V value) pure @safe         @nogc dg)       pure @safe               { return opApplyImpl(dg); }
		int opApply(scope int delegate(                ref       V value) pure @safe nothrow       dg)       pure @safe nothrow       { return opApplyImpl(dg); }
		int opApply(scope int delegate(                ref       V value) pure @safe nothrow @nogc dg)       pure @safe nothrow       { return opApplyImpl(dg); }

		int opApply(scope int delegate(K start, K end, ref const V value)                          dg) const                          { return opApplyImpl(dg); }
		int opApply(scope int delegate(K start, K end, ref const V value)                    @nogc dg) const                    @nogc { return opApplyImpl(dg); }
		int opApply(scope int delegate(K start, K end, ref const V value)            nothrow       dg) const            nothrow       { return opApplyImpl(dg); }
		int opApply(scope int delegate(K start, K end, ref const V value)            nothrow @nogc dg) const            nothrow @nogc { return opApplyImpl(dg); }
		int opApply(scope int delegate(K start, K end, ref const V value)      @safe               dg) const      @safe               { return opApplyImpl(dg); }
		int opApply(scope int delegate(K start, K end, ref const V value)      @safe         @nogc dg) const      @safe         @nogc { return opApplyImpl(dg); }
		int opApply(scope int delegate(K start, K end, ref const V value)      @safe nothrow       dg) const      @safe nothrow       { return opApplyImpl(dg); }
		int opApply(scope int delegate(K start, K end, ref const V value)      @safe nothrow @nogc dg) const      @safe nothrow @nogc { return opApplyImpl(dg); }
		int opApply(scope int delegate(K start, K end, ref const V value) pure                     dg) const pure                     { return opApplyImpl(dg); }
		int opApply(scope int delegate(K start, K end, ref const V value) pure               @nogc dg) const pure               @nogc { return opApplyImpl(dg); }
		int opApply(scope int delegate(K start, K end, ref const V value) pure       nothrow       dg) const pure       nothrow       { return opApplyImpl(dg); }
		int opApply(scope int delegate(K start, K end, ref const V value) pure       nothrow @nogc dg) const pure       nothrow @nogc { return opApplyImpl(dg); }
		int opApply(scope int delegate(K start, K end, ref const V value) pure @safe               dg) const pure @safe               { return opApplyImpl(dg); }
		int opApply(scope int delegate(K start, K end, ref const V value) pure @safe         @nogc dg) const pure @safe         @nogc { return opApplyImpl(dg); }
		int opApply(scope int delegate(K start, K end, ref const V value) pure @safe nothrow       dg) const pure @safe nothrow       { return opApplyImpl(dg); }
		int opApply(scope int delegate(K start, K end, ref const V value) pure @safe nothrow @nogc dg) const pure @safe nothrow @nogc { return opApplyImpl(dg); }

		int opApply(scope int delegate(K start, K end, ref       V value)                          dg)                                { return opApplyImpl(dg); }
		int opApply(scope int delegate(K start, K end, ref       V value)                    @nogc dg)                                { return opApplyImpl(dg); }
		int opApply(scope int delegate(K start, K end, ref       V value)            nothrow       dg)                  nothrow       { return opApplyImpl(dg); }
		int opApply(scope int delegate(K start, K end, ref       V value)            nothrow @nogc dg)                  nothrow       { return opApplyImpl(dg); }
		int opApply(scope int delegate(K start, K end, ref       V value)      @safe               dg)            @safe               { return opApplyImpl(dg); }
		int opApply(scope int delegate(K start, K end, ref       V value)      @safe         @nogc dg)            @safe               { return opApplyImpl(dg); }
		int opApply(scope int delegate(K start, K end, ref       V value)      @safe nothrow       dg)            @safe nothrow       { return opApplyImpl(dg); }
		int opApply(scope int delegate(K start, K end, ref       V value)      @safe nothrow @nogc dg)            @safe nothrow       { return opApplyImpl(dg); }
		int opApply(scope int delegate(K start, K end, ref       V value) pure                     dg)       pure                     { return opApplyImpl(dg); }
		int opApply(scope int delegate(K start, K end, ref       V value) pure               @nogc dg)       pure                     { return opApplyImpl(dg); }
		int opApply(scope int delegate(K start, K end, ref       V value) pure       nothrow       dg)       pure       nothrow       { return opApplyImpl(dg); }
		int opApply(scope int delegate(K start, K end, ref       V value) pure       nothrow @nogc dg)       pure       nothrow       { return opApplyImpl(dg); }
		int opApply(scope int delegate(K start, K end, ref       V value) pure @safe               dg)       pure @safe               { return opApplyImpl(dg); }
		int opApply(scope int delegate(K start, K end, ref       V value) pure @safe         @nogc dg)       pure @safe               { return opApplyImpl(dg); }
		int opApply(scope int delegate(K start, K end, ref       V value) pure @safe nothrow       dg)       pure @safe nothrow       { return opApplyImpl(dg); }
		int opApply(scope int delegate(K start, K end, ref       V value) pure @safe nothrow @nogc dg)       pure @safe nothrow       { return opApplyImpl(dg); }

		/// Deletes spans matching this slice's range from the array.
		void clear() pure @safe nothrow
		{
			if (!tree)
				return;

			static if (isFullSlice)
			{
				tree.clear();
			}
			else
			{
				if (start == end)
					return;

				fragmentTree();
				auto r = IntervalAssocArray(tree)
					.treeWithIntersectionComparison
					.equalRange(Span(start, end));
				tree.remove(r);
			}
		}

		/// Performs a shallow copy of this array / slice.
		// static if (is(typeof((ref const V a, ref V b) { b = a; })))
		IntervalAssocArray dup() pure @safe nothrow
		{
			if (!tree)
				return IntervalAssocArray(null);

			static if (isFullSlice)
			{
				auto tree = this.tree.dup;
				foreach (ref node; tree)
					node.value = copyValue(*node.value);
				return IntervalAssocArray(tree);
			}
			else
			{
				auto tree = new SpanTree;
				foreach (start, end, ref value; this)
					tree.insert(Span(start, end, copyValue(value)));
				return IntervalAssocArray(tree);
			}
		}

		/// Sets the array to have the given value at any point where it did not yet have a value,
		/// thus ensuring that it has some value at any point in this slice's range.
		static if (!isFullSlice)
		void require(V value) pure @safe nothrow
		{
			if (!tree)
				return;

			auto lastEnd = this.start;
			foreach (ref node; tree)
			{
				if (node.start > lastEnd)
					tree.insert(Span(lastEnd, node.start, copyValue(value)));
				if (node.end > lastEnd)
					lastEnd = node.end;
			}
			if (lastEnd < this.end)
				tree.insert(Span(lastEnd, this.end, copyValue(value)));
		}

		/// Updates this array so that this slice's range contains the given value.
		static if (!isFullSlice)
		void opAssign(V value) pure @safe nothrow
		{
			if (!tree)
				assert(false, "No tree");

			if (start == end)
				return;

			clear();
			tree.insert(Span(start, end, copyValue(value)));
		}

		/// Applies the given operator and operand over any existing spans matching this slice's range.
		void opOpAssign(string op, O)(O value) pure @safe nothrow
		if (is(typeof(mixin("(ref V v) { v " ~ op ~ "= value; }"))))
		{
			foreach (start, end, ref V v; this)
				mixin("v " ~ op ~ "= value;");
		}
	}

	alias FullSlice = Slice!true;
	alias PartialSlice = Slice!false;

public:
	// Slicing

	static Interval opSlice(size_t dim: 0)(K start, K end) pure @safe nothrow @nogc
	in (start <= end)
	{
		return Interval(start, end);
	}

	FullSlice opIndex() pure @safe nothrow
	{
		needTree();
		return FullSlice(tree);
	}

	inout(FullSlice) opIndex() inout pure @safe nothrow
	{
		return inout(FullSlice)(tree);
	}

	PartialSlice opIndex(Interval i) pure @safe nothrow
	{
		needTree();
		return PartialSlice(tree, i.start, i.end);
	}

	inout(PartialSlice) opIndex(Interval i) inout pure @safe nothrow
	{
		return inout(PartialSlice)(tree, i.start, i.end);
	}

	// Operations applicable to both slices and the array itself - forwarding to slice

	ref const(V) opIndex(K point) const pure @safe nothrow @nogc
	{
		return this.opIndex().opIndex(point);
	}

	const(V)* opBinaryRight(string op : "in")(K key) const pure @safe nothrow @nogc
	{
		return this.opIndex().opBinaryRight!op(key);
	}

	// Note: we enumerate all overload combinations instead of using a function template to enable type inference for foreach variables

	int opApply(scope int delegate(                ref const V value)                          dg) const                          { return this.opIndex().opApply(dg); }
	int opApply(scope int delegate(                ref const V value)                    @nogc dg) const                    @nogc { return this.opIndex().opApply(dg); }
	int opApply(scope int delegate(                ref const V value)            nothrow       dg) const            nothrow       { return this.opIndex().opApply(dg); }
	int opApply(scope int delegate(                ref const V value)            nothrow @nogc dg) const            nothrow @nogc { return this.opIndex().opApply(dg); }
	int opApply(scope int delegate(                ref const V value)      @safe               dg) const      @safe               { return this.opIndex().opApply(dg); }
	int opApply(scope int delegate(                ref const V value)      @safe         @nogc dg) const      @safe         @nogc { return this.opIndex().opApply(dg); }
	int opApply(scope int delegate(                ref const V value)      @safe nothrow       dg) const      @safe nothrow       { return this.opIndex().opApply(dg); }
	int opApply(scope int delegate(                ref const V value)      @safe nothrow @nogc dg) const      @safe nothrow @nogc { return this.opIndex().opApply(dg); }
	int opApply(scope int delegate(                ref const V value) pure                     dg) const pure                     { return this.opIndex().opApply(dg); }
	int opApply(scope int delegate(                ref const V value) pure               @nogc dg) const pure               @nogc { return this.opIndex().opApply(dg); }
	int opApply(scope int delegate(                ref const V value) pure       nothrow       dg) const pure       nothrow       { return this.opIndex().opApply(dg); }
	int opApply(scope int delegate(                ref const V value) pure       nothrow @nogc dg) const pure       nothrow @nogc { return this.opIndex().opApply(dg); }
	int opApply(scope int delegate(                ref const V value) pure @safe               dg) const pure @safe               { return this.opIndex().opApply(dg); }
	int opApply(scope int delegate(                ref const V value) pure @safe         @nogc dg) const pure @safe         @nogc { return this.opIndex().opApply(dg); }
	int opApply(scope int delegate(                ref const V value) pure @safe nothrow       dg) const pure @safe nothrow       { return this.opIndex().opApply(dg); }
	int opApply(scope int delegate(                ref const V value) pure @safe nothrow @nogc dg) const pure @safe nothrow @nogc { return this.opIndex().opApply(dg); }

	int opApply(scope int delegate(                ref       V value)                          dg)                                { return this.opIndex().opApply(dg); }
	int opApply(scope int delegate(                ref       V value)                    @nogc dg)                                { return this.opIndex().opApply(dg); }
	int opApply(scope int delegate(                ref       V value)            nothrow       dg)                  nothrow       { return this.opIndex().opApply(dg); }
	int opApply(scope int delegate(                ref       V value)            nothrow @nogc dg)                  nothrow       { return this.opIndex().opApply(dg); }
	int opApply(scope int delegate(                ref       V value)      @safe               dg)            @safe               { return this.opIndex().opApply(dg); }
	int opApply(scope int delegate(                ref       V value)      @safe         @nogc dg)            @safe               { return this.opIndex().opApply(dg); }
	int opApply(scope int delegate(                ref       V value)      @safe nothrow       dg)            @safe nothrow       { return this.opIndex().opApply(dg); }
	int opApply(scope int delegate(                ref       V value)      @safe nothrow @nogc dg)            @safe nothrow       { return this.opIndex().opApply(dg); }
	int opApply(scope int delegate(                ref       V value) pure                     dg)       pure                     { return this.opIndex().opApply(dg); }
	int opApply(scope int delegate(                ref       V value) pure               @nogc dg)       pure                     { return this.opIndex().opApply(dg); }
	int opApply(scope int delegate(                ref       V value) pure       nothrow       dg)       pure       nothrow       { return this.opIndex().opApply(dg); }
	int opApply(scope int delegate(                ref       V value) pure       nothrow @nogc dg)       pure       nothrow       { return this.opIndex().opApply(dg); }
	int opApply(scope int delegate(                ref       V value) pure @safe               dg)       pure @safe               { return this.opIndex().opApply(dg); }
	int opApply(scope int delegate(                ref       V value) pure @safe         @nogc dg)       pure @safe               { return this.opIndex().opApply(dg); }
	int opApply(scope int delegate(                ref       V value) pure @safe nothrow       dg)       pure @safe nothrow       { return this.opIndex().opApply(dg); }
	int opApply(scope int delegate(                ref       V value) pure @safe nothrow @nogc dg)       pure @safe nothrow       { return this.opIndex().opApply(dg); }

	int opApply(scope int delegate(K start, K end, ref const V value)                          dg) const                          { return this.opIndex().opApply(dg); }
	int opApply(scope int delegate(K start, K end, ref const V value)                    @nogc dg) const                    @nogc { return this.opIndex().opApply(dg); }
	int opApply(scope int delegate(K start, K end, ref const V value)            nothrow       dg) const            nothrow       { return this.opIndex().opApply(dg); }
	int opApply(scope int delegate(K start, K end, ref const V value)            nothrow @nogc dg) const            nothrow @nogc { return this.opIndex().opApply(dg); }
	int opApply(scope int delegate(K start, K end, ref const V value)      @safe               dg) const      @safe               { return this.opIndex().opApply(dg); }
	int opApply(scope int delegate(K start, K end, ref const V value)      @safe         @nogc dg) const      @safe         @nogc { return this.opIndex().opApply(dg); }
	int opApply(scope int delegate(K start, K end, ref const V value)      @safe nothrow       dg) const      @safe nothrow       { return this.opIndex().opApply(dg); }
	int opApply(scope int delegate(K start, K end, ref const V value)      @safe nothrow @nogc dg) const      @safe nothrow @nogc { return this.opIndex().opApply(dg); }
	int opApply(scope int delegate(K start, K end, ref const V value) pure                     dg) const pure                     { return this.opIndex().opApply(dg); }
	int opApply(scope int delegate(K start, K end, ref const V value) pure               @nogc dg) const pure               @nogc { return this.opIndex().opApply(dg); }
	int opApply(scope int delegate(K start, K end, ref const V value) pure       nothrow       dg) const pure       nothrow       { return this.opIndex().opApply(dg); }
	int opApply(scope int delegate(K start, K end, ref const V value) pure       nothrow @nogc dg) const pure       nothrow @nogc { return this.opIndex().opApply(dg); }
	int opApply(scope int delegate(K start, K end, ref const V value) pure @safe               dg) const pure @safe               { return this.opIndex().opApply(dg); }
	int opApply(scope int delegate(K start, K end, ref const V value) pure @safe         @nogc dg) const pure @safe         @nogc { return this.opIndex().opApply(dg); }
	int opApply(scope int delegate(K start, K end, ref const V value) pure @safe nothrow       dg) const pure @safe nothrow       { return this.opIndex().opApply(dg); }
	int opApply(scope int delegate(K start, K end, ref const V value) pure @safe nothrow @nogc dg) const pure @safe nothrow @nogc { return this.opIndex().opApply(dg); }

	int opApply(scope int delegate(K start, K end, ref       V value)                          dg)                                { return this.opIndex().opApply(dg); }
	int opApply(scope int delegate(K start, K end, ref       V value)                    @nogc dg)                                { return this.opIndex().opApply(dg); }
	int opApply(scope int delegate(K start, K end, ref       V value)            nothrow       dg)                  nothrow       { return this.opIndex().opApply(dg); }
	int opApply(scope int delegate(K start, K end, ref       V value)            nothrow @nogc dg)                  nothrow       { return this.opIndex().opApply(dg); }
	int opApply(scope int delegate(K start, K end, ref       V value)      @safe               dg)            @safe               { return this.opIndex().opApply(dg); }
	int opApply(scope int delegate(K start, K end, ref       V value)      @safe         @nogc dg)            @safe               { return this.opIndex().opApply(dg); }
	int opApply(scope int delegate(K start, K end, ref       V value)      @safe nothrow       dg)            @safe nothrow       { return this.opIndex().opApply(dg); }
	int opApply(scope int delegate(K start, K end, ref       V value)      @safe nothrow @nogc dg)            @safe nothrow       { return this.opIndex().opApply(dg); }
	int opApply(scope int delegate(K start, K end, ref       V value) pure                     dg)       pure                     { return this.opIndex().opApply(dg); }
	int opApply(scope int delegate(K start, K end, ref       V value) pure               @nogc dg)       pure                     { return this.opIndex().opApply(dg); }
	int opApply(scope int delegate(K start, K end, ref       V value) pure       nothrow       dg)       pure       nothrow       { return this.opIndex().opApply(dg); }
	int opApply(scope int delegate(K start, K end, ref       V value) pure       nothrow @nogc dg)       pure       nothrow       { return this.opIndex().opApply(dg); }
	int opApply(scope int delegate(K start, K end, ref       V value) pure @safe               dg)       pure @safe               { return this.opIndex().opApply(dg); }
	int opApply(scope int delegate(K start, K end, ref       V value) pure @safe         @nogc dg)       pure @safe               { return this.opIndex().opApply(dg); }
	int opApply(scope int delegate(K start, K end, ref       V value) pure @safe nothrow       dg)       pure @safe nothrow       { return this.opIndex().opApply(dg); }
	int opApply(scope int delegate(K start, K end, ref       V value) pure @safe nothrow @nogc dg)       pure @safe nothrow       { return this.opIndex().opApply(dg); }

	/// Clear the entire array.
	void clear() pure @safe nothrow { this.opIndex().clear(); }

	/// Performs a shallow copy of this array.
	IntervalAssocArray dup() pure @safe nothrow { return this.opIndex().dup(); }

	/// Joins adjacent elements with the same value into a single span.
	static if (is(typeof((ref V v) => v == v)))
	void defragment()
	{
		if (!tree || tree.length < 2)
			return;

		Span[] newSpans;
		foreach (ref span; tree)
			if (newSpans.length > 0 && newSpans[$-1].end == span.start && *newSpans[$-1].value == *span.value)
				newSpans[$-1].end = span.end;
			else
				newSpans ~= span;
		tree = new SpanTree(newSpans);
	}
}

debug(ae_unittest) pure @safe nothrow unittest
{
	IntervalAssocArray!(int, string) a;

	// Test basic assignment and retrieval
	a[0..5] = "hello";
	assert(a[2] == "hello");
	assert(a[0..5][3] == "hello");

	// Test overlapping assignment
	a[2..7] = "world";
	assert(a[1] == "hello");
	assert(a[3] == "world");
	assert(a[6] == "world");

	// Test non-overlapping assignment
	a[10..15] = "test";
	assert(a[12] == "test");

	// Test 'in' operator
	assert(5 in a);
	assert(8 !in a);

	// Test iteration
	int count = 0;
	foreach (start, end, ref value; a)
	{
		count++;
		assert(start < end);
	}
	assert(count == 3);

	// Test clear
	a.clear();
	assert(0 !in a);
	assert(5 !in a);
	assert(12 !in a);

	// Test complex overlapping assignments
	a[0..10] = "A";
	a[5..15] = "B";
	a[2..7] = "C";
	assert(a[1] == "A");
	assert(a[3] == "C");
	assert(a[6] == "C");
	assert(a[8] == "B");
	assert(a[12] == "B");

	// Test slice retrieval
	auto slice = a[4..9];
	assert(slice[4] == "C");
	assert(slice[8] == "B");
	assert(3 !in slice);

	// Test slice op-assign
	a[4..9] ~= "D";
	assert(a[1] == "A");
	assert(a[3] == "C");
	assert(a[4] == "CD");
	assert(a[8] == "BD");
	assert(a[9] == "B");

	// Test defragmentation
	a.clear();
	a[0..2] = "A";
	a[1..3] = "B";
	a[2..4] = "C";
	a[1..2] = "A";
	a[2..4] = "A";
	a.defragment();
	int n;
	foreach (start, end, ref value; a)
		n++;
	assert(n == 1);
}

debug(ae_unittest) @nogc unittest
{
	const IntervalAssocArray!(int, string) a;
	foreach (start, end, ref value; a)
		assert(start < end);
}

debug(ae_unittest) pure @safe nothrow unittest
{
	IntervalAssocArray!(int, string) a;

	// Test require on empty array
	a[0 .. 5].require("A");
	assert(a[0] == "A");
	assert(a[2] == "A");
	assert(a[4] == "A");
	assert(2 in a);
	assert(6 !in a);

	// Test require on existing range (should not overwrite)
	a[2 .. 7].require("B");
	assert(a[2] == "A");
	assert(a[4] == "A");
	assert(a[5] == "B");
	assert(a[6] == "B");

	// Test require with gap
	a[10 .. 15].require("C");
	assert(a[12] == "C");
	assert(9 !in a);

	// Test require filling gaps between existing ranges
	a[0 .. 15].require("D");
	assert(a[2] == "A");  // still A
	assert(a[5] == "B");  // still B
	assert(a[7] == "D");  // gap filled with D
	assert(a[8] == "D");  // gap filled with D
	assert(a[9] == "D");  // gap filled with D
	assert(a[12] == "C"); // still C

	// Test require with overlapping ranges
	a.clear();
	a[3..7] = "P";
	a[9..12] = "Q";
	a[0 .. 15].require("R");
	assert(a[1] == "R");   // gap before P
	assert(a[5] == "P");   // still P
	assert(a[8] == "R");   // gap between P and Q
	assert(a[10] == "Q");  // still Q
	assert(a[13] == "R");  // gap after Q

	// Test empty range (should do nothing)
	a.clear();
	a[0..5] = "A";
	a[2 .. 2].require("B");
	assert(a[2] == "A");
}

debug(ae_unittest) pure @safe nothrow unittest
{
	IntervalAssocArray!(int, string) a;

	a[2..4] = "1";
	auto b = a.dup;
	a[2..4] = "2";
	assert(a[3] == "2");
	assert(b[3] == "1");
}

debug(ae_unittest) pure @safe nothrow unittest
{
	struct State { int value; }
	IntervalAssocArray!(int, State) a;
}

debug(ae_unittest) pure @safe nothrow unittest
{
	struct State { int[] value; }
	IntervalAssocArray!(int, State) a;
}
