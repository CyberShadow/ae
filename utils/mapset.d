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

static if (__VERSION__ >= 2083):

import std.algorithm.iteration;
import std.algorithm.searching;
import std.algorithm.sorting;
import std.array;
import std.exception;
import std.typecons : tuple;

import ae.utils.aa;
import ae.utils.array : amap;

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
	/// Logically, each MapSet node has a map of values to a subset.
	/// However, it is faster to represent that map as an array of key-value pairs
	/// rather than a D associative array, so we do that here.
	struct Pair
	{
		DimValue value;
		MapSet set;

		int opCmp(ref const typeof(this) other) const
		{
			static if (is(typeof(value.opCmp(other.value)) : int))
				return value.opCmp(other.value);
			else
				return value < other.value ? -1 : value > other.value ? 1 : 0;
		}
	}

	struct Node
	{
		DimName dim;
		Pair[] children;

		immutable this(DimName dim, immutable Pair[] children)
		{
			// Zero children doesn't make sense.
			// It would be the equivalent of an empty set,
			// but then we should just use MapSet.emptySet instead.
			assert(!children.empty, "Node with zero children");

			// Nodes should be in their canonical form for
			// memoization and deduplication to be effective.
			assert(children.isSorted, "Children are not sorted");

			this.dim = dim;
			this.children = children;

			// Because each subset is immutable, we can
			// pre-calculate the hash during construction.
			hash = hashOf(dim) ^ hashOf(children);

			size_t totalMembers = 0;
			foreach (i, ref pair; children)
			{
				if (i)
					assert(pair.value != children[i-1].value, "Duplicate value");

				pair.set.assertDeduplicated();
				// Same as "Node with zero children"
				assert(pair.set !is emptySet, "Empty set as subset");

				totalMembers += pair.set.count;
			}
			this.totalMembers = totalMembers;
		}

		immutable this(DimName dim, immutable MapSet[DimValue] children)
		{
			auto childrenList = children.byKeyValue.map!(kv => Pair(kv.key, kv.value)).array;
			childrenList.sort();
			this(dim, cast(immutable) childrenList);
		}

		void toString(scope void delegate(const(char)[]) sink) const
		{
			import std.format : formattedWrite;
			sink.formattedWrite("{ %(%s%), [ ", (&dim)[0..1]);
			bool first = true;
			foreach (ref pair; children)
			{
				if (first)
					first = false;
				else
					sink(", ");
				sink.formattedWrite("%s : %s", pair.value, pair.set);
			}
			sink(" ] }");
		}

		private hash_t hash;
		size_t totalMembers;

		hash_t toHash() const
		{
			return hash;
		}

		bool opEquals(ref const typeof(this) s) const
		{
			return hash == s.hash && dim == s.dim && children == s.children;
		}
	}

	/// Indicates the empty set.
	/// May only occur at the top level (never as a subset).
	private enum emptySetRoot = cast(immutable(Node)*)1;

	/// If emptySetRoot, zero values.
	/// If null, one value with zero dimensions.
	/// Otherwise, pointer to node describing the next dimension.
	immutable(Node)* root = emptySetRoot;

	/// A set containing a single nil-dimensional element.
	/// Holds exactly one value (a point with all dimensions at
	/// nullValue).
	static immutable unitSet = MapSet(null);

	/// The empty set. Represents a set which holds zero values.
	static immutable emptySet = MapSet(emptySetRoot);

	/// Return the total number of items in this set.
	size_t count() const
	{
		if (this is emptySet)
			return 0;
		if (this is unitSet)
			return 1;
		return root.totalMembers;
	}

	private struct SetSetOp { MapSet a, b; }
	private struct SetDimOp { MapSet set; DimName dim; }
	private struct SetIdxOp { MapSet set; size_t index; }
	private struct Cache
	{
		/// For deduplication - key is value
		MapSet[MapSet] instances;
		/// Operations - things that operate recursively on subtrees
		/// should be memoized here
		MapSet[SetSetOp] merge, subtract, cartesianProduct, reorderUsing;
		MapSet[SetDimOp] remove, bringToFront;
		MapSet[SetIdxOp] swapDepth;
		MapSet[MapSet] optimize, completeSuperset;
		size_t[MapSet] uniqueNodes, maxDepth;
	}

	/// Because subtrees can be reused within the tree, a way of
	/// memoizing operations across the entire tree (instead of just
	/// across children of a single node, or siblings) is crucial for
	/// performance.
	static Cache cache;

	/// Clear the global operations cache.
	static void clearCache()
	{
		cache = Cache.init;
	}

	/// Because MapSet operations benefit greatly from memoization,
	/// maintaining a set of interned sets benefits performance. After
	/// calling `clearCache`, call this method to re-register extant
	/// live instances to the instance cache.
	void addToCache() const
	{
		cache.instances.updateVoid(
			this,
			{
				if (this !is emptySet && this !is unitSet)
					foreach (ref pair; root.children)
						pair.set.addToCache();
				return this;
			},
			(ref MapSet set)
			{
				assert(set is this);
			}
		);
	}

	/// Intern and deduplicate this MapSet.
	/// Needs to be called only after constructing a MapSet manually
	/// (by allocating, populating, and setting `root`).
	MapSet deduplicate() const
	{
		MapSet deduplicated;
		cache.instances.updateVoid(
			this,
			{
				debug if (this !is emptySet && this !is unitSet)
					foreach (ref pair; root.children)
						pair.set.assertDeduplicated();
				deduplicated = this;
				return this;
			},
			(ref MapSet set)
			{
				deduplicated = set;
			}
		);
		return deduplicated;
	}

	private void assertDeduplicated() const { debug assert(this is emptySet || this is unitSet || cache.instances[this] is this); }

	/// Count and return the total number of unique nodes in this MapSet.
	size_t uniqueNodes() const
	{
		return cache.uniqueNodes.require(this, {
			HashSet!MapSet seen;
			void visit(MapSet set)
			{
				if (set is emptySet || set is unitSet || set in seen)
					return;
				seen.add(set);
				foreach (ref pair; set.root.children)
					visit(pair.set);
			}
			visit(this);
			return seen.length;
		}());
	}

	/// Collect the names of all dimensions occurring in this tree.
	DimName[] getDims() const
	{
		HashSet!DimName dims;
		HashSet!MapSet seen;
		void visit(MapSet set)
		{
			if (set is emptySet || set is unitSet || set in seen)
				return;
			seen.add(set);
			dims.add(set.root.dim);
			foreach (ref pair; set.root.children)
				visit(pair.set);
		}
		visit(this);
		return dims.keys;
	}

	/// Return all values for all dimensions occurring in this set.
	/// The Cartesian product of these values would thus be a superset
	/// of this set.
	/// This is equivalent to, but faster than, calling `getDims` and
	/// then `all` for each dim.
	HashSet!DimValue[DimName] getDimsAndValues() const
	{
		if (this is emptySet) return null;

		// Be careful to count the implicit nullValues on branches
		// where a dim doesn't occur.
		MapSet set = this.completeSuperset;
		HashSet!DimValue[DimName] result;
		while (set !is unitSet)
		{
			DimName dim = set.root.dim;
			HashSet!DimValue values = set.root.children.map!((ref child) => child.value).toSet;
			bool added = result.addNew(dim, values);
			assert(added, "Duplicate dimension");
			set = set.root.children[0].set;
		}
		return result;
	}

	/// Combine two matrices together, returning their union.
	/// If `other` is a subset of `this`, return `this` unchanged.
	MapSet merge(MapSet other) const
	{
		if (this is emptySet) return other;
		if (other is emptySet) return this;
		if (this is other) return this;
		if (!root) return bringToFront(other.root.dim).merge(other);

		this.assertDeduplicated();
		other.assertDeduplicated();
		return cache.merge.require(SetSetOp(this, other), {
			other = other.bringToFront(root.dim);

			if (root.children.length == 1 && other.root.children.length == 1 &&
				root.children[0].value == other.root.children[0].value)
			{
				// Single-child optimization
				auto mergeResult = root.children[0].set.merge(other.root.children[0].set);
				if (mergeResult !is root.children[0].set)
					return MapSet(new immutable Node(root.dim, [Pair(root.children[0].value, mergeResult)])).deduplicate;
				else
					return this;
			}

			MapSet[DimValue] newChildren;
			foreach (ref pair; root.children)
				newChildren[pair.value] = pair.set;

			bool modified;
			foreach (ref pair; other.root.children)
				newChildren.updateVoid(pair.value,
					{
						modified = true;
						return pair.set;
					},
					(ref MapSet oldSubmatrix)
					{
						auto mergeResult = oldSubmatrix.merge(pair.set);
						if (oldSubmatrix !is mergeResult)
						{
							oldSubmatrix = mergeResult;
							modified = true;
						}
					}
				);

			if (!modified)
				return this;

			return MapSet(new immutable Node(root.dim, cast(immutable) newChildren)).deduplicate;
		}());
	}

	/// Return the difference between `this` and the given set.
	/// If `other` does not intersect with `this`, return `this` unchanged.
	MapSet subtract(MapSet other) const
	{
		if (this is emptySet) return this;
		if (other is emptySet) return this;
		if (this is other) return emptySet;
		if (!root) return bringToFront(other.root.dim).subtract(other);

		this.assertDeduplicated();
		other.assertDeduplicated();
		return cache.subtract.require(SetSetOp(this, other), {
			other = other.bringToFront(root.dim);

			if (root.children.length == 1 && other.root.children.length == 1 &&
				root.children[0].value == other.root.children[0].value)
			{
				// Single-child optimization
				auto subtractResult = root.children[0].set.subtract(other.root.children[0].set);
				if (subtractResult is emptySet)
					return emptySet;
				else
				if (subtractResult !is root.children[0].set)
					return MapSet(new immutable Node(root.dim, [Pair(root.children[0].value, subtractResult)])).deduplicate;
				else
					return this;
			}

			MapSet[DimValue] newChildren;
			foreach (ref pair; root.children)
				newChildren[pair.value] = pair.set;

			bool modified;
			foreach (ref pair; other.root.children)
				if (auto poldSubmatrix = pair.value in newChildren)
				{
					auto subtractResult = poldSubmatrix.subtract(pair.set);
					if (*poldSubmatrix !is subtractResult)
					{
						*poldSubmatrix = subtractResult;
						if (subtractResult is emptySet)
							newChildren.remove(pair.value);
						modified = true;
					}
				}

			if (!modified)
				return this;
			if (!newChildren.length)
				return emptySet;

			return MapSet(new immutable Node(root.dim, cast(immutable) newChildren)).deduplicate;
		}());
	}

	private MapSet lazyMap(scope MapSet delegate(MapSet) fn) const
	{
		// Defer allocation until the need to mutate
		foreach (i, ref pair; root.children) // Read-only scan
		{
			auto newSet = fn(pair.set);
			if (newSet !is pair.set)
			{
				auto newChildren = new Pair[root.children.length];
				// Known to not need mutation
				newChildren[0 .. i] = root.children[0 .. i];
				// Reuse already calculated result
				newChildren[i] = Pair(pair.value, newSet);
				// Continue scan with mutation
				foreach (j, ref pair2; root.children[i + 1 .. $])
					newChildren[i + 1 + j] = Pair(pair2.value, fn(pair2.set));
				return MapSet(new immutable Node(root.dim, cast(immutable) newChildren)).deduplicate;
			}
		}
		return this; // No mutation necessary
	}

	/// "Unset" a given dimension, removing it from the matrix.
	/// The result is the union of all sub-matrices for all values of `dim`.
	MapSet remove(DimName dim) const
	{
		if (this is emptySet || this is unitSet) return this;
		this.assertDeduplicated();
		return cache.remove.require(SetDimOp(this, dim), {
			if (root.dim == dim)
			{
				MapSet result;
				foreach (ref pair; root.children)
					result = result.merge(pair.set);
				return result;
			}
			return lazyMap(set => set.remove(dim));
		}());
	}

	/// Unset dimensions according to a predicate.
	/// This is faster than removing dimensions individually, however,
	/// unlike the `DimName` overload, this one does not benefit from global memoization.
	MapSet remove(bool delegate(DimName) pred) const
	{
		if (this is emptySet) return this;
		this.assertDeduplicated();

		MapSet[MapSet] cache;
		MapSet visit(MapSet set)
		{
			if (set is unitSet)
				return set;
			return cache.require(set, {
				if (pred(set.root.dim))
				{
					MapSet result;
					foreach (ref pair; set.root.children)
						result = result.merge(visit(pair.set));
					return result;
				}
				return set.lazyMap(set => visit(set));
			}());
		}
		return visit(this);
	}

	/// Set the given dimension to always have the given value,
	/// collapsing (returning the union of) all sub-matrices
	/// for previously different values of `dim`.
	MapSet set(DimName dim, DimValue value) const
	{
		return this.remove(dim).addDim(dim, value);
	}

	/// Adds a new dimension with the given value.
	/// The dimension must not have previously existed in `this`.
	private MapSet addDim(DimName dim, DimValue value) const
	{
		if (this is emptySet) return this;
		this.assertDeduplicated();
		assert(this is this.remove(dim), "Duplicate dimension");
		if (value == nullValue)
			return this;
		return MapSet(new immutable Node(dim, [Pair(value, this)])).deduplicate;
	}

	/// Return a sub-matrix for all points where the given dimension has this value.
	/// The dimension itself is not included in the result.
	/// Note: if `dim` doesn't occur (e.g. because `this` is the unit set) and `value` is `nullValue`,
	/// this returns the unit set (not the empty set).
	MapSet slice(DimName dim, DimValue value) const
	{
		if (this is emptySet) return emptySet;
		this.assertDeduplicated();
		foreach (ref pair; bringToFront(dim).root.children)
			if (pair.value == value)
				return pair.set;
		return emptySet;
	}

	/// Return a subset of this set for all points where the given dimension has this value.
	/// Unlike `slice`, the dimension itself is included in the result (with the given value).
	MapSet get(DimName dim, DimValue value) const
	{
		if (this is emptySet) return emptySet;
		this.assertDeduplicated();
		foreach (ref pair; bringToFront(dim).root.children)
			if (pair.value == value)
				return MapSet(new immutable Node(dim, [Pair(value, pair.set)])).deduplicate;
		return emptySet;
	}

	/// Return all unique values occurring for a given dimension.
	/// Unless this is the empty set, the return value is always non-empty.
	/// If `dim` doesn't occur, it will be `[nullValue]`.
	const(DimValue)[] all(DimName dim) const
	{
		// return bringToFront(dim).root.children.keys;
		if (this is emptySet) return null;
		if (this is unitSet) return [nullValue];
		if (root.dim == dim) return root.children.amap!(child => child.value);
		this.assertDeduplicated();

		HashSet!DimValue allValues;
		HashSet!MapSet seen;
		void visit(MapSet set)
		{
			if (set is unitSet)
			{
				allValues.add(nullValue);
				return;
			}
			if (set in seen)
				return;
			seen.add(set);

			if (set.root.dim == dim)
				foreach (ref pair; set.root.children)
					allValues.add(pair.value);
			else
				foreach (ref pair; set.root.children)
					visit(pair.set);
		}
		visit(this);
		return allValues.keys;
	}

	/// Return a set which represents the Cartesian product between
	/// this set and the given `values` across the specified
	/// dimension.
	MapSet cartesianProduct(DimName dim, DimValue[] values) const
	{
		if (this is emptySet) return emptySet;
		if (values.length == 0) return emptySet;
		this.assertDeduplicated();
		auto unset = this.remove(dim);
		auto children = values.map!(value => Pair(value, unset)).array;
		children.sort();
		return MapSet(new immutable Node(dim, cast(immutable) children)).deduplicate;
	}

	/// Return a set which represents the Cartesian product between
	/// this and the given set.
	/// Duplicate dimensions are first removed from `this` set.
	/// For best performance, call `big.cartesianProduct(small)`
	MapSet cartesianProduct(MapSet other) const
	{
		if (this is emptySet || other is emptySet) return emptySet;
		if (this is unitSet) return other;
		if (other is unitSet) return this;

		MapSet unset = this;
		foreach (dim; other.getDims())
			unset = unset.remove(dim);

		return other.uncheckedCartesianProduct(unset);
	}

	// Assumes that the dimensions in `this` and `other` are disjoint.
	private MapSet uncheckedCartesianProduct(MapSet other) const
	{
		if (this is unitSet) return other;
		if (other is unitSet) return this;

		this.assertDeduplicated();
		other.assertDeduplicated();

		return cache.cartesianProduct.require(SetSetOp(this, other), {
			return lazyMap(set => set.uncheckedCartesianProduct(other));
		}());
	}

	/// Return a superset of this set, consisting of a Cartesian
	/// product of every value of every dimension. The total number of
	/// unique nodes is thus equal to the number of dimensions.
	MapSet completeSuperset() const
	{
		if (this is emptySet || this is unitSet) return this;
		this.assertDeduplicated();

		return cache.completeSuperset.require(this, {
			MapSet child = MapSet.emptySet;
			foreach (ref pair; root.children)
				child = child.merge(pair.set);
			child = child.completeSuperset();
			auto newChildren = root.children.dup;
			foreach (ref pair; newChildren)
				pair.set = child;
			return MapSet(new immutable Node(root.dim, cast(immutable) newChildren)).deduplicate;
		}());
	}

	/// Refactor this matrix into one with the same data,
	/// but putting the given dimension in front.
	/// This will speed up access to values with the given dimension.
	/// If the dimension does not yet occur in the set (or any subset),
	/// it is instantiated with a single `nullValue` value.
	/// The set must be non-empty.
	MapSet bringToFront(DimName dim) const
	{
		assert(this !is emptySet, "Empty sets may not have dimensions");

		if (this is unitSet)
		{
			// We reached the bottom, and did not find `dim` along the way.
			// Create it now.
			return MapSet(new immutable Node(dim, [Pair(nullValue, unitSet)])).deduplicate;
		}

		if (dim == root.dim)
		{
			// Already at the front.
			return this;
		}

		// 1. Recurse.
		// 2. After recursion, all children should have `dim` at the front.
		// So, just swap this layer with the next one.

		this.assertDeduplicated();
		return cache.bringToFront.require(SetDimOp(this, dim), {
			if (root.children.length == 1)
			{
				auto newSubmatrix = root.children[0].set.bringToFront(dim);
				auto newChildren = newSubmatrix.root.children.dup;
				foreach (ref pair; newChildren)
					pair.set = MapSet(new immutable Node(root.dim, [Pair(root.children[0].value, pair.set)])).deduplicate;
				return MapSet(new immutable Node(dim, cast(immutable) newChildren)).deduplicate;
			}

			Pair[][DimValue] subsets;
			foreach (ref pair; root.children)
			{
				auto newSubmatrix = pair.set.bringToFront(dim);
				assert(newSubmatrix.root.dim == dim);
				foreach (ref pair2; newSubmatrix.root.children)
					subsets[pair2.value] ~= Pair(pair.value, pair2.set);
			}
			Pair[] newChildren;
			foreach (value, children; subsets)
			{
				children.sort();
				newChildren ~= Pair(value, MapSet(new immutable Node(root.dim, cast(immutable) children)).deduplicate);
			}
			newChildren.sort();
			return MapSet(new immutable Node(dim, cast(immutable) newChildren)).deduplicate;
		}());
	}

	/// Refactor this matrix into one with the same data,
	/// but attempting to lower the total number of nodes.
	MapSet optimize() const
	{
		if (this is emptySet || this is unitSet) return this;
		this.assertDeduplicated();

		return cache.optimize.require(this, {
			struct Result { bool done; MapSet[MapSet] map; }
			static Result optimizeLayer(HashSet!MapSet sets0)
			{
				// - At the bottom?
				//   - Yes:
				//     - return failure
				//   - No:
				//     - Try to swap this layer. Success?
				//       - Yes:
				//         - return success
				//       - No:
				//         - Recurse and try to swap next layer. Success?
				//           - Yes: Retry this layer
				//           - No: return failure (bottom reached)

				assert(!sets0.empty);
				if (sets0.byKey.front is unitSet)
					return Result(true, null); // at the bottom
				auto dim0 = sets0.byKey.front.root.dim;
				assert(sets0.byKey.all!(set => set !is unitSet), "Leaf/non-leaf nodes mismatch");
				assert(sets0.byKey.all!(set => set.root.dim == dim0), "Dim mismatch");

				auto sets1 = sets0.byKey.map!(set => set.root.children.map!(function MapSet (ref child) => child.set)).joiner.toSet;
				assert(!sets1.empty);
				if (sets1.byKey.front is unitSet)
					return Result(true, null); // one layer away from the bottom, nothing to swap with
				auto dim1 = sets1.byKey.front.root.dim;
				assert(sets1.byKey.all!(set => set !is unitSet), "Leaf/non-leaf nodes mismatch");
				assert(sets1.byKey.all!(set => set.root.dim == dim1), "Dim mismatch");

				auto currentNodes = sets0.length + sets1.length;

				MapSet[MapSet] swappedSets;
				HashSet!MapSet sets0new, sets1new;

				foreach (set0; sets0.byKey)
				{
					Pair[][DimValue] subsets;
					foreach (ref pair0; set0.root.children)
						foreach (ref pair1; pair0.set.root.children)
							subsets[pair1.value] ~= Pair(pair0.value, pair1.set);

					Pair[] newChildren;
					foreach (value, children; subsets)
					{
						children.sort();
						auto set1new = MapSet(new immutable Node(dim0, cast(immutable) children)).deduplicate;
						sets1new.add(set1new);
						newChildren ~= Pair(value, set1new);
					}
					newChildren.sort();
					auto set0new = MapSet(new immutable Node(dim1, cast(immutable) newChildren)).deduplicate;
					sets0new.add(set0new);
					swappedSets[set0] = set0new;
				}

				auto newNodes = sets0new.length + sets1new.length;

				if (newNodes < currentNodes)
					return Result(false, swappedSets); // Success, retry above layer

				// Failure, descend

				auto result1 = optimizeLayer(sets1);
				if (!result1.map)
				{
					assert(result1.done);
					return Result(true, null); // Done, bottom reached
				}

				// Apply result
				sets0new.clear();
				foreach (set0; sets0.byKey)
				{
					set0.assertDeduplicated();
					auto newChildren = set0.root.children.dup;
					foreach (ref pair0; newChildren)
						pair0.set = result1.map[pair0.set];
					auto set0new = MapSet(new immutable Node(dim0, cast(immutable) newChildren)).deduplicate;
					sets0new.add(set0new);
					swappedSets[set0] = set0new;
				}

				if (result1.done)
					return Result(true, swappedSets);

				// Retry this layer
				auto result0 = optimizeLayer(sets0new);
				if (!result0.map)
				{
					assert(result0.done);
					return Result(true, swappedSets); // Bottom was reached upon retry, just return our results unchanged
				}

				MapSet[MapSet] compoundedResult;
				foreach (set0; sets0.byKey)
					compoundedResult[set0] = result0.map[swappedSets[set0]];
				return Result(result0.done, compoundedResult);
			}

			MapSet[1] root = [this.normalize];
			while (true)
			{
				auto result = optimizeLayer(root[].toSet());
				if (result.map)
					root[0] = result.map[root[0]];
				if (result.done)
					return root[0];
			}
		}());
	}

	/// Return a set equivalent to a unit set (all dimensions
	/// explicitly set to `nullValue`), with all dimensions in `this`,
	/// in an order approximately following that of the dimensions in
	/// `this`.  Implicitly normalized.
	private MapSet dimOrderReference() const
	{
		if (this is unitSet || this is emptySet) return this;

		DimName[] dims;
		HashSet!MapSet seen;
		void visit(MapSet set, size_t pos)
		{
			if (set is unitSet) return;
			if (set in seen) return;
			seen.add(set);
			if ((pos == dims.length || dims[pos] != set.root.dim) && !dims.canFind(set.root.dim))
			{
				dims.insertInPlace(pos, set.root.dim);
				pos++;
			}
			foreach (ref pair; set.root.children)
				visit(pair.set, pos);
		}
		visit(this, 0);

		MapSet result = unitSet;
		foreach_reverse (dim; dims)
			result = MapSet(new immutable Node(dim, [Pair(nullValue, result)])).deduplicate();

		return result;
	}

	/// Refactor this matrix into one in which dimensions always occur
	/// in the same order, no matter what path is taken.
	MapSet normalize() const
	{
		if (this is unitSet || this is emptySet) return this;

		return reorderUsing(dimOrderReference());
	}

	private size_t maxDepth() const
	{
		import std.algorithm.comparison : max;

		if (this is emptySet || this is unitSet)
			return 0;
		this.assertDeduplicated();
		return cache.maxDepth.require(this, {
			size_t maxDepth = 0;
			foreach (ref pair; root.children)
				maxDepth = max(maxDepth, pair.set.maxDepth());
			return 1 + maxDepth;
		}());
	}

	private MapSet swapDepth(size_t depth) const
	{
		if (this is emptySet || this is unitSet) return this;
		this.assertDeduplicated();

		return cache.swapDepth.require(SetIdxOp(this, depth), {
			if (depth == 0)
			{
				foreach (ref pair; root.children)
					if (pair.set !is unitSet)
						return bringToFront(pair.set.root.dim);
				return this;
			}
			else
			{
				auto newChildren = root.children.dup;
				foreach (ref pair; newChildren)
					pair.set = pair.set.swapDepth(depth - 1);
				return MapSet(new immutable Node(root.dim, cast(immutable) newChildren)).deduplicate;
			}
		}());
	}

	/// Refactor this matrix into one with the same data, but in which
	/// the dimensions always occur as in `reference` (which is
	/// assumed to be normalized).
	MapSet reorderUsing(MapSet reference) const
	{
		if (this is emptySet || reference is emptySet || reference is unitSet) return this;
		this.assertDeduplicated();
		reference.assertDeduplicated();

		return cache.reorderUsing.require(SetSetOp(this, reference), {
			return bringToFront(reference.root.dim).lazyMap(set => set.reorderUsing(reference.root.children[0].set));
		}());
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

	hash_t toHash() const
	{
		return
			this is emptySet ? 0 :
			this is unitSet ? 1 :
			root.toHash();
	}

	bool opEquals(const typeof(this) s) const
	{
		if (root is s.root)
			return true;
		if (this is emptySet || this is unitSet || s is emptySet || s is unitSet)
			return this is s;
		return *root == *s.root;
	}
}

unittest
{
	import std.algorithm.sorting : sort;

	alias M = MapSet!(string, int);
	M m, n;
	m = m.merge(M.unitSet.set("x", 1).set("y", 5));
	m = m.merge(M.unitSet.set("x", 1).set("y", 6));
	assert(m.all("x") == [1]);
	assert(m.all("y").dup.sort.release == [5, 6]);

	m = m.merge(M.unitSet.set("x", 2).set("y", 6));
	assert(m.get("x", 1).all("y").dup.sort.release == [5, 6]);
	assert(m.get("y", 6).all("x").dup.sort.release == [1, 2]);

	m = m.subtract(M.unitSet.set("x", 1).set("y", 6));
	assert(m.all("x").dup.sort.release == [1, 2]);
	assert(m.all("y").dup.sort.release == [5, 6]);
	assert(m.get("x", 1).all("y") == [5]);
	assert(m.get("y", 6).all("x") == [2]);

	m = M.emptySet;
	m = m.merge(M.unitSet.set("x", 10).set("y", 20));
	m = m.merge(M.unitSet.set("x", 10).set("y", 21));
	m = m.merge(M.unitSet.set("x", 11).set("y", 21));
	m = m.merge(M.unitSet.set("x", 11).set("y", 22));
	auto o = m.optimize();
	assert(o.uniqueNodes < m.uniqueNodes);

	m = M.emptySet;
	assert(m.all("x") == []);
	m = M.unitSet;
	assert(m.all("x") == [0]);
	m = m.merge(M.unitSet.set("x", 1));
	assert(m.all("x").dup.sort.release == [0, 1]);

	m = M.unitSet;
	assert(m.set("x", 1).set("x", 1).all("x") == [1]);

	m = M.unitSet;
	m = m.cartesianProduct("x", [1, 2, 3]);
	m = m.cartesianProduct("y", [1, 2, 3]);
	m = m.cartesianProduct("z", [1, 2, 3]);
	assert(m.count == 3 * 3 * 3);
	assert(m            .all("x").dup.sort.release == [1, 2, 3]);
	assert(m.set("z", 1).all("x").dup.sort.release == [1, 2, 3]);
	assert(m.set("x", 1).all("z").dup.sort.release == [1, 2, 3]);

	m = M.unitSet;
	m = m.cartesianProduct("a", [1, 2, 3]);
	m = m.cartesianProduct("b", [1, 2, 3]);
	n = M.unitSet;
	n = n.cartesianProduct("c", [1, 2, 3]);
	n = n.cartesianProduct("d", [1, 2, 3]);
	m = m.cartesianProduct(n);
	assert(m.count == 3 * 3 * 3 * 3);

	assert(M.unitSet != M.unitSet.set("x", 1));

	m = M.emptySet;
	m = m.merge(M.unitSet.set("x", 1).set("y", 11));
	m = m.merge(M.unitSet.set("x", 2).set("y", 12).set("z", 22));
	m = m.completeSuperset();
	assert(m.uniqueNodes == 3);
	assert(m.count == 8); // 2 ^^ 3
	assert(m.all("x").dup.sort.release == [1, 2]);
	assert(m.all("y").dup.sort.release == [11, 12]);
	assert(m.all("z").dup.sort.release == [0, 22]);
}


/// Allows executing a deterministic algorithm over all states in a given MapSet.
/// If a variable is not queried by the algorithm, states for all
/// variations of that variable are processed in one iteration.
struct MapSetVisitor(A, V)
{
	alias Set = MapSet!(A, V);
	Set set;

	struct Var
	{
		A name;
		const(V)[] values;
		size_t pos;
	}
	Var[] stack;
	size_t stackPos;
	V[A] singularValues, resolvedValues; // Faster than workingSet.all(name)[0]
	private HashSet!A dirtyValues; // Accumulate MapSet.set calls
	private Set workingSet;

	this(Set set)
	{
		this.set = set;
		foreach (dim, values; set.getDimsAndValues())
			if (values.length == 1)
				singularValues[dim] = values.byKey.front;
	}

	/// Resets iteration to the beginning.
	/// Equivalent to but faster than constructing a new MapSetVisitor
	/// instance (`visitor = MapSetVisitor(visitor.set)`).
	void reset()
	{
		workingSet = Set.emptySet;
		stack = null;
	}

	/// Returns true if there are more states to iterate over,
	/// otherwise returns false
	bool next()
	{
		if (set is Set.emptySet)
			return false;
		if (workingSet is Set.emptySet)
		{
			// first iteration
		}
		else
			while (true)
			{
				if (!stack.length)
					return false; // All possibilities exhausted
				auto last = &stack[$-1];
				last.pos++;
				if (last.pos == last.values.length)
				{
					stack = stack[0 .. $ - 1];
					continue;
				}
				break;
			}

		workingSet = set;
		resolvedValues = null;
		dirtyValues.clear();
		stackPos = 0;
		return true;
	}

	private void flush()
	{
		if (dirtyValues.empty)
			return;
		workingSet = workingSet.remove((A name) => name in dirtyValues);
		foreach (name; dirtyValues)
			workingSet = workingSet.addDim(name, resolvedValues[name]);
		dirtyValues.clear();
	}

	@property Set currentSubset()
	{
		assert(workingSet !is Set.emptySet, "Not iterating");
		flush();
		return workingSet;
	}

	/// Algorithm interface - get a value by name
	V get(A name)
	{
		assert(workingSet !is Set.emptySet, "Not iterating");
		if (auto pvalue = name in resolvedValues)
			return *pvalue;
		if (auto pvalue = name in singularValues)
			return *pvalue;

		if (stackPos == stack.length)
		{
			// Expand new variable
			auto values = workingSet.all(name);
			auto value = values[0];
			resolvedValues[name] = value;
			stack ~= Var(name, values, 0);
			stackPos++;
			if (values.length > 1)
				workingSet = workingSet.get(name, value);
			return value;
		}

		// Iterate over known variable
		auto var = &stack[stackPos];
		assert(var.name == name, "Mismatching get order");
		auto value = var.values[var.pos];
		workingSet = workingSet.get(var.name, value);
		assert(workingSet !is Set.emptySet, "Empty set after restoring");
		resolvedValues[var.name] = value;
		stackPos++;
		return value;
	}

	/// Algorithm interface - set a value by name
	void put(A name, V value)
	{
		assert(workingSet !is Set.emptySet, "Not iterating");
		if (name !in resolvedValues)
			if (auto pvalue = name in singularValues)
				if (*pvalue == value)
					return;

		resolvedValues[name] = value;
		dirtyValues.add(name);
	}

	/// Apply a function over every possible value of the given
	/// variable, without resolving it (unless it's already resolved).
	void transform(A name, scope void delegate(ref V value) fun)
	{
		assert(workingSet !is Set.emptySet, "Not iterating");
		if (auto pvalue = name in resolvedValues)
		{
			dirtyValues.add(name);
			return fun(*pvalue);
		}

		workingSet = workingSet.bringToFront(name);
		Set[V] newChildren;
		foreach (ref child; workingSet.root.children)
		{
			V value = child.value;
			fun(value);
			newChildren.updateVoid(value,
				() => child.set,
				(ref Set set)
				{
					set = set.merge(child.set);
				});
		}
		workingSet = Set(new immutable Set.Node(name, cast(immutable) newChildren)).deduplicate;
	}

	/// Apply a function over every possible value of the given
	/// variable, without resolving it (unless it's already resolved).
	/// The function is assumed to be injective (does not produce
	/// duplicate outputs for distinct inputs).
	void injectiveTransform(A name, scope void delegate(ref V value) fun)
	{
		assert(workingSet !is Set.emptySet, "Not iterating");
		if (auto pvalue = name in resolvedValues)
		{
			dirtyValues.add(name);
			return fun(*pvalue);
		}

		workingSet = workingSet.bringToFront(name);
		auto newChildren = workingSet.root.children.dup;
		foreach (ref child; newChildren)
			fun(child.value);
		newChildren.sort();
		workingSet = Set(new immutable Set.Node(name, cast(immutable) newChildren)).deduplicate;
	}
}

/// An algorithm which divides two numbers.
/// When the divisor is zero, we don't even query the dividend,
/// therefore processing all dividends in one iteration.
unittest
{
	alias M = MapSet!(string, int);
	M m = M.unitSet
		.cartesianProduct("divisor" , [0, 1, 2])
		.cartesianProduct("dividend", [0, 1, 2]);
	assert(m.count == 9);

	auto v = MapSetVisitor!(string, int)(m);
	M results;
	int iterations;
	while (v.next())
	{
		iterations++;
		auto divisor = v.get("divisor");
		if (divisor == 0)
			continue;
		auto dividend = v.get("dividend");
		v.put("quotient", dividend / divisor);
		results = results.merge(v.currentSubset);
	}

	assert(iterations == 7); // 1 for division by zero + 3 for division by one + 3 for division by two
	assert(results.get("divisor", 2).get("dividend", 2).all("quotient") == [1]);
	assert(results.get("divisor", 0).count == 0);
}

unittest
{
	import std.algorithm.sorting : sort;

	alias M = MapSet!(string, int);
	M m = M.unitSet.cartesianProduct("x", [1, 2, 3]);
	auto v = MapSetVisitor!(string, int)(m);
	v.next();
	v.transform("x", (ref int v) { v *= 2; });
	assert(v.currentSubset.all("x").dup.sort.release == [2, 4, 6]);
}

unittest
{
	alias M = MapSet!(string, int);
	M m = M.unitSet.cartesianProduct("x", [1, 2, 3]);
	auto v = MapSetVisitor!(string, int)(m);
	while (v.next())
	{
		v.transform("x", (ref int v) { v *= 2; });
		v.put("y", v.get("x"));
	}
}
