/**
 * Data structure for optimized "sparse" N-dimensional matrices
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

module ae.utils.mapset;

import std.algorithm.iteration;
import std.array;
import std.exception;

import ae.utils.aa;

/**
   Data structure for holding optimized "sparse" N-dimensional matrices.
   The number of dimensions is arbitrary and can be varied at runtime.

   Unlike classical sparse arrays/matrices, this data structure is
   optimized not just for arrays which are mostly zero (or any given
   value), but for any matrices where data is likely to repeat across
   dimensions.

   This is done by storing the data as a tree, with each depth
   representing one dimension. A sub-tree is, thus, a sub-matrix
   (slice of the matrix represented by the top-level tree) along the
   top-level dimension. Each sub-tree is individually immutable, and
   can therefore be shared within the same tree or even by several
   instances of this type.

   Dimension order need not be the same for all sub-trees. Even the
   number of dimensions in siblings' sub-trees need not be the same;
   i.e, the data structure is itself sparse with regards to the
   dimensions.

   As there is no explicit "value" type (associated with every set of
   coordinates), this data structure can be seen as a representation
   of a set of points, but it can be simulated by adding a "value"
   dimension (in the same way how a gray-scale image can be
   represented as a set of 3D points like a height-map).

   An alternative way to look at this data structure is as a set of
   maps (i.e. associative arrays). Thus, each layer of the tree stores
   one possible map key, and under it, all the maps that have this key
   with a specific value. Note that for this use case, DimValue needs
   to have a value (configured using nullValue) which indicates the
   absence of a certain key (dimension) in a map.

   Params:
     DimName = The type used to indicate the name (or index) of a dimension.
     DimValue = The type for indicating a point on a dimension's axis.
     nullValue = A value for DimValue indicating that a dimension is unset
 */
struct MapSet(DimName, DimValue, DimValue nullValue = DimValue.init)
{
	alias ValueSet = HashSet!DimValue;

	struct Node
	{
		DimName dim;
		ValueSet[MapSet] children;

		immutable this(DimName dim, immutable ValueSet[MapSet] children)
		{
			// Zero children doesn't make sense.
			// It would be the equivalent of an empty set,
			// but then we should just use MapSet.emptySet instead.
			assert(!children.byValue.empty, "Node with zero children");

			this.dim = dim;
			this.children = children;

			// Because each submatrix is immutable, we can
			// pre-calculate the hash during construction.
			hash = hashOf(dim) ^ hashOf(children);

			size_t totalNodes = 1;
			foreach (submatrix, ref values; children)
				if (submatrix !is emptySet && submatrix !is unitSet)
					totalNodes += submatrix.root.totalNodes;
			this.totalNodes = totalNodes;
		}

		immutable this(DimName dim, immutable MapSet[DimValue] childMap)
		{
			ValueSet[MapSet] children;
			foreach (value, submatrix; childMap)
				children.require(submatrix, ValueSet.init).add(value);
			this(dim, cast(immutable) children);
		}

		void toString(scope void delegate(const(char)[]) sink) const
		{
			import std.format : formattedWrite;
			sink.formattedWrite("{ %(%s%), [ ", (&dim)[0..1]);
			bool first = true;
			foreach (submatrix, ref values; children)
			{
				if (first)
					first = false;
				else
					sink(", ");
				sink.formattedWrite("[ %(%s, %) ] : %s", values.byKey, submatrix);
			}
			sink(" ] }");
		}

		private hash_t hash;
		size_t totalNodes;

		hash_t toHash() const @safe pure nothrow
		{
			return hash;
		}

		bool opEquals(ref const typeof(this) s) const @safe pure nothrow
		{
			return hash == s.hash && dim == s.dim && children == s.children;
		}
	}

	/// Indicates the empty set.
	/// May only occur at the top level (never as a submatrix).
	private enum emptySetRoot = cast(immutable(Node)*)1;

	/// If emptySetRoot, zero values.
	/// If null, one value with zero dimensions.
	/// Otherwise, pointer to node describing the next dimension.
	immutable(Node)* root = emptySetRoot;

	/// A set containing a single nil-dimensional element.
	/// Holds exactly one value (a point with all dimensions at
	/// nullValue).
	enum unitSet = MapSet(null);

	/// The empty set. Represents a set which holds zero values.
	enum emptySet = MapSet(emptySetRoot);

	/// Combine two matrices together, returning their union.
	/// If `other` is a subset of `this`, return `this` unchanged.
	MapSet merge(MapSet other) const
	{
		if (this is emptySet) return other;
		if (other is emptySet) return this;
		if (this is unitSet && other is unitSet) return unitSet;
		if (!root) return bringToFront(other.root.dim).merge(other);

		other = other.bringToFront(root.dim);

		MapSet[MapSet][MapSet] mergeCache;

		MapSet[DimValue] newChildren;
		foreach (submatrix, ref values; root.children)
			foreach (value; values)
				newChildren[value] = submatrix;

		bool modified;
		foreach (submatrix, ref values; other.root.children)
			foreach (value; values)
				newChildren.updateVoid(value,
					{
						modified = true;
						return submatrix;
					},
					(ref MapSet oldSubmatrix)
					{
						auto mergeResult = mergeCache
							.require(oldSubmatrix, null)
							.require(submatrix, oldSubmatrix.merge(submatrix));
						if (oldSubmatrix !is mergeResult)
						{
							oldSubmatrix = mergeResult;
							modified = true;
						}
					}
				);

		if (!modified)
			return this;

		return MapSet(new immutable Node(root.dim, cast(immutable) newChildren));
	}

	/// Return the difference between `this` and the given set.
	/// If `other` does not intersect with `this`, return `this` unchanged.
	MapSet subtract(MapSet other) const
	{
		if (this is emptySet) return this;
		if (other is emptySet) return this;
		if (this is unitSet && other is unitSet) return emptySet;
		if (!root) return bringToFront(other.root.dim).subtract(other);

		other = other.bringToFront(root.dim);

		MapSet[MapSet][MapSet] subtractCache;

		MapSet[DimValue] newChildren;
		foreach (submatrix, ref values; root.children)
			foreach (value; values)
				newChildren[value] = submatrix;
		bool modified;
		foreach (submatrix, ref values; other.root.children)
			foreach (value; values)
				if (auto poldSubmatrix = value in newChildren)
				{
					auto subtractResult = subtractCache
						.require(*poldSubmatrix, null)
						.require(submatrix, poldSubmatrix.subtract(submatrix));
					if (*poldSubmatrix !is subtractResult)
					{
						*poldSubmatrix = subtractResult;
						if (subtractResult is emptySet)
							newChildren.remove(value);
						modified = true;
					}
				}

		if (!modified)
			return this;
		if (!newChildren.length)
			return emptySet;

		return MapSet(new immutable Node(root.dim, cast(immutable) newChildren));
	}

	private static void mergeValues(ref ValueSet target, ValueSet newValues)
	{
		if (target.empty)
			target = newValues;
		else
			foreach (value; newValues)
				target.add(value);
	}

	private static void mergeChildren(ref ValueSet[MapSet] target, MapSet submatrix, ValueSet newValues)
	{
		target.updateVoid(submatrix,
			() => newValues,
			(ref ValueSet oldValues) { mergeValues(oldValues, newValues); },
		);
	}

	/// "Unset" a given dimension, removing it from the matrix.
	/// The result is the union of all sub-matrices for all values of `dim`.
	MapSet remove(DimName dim) const
	{
		if (this is emptySet || this is unitSet) return this;
		if (root.dim == dim)
		{
			MapSet result;
			foreach (submatrix, ref values; root.children)
				result.merge(submatrix);
			return result;
		}
		// Defer allocation until the need to mutate
		size_t i;
		foreach (submatrix, ref values; root.children) // Read-only scan
		{
			auto newSubmatrix = submatrix.remove(dim);
			if (newSubmatrix !is submatrix)
			{
				ValueSet[MapSet] newChildren;
				size_t j;
				// Restart scan with mutation
				foreach (submatrix2, values2; root.children)
				{
					if (j < i)
					{
						// Known to not need mutation
						newChildren[submatrix2] = cast() values2;
						j++;
					}
					else
					if (j == i)
					{
						// Reuse already calculated result
						assert(values == values2);
						mergeChildren(newChildren, newSubmatrix, cast() values2);
						j++;
					}
					else
					{
						// Not yet scanned, do so now
						mergeChildren(newChildren, submatrix2.remove(dim), cast() values2);
					}
				}
				return MapSet(new immutable Node(root.dim, cast(immutable) newChildren));
			}
			i++;
		}
		return this; // No mutation necessary
	}

	/// Set the given dimension to always have the given value,
	/// collapsing (returning the union of) all sub-matrices
	/// for previously different values of `dim`.
	MapSet set(DimName dim, DimValue value) const
	{
		if (this is emptySet) return emptySet;
		return MapSet(new immutable Node(dim, cast(immutable) [this.remove(dim) : ValueSet([value])]));
	}

	/// Return a sub-matrix for all points where the given dimension has this value.
	/// Note: if `dim` doesn't occur (e.g. because `this` is the unit set) and `value` is `nullValue,
	/// this returns the unit set (not the empty set).
	MapSet get(DimName dim, DimValue value) const
	{
		if (this is emptySet) return emptySet;
		foreach (submatrix, ref values; bringToFront(dim).root.children)
			if (value in values)
				return submatrix;
		return emptySet;
	}

	/// Return all unique values occurring for a given dimension.
	/// Unless this is the empty set, the return value is always non-empty.
	/// If `dim` doesn't occur, it will be `[nullValue]`.
	DimValue[] all(DimName dim) const
	{
		if (this is emptySet) return null;
		return bringToFront(dim).root.children.byValue.map!((ref values) => values.byKey).join;
	}

	/// Refactor this matrix into one with the same data,
	/// but putting the given dimension in front.
	private MapSet bringToFront(DimName dim) const
	{
		assert(this !is emptySet);

		if (this is unitSet)
		{
			// We reached the bottom, and did not find `dim` along the way.
			// Create it now.
			return MapSet(new immutable Node(dim, [nullValue : unitSet]));
		}

		if (dim == root.dim)
		{
			// Already at the front.
			return this;
		}

		// 1. Recurse.
		// 2. After recursion, all children should have `dim` at the front.
		// So, just swap this layer with the next one.

		MapSet[DimValue][DimValue] submatrices;
		foreach (submatrix, ref values; root.children)
			foreach (value; values)
			{
				auto newSubmatrix = submatrix.bringToFront(dim);
				assert(newSubmatrix.root.dim == dim);
				if (newSubmatrix.root.children.byKey.empty)
					submatrices[nullValue][value] = MapSet();
				else
				foreach (submatrix2, values2; newSubmatrix.root.children)
					foreach (value2; values2)
						submatrices[value2][value] = submatrix2;
			}
		MapSet[DimValue] newChildren;
		foreach (value, children; submatrices)
			newChildren[value] = MapSet(new immutable Node(root.dim, cast(immutable) children));
		return MapSet(new immutable Node(dim, cast(immutable) newChildren));
	}

	/// Refactor this matrix into one with the same data,
	/// but attempting to lower the total number of nodes.
	MapSet optimize()
	{
		if (this is emptySet || this is unitSet) return this;

		bool modified;
		ValueSet[MapSet] newChildren;
		foreach (submatrix, ref values; root.children)
		{
			auto newMatrix = submatrix.optimize;
			if (newMatrix !is submatrix)
				modified = true;
			mergeChildren(newChildren, newMatrix, cast() values); // WATCH ME: this cast!
		}

		MapSet result = modified ? MapSet(new immutable Node(root.dim, cast(immutable) newChildren)) : this;

		foreach (submatrix, ref values; result.root.children)
			if (submatrix.root)
			{
				auto optimized = result.bringToFront(submatrix.root.dim);
				// {
				// 	import std.stdio;
				// 	writefln("Trying to optimize:\n- Old: %d : %s\n- New: %d : %s",
				// 		result.root.totalNodes, result,
				// 		optimized.root.totalNodes, optimized,
				// 	);
				// }
				return optimized.root.totalNodes < result.root.totalNodes ? optimized : result;
			}

		return result;
	}

	void toString(scope void delegate(const(char)[]) sink) const
	{
		import std.format : formattedWrite;
		if (this is emptySet)
			sink("{}");
		else
		if (this is unitSet)
			sink("{[]}");
		else
			sink.formattedWrite!"%s"(*root);
	}

	hash_t toHash() const @safe pure nothrow
	{
		return
			this is emptySet ? 0 :
			this is unitSet ? 1 :
			0;
	}

	bool opEquals(ref const typeof(this) s) const @safe pure nothrow
	{
		if (root is s.root)
			return true;
		if ((this is emptySet || this is unitSet) && (s is emptySet || s is unitSet))
			return this is s;
		return *root == *s.root;
	}
}

unittest
{
	import std.algorithm.sorting : sort;

	alias M = MapSet!(string, int);
	M m = M.emptySet;
	m = m.merge(M.unitSet.set("x", 1).set("y", 5));
	m = m.merge(M.unitSet.set("x", 1).set("y", 6));
	assert(m.all("x") == [1]);
	assert(m.all("y").sort.release == [5, 6]);

	m = m.merge(M.unitSet.set("x", 2).set("y", 6));
	assert(m.get("x", 1).all("y").sort.release == [5, 6]);
	assert(m.get("y", 6).all("x").sort.release == [1, 2]);

	m = m.subtract(M.unitSet.set("x", 1).set("y", 6));
	assert(m.all("x").sort.release == [1, 2]);
	assert(m.all("y").sort.release == [5, 6]);
	assert(m.get("x", 1).all("y") == [5]);
	assert(m.get("y", 6).all("x") == [2]);

	m = M.emptySet;
	m = m.merge(M.unitSet.set("x", 10).set("y", 20));
	m = m.merge(M.unitSet.set("x", 10).set("y", 21));
	m = m.merge(M.unitSet.set("x", 11).set("y", 21));
	m = m.merge(M.unitSet.set("x", 11).set("y", 22));
	auto o = m.optimize();
	assert(o.root.totalNodes < m.root.totalNodes);
}
