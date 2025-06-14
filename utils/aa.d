/**
 * Associative Array utility functions
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

module ae.utils.aa;

import std.algorithm;
import std.range;
import std.traits;
import std.typecons;

import ae.utils.meta : progn, BoxVoid, BoxedVoid;

// ***************************************************************************

/// Polyfill for object.require
static if (!__traits(hasMember, object, "require"))
ref V require(K, V)(ref V[K] aa, K key, lazy V value = V.init)
{
	auto p = key in aa;
	if (p)
		return *p;
	return aa[key] = value;
}

debug(ae_unittest) unittest
{
	int[int] aa;
	aa.require(1, 2);
	assert(aa[1] == 2);
	aa.require(2, 3) = 4;
	assert(aa[2] == 4);
	aa.require(1, 5);
	assert(aa[1] == 2);
	aa.require(1, 6) = 7;
	assert(aa[1] == 7);
}

static if (!__traits(hasMember, object, "update"))
{
	/// Polyfill for object.update
	void updatePolyfill(K, V, C, U)(ref V[K] aa, K key, scope C create, scope U update)
	if (is(typeof(create()) : V) && is(typeof(update(aa[K.init])) : V))
	{
		auto p = key in aa;
		if (p)
			*p = update(*p);
		else
			aa[key] = create();
	}

	/// Work around https://issues.dlang.org/show_bug.cgi?id=15795
	alias update = updatePolyfill;
}

// https://github.com/dlang/druntime/pull/3012
private enum haveObjectUpdateWithVoidUpdate = is(typeof({
	int[int] aa;
	.object.update(aa, 0, { return 0; }, (ref int v) { });
}));

static if (!haveObjectUpdateWithVoidUpdate)
{
	/// Polyfill for object.update with void update function
	void updateVoid(K, V, C, U)(ref V[K] aa, K key, scope C create, scope U update)
	if (is(typeof(create()) : V) && is(typeof(update(aa[K.init])) == void))
	{
		// We can polyfill this in two ways.
		// What's more expensive, copying the value, or a second key lookup?
		enum haveObjectUpdate = __traits(hasMember, object, "update");
		enum valueIsExpensiveToCopy = V.sizeof > string.sizeof
			|| hasElaborateCopyConstructor!V
			|| hasElaborateDestructor!V;
		static if (haveObjectUpdate && !valueIsExpensiveToCopy)
		{
			.object.update(aa, key,
				delegate V() { return create(); },
				(ref V v) { update(v); return v; });
		}
		else
		{
			auto p = key in aa;
			if (p)
				update(*p);
			else
				aa[key] = create();
		}
	}

	/// Work around https://issues.dlang.org/show_bug.cgi?id=15795
	alias update = updateVoid;
}
else
	alias updateVoid = object.update; /// Use `object.update` for void update function

// Inject overload
static if (__traits(hasMember, object, "update"))
	private alias update = object.update;

// ***************************************************************************

/// Get a value from an AA, and throw an exception (not an error) if not found
ref auto aaGet(AA, K)(auto ref AA aa, auto ref K key)
	if (is(typeof(key in aa)))
{
	import std.conv;

	auto p = key in aa;
	if (p)
		return *p;
	else
		static if (is(typeof(text(key))))
			throw new Exception("Absent value: " ~ text(key));
		else
			throw new Exception("Absent value");
}

/// If key is not in aa, add it with defaultValue.
/// Returns a reference to the value corresponding to key.
ref V getOrAdd(K, V)(ref V[K] aa, auto ref K key, auto ref V defaultValue)
{
	return aa.require(key, defaultValue);
}

/// ditto
ref V getOrAdd(K, V)(ref V[K] aa, auto ref K key)
{
	return getOrAdd(aa, key, V.init);
}

debug(ae_unittest) unittest
{
	int[int] aa;
	aa.getOrAdd(1, 2) = 3;
	assert(aa[1] == 3);
	assert(aa.getOrAdd(1, 4) == 3);
}

/// If key is not in aa, add it with the given value, and return true.
/// Otherwise, return false.
bool addNew(K, V)(ref V[K] aa, auto ref K key, auto ref V value)
{
	bool added /*= void*/;
	updateVoid(aa, key,
		delegate V   (       ) { added = true ; return value; },
		delegate void(ref V v) { added = false;               },
	);
	return added;
}

debug(ae_unittest) @safe unittest
{
	int[int] aa;
	assert( aa.addNew(1, 2));
	assert(!aa.addNew(1, 3));
	assert(aa[1] == 2);
}

debug(ae_unittest) unittest
{
	OrderedMap!(int, int) aa;
	assert( aa.addNew(1, 2));
	assert(!aa.addNew(1, 3));
	assert(aa[1] == 2);
}

// ***************************************************************************

/// Key/value pair
struct KeyValuePair(K, V) { K key; /***/ V value; /***/ }

/// Get key/value pairs from AA
deprecated KeyValuePair!(K, V)[] pairs(K, V)(V[K] aa)
{
	KeyValuePair!(K, V)[] result;
	foreach (key, value; aa)
		result ~= KeyValuePair!(K, V)(key, value);
	return result;
}

/// Get key/value pairs from AA, sorted by keys
KeyValuePair!(K, V)[] sortedPairs(K, V)(V[K] aa)
{
	KeyValuePair!(K, V)[] result;
	foreach (key; aa.keys.sort)
		result ~= KeyValuePair!(K, V)(key, aa[key]);
	return result;
}

/// Get values from AA, sorted by keys
V[] sortedValues(K, V)(in V[K] aa)
{
	V[] result;
	foreach (key; aa.keys.sort())
		result ~= aa[key];
	return result;
}

/// Merge source into target. Return target.
V[K] merge(K, V)(auto ref V[K] target, V[K] source)
{
	foreach (k, v; source)
		target[k] = v;
	return target;
}

debug(ae_unittest) unittest
{
	int[int] target;
	int[int] source = [2:4];
	merge(target, source);
	assert(source == target);

	target = [1:1, 2:2, 3:3];
	merge(target, source);
	assert(target == [1:1, 2:4, 3:3]);

	assert(merge([1:1], [2:2]) == [1:1, 2:2]);
}

debug(ae_unittest) unittest
{
	ubyte[][string] a, b;
	merge(a, b);
}

/// Slurp a range of two elements (or two-element struct/class) into an AA.
auto toAA(R)(R r)
	if (is(typeof(r.front[1])))
{
	alias K = typeof(r.front[0]);
	alias V = typeof(r.front[1]);
	V[K] result;
	foreach (pair; r)
	{
		assert(pair.length == 2);
		result[pair[0]] = pair[1];
	}
	return result;
}

/// ditto
auto toAA(R)(R r)
	if (is(typeof(r.front.tupleof)) && r.front.tupleof.length == 2 && !is(typeof(r.front[1])))
{
	return r.map!(el => tuple(el.tupleof)).toAA();
}

debug(ae_unittest) deprecated unittest
{
	assert([[2, 4]].toAA() == [2:4]);
	assert([2:4].pairs.toAA() == [2:4]);
}

/// Ensure that arr is non-null if empty.
V[K] nonNull(K, V)(V[K] aa)
{
	if (aa !is null)
		return aa;
	aa[K.init] = V.init;
	aa.remove(K.init);
	assert(aa !is null);
	return aa;
}

debug(ae_unittest) unittest
{
	int[int] aa;
	assert(aa is null);
	aa = aa.nonNull;
	assert(aa !is null);
	assert(aa.length == 0);
}

// ***************************************************************************

// Helpers for HashCollection
private
{
	alias Void = BoxedVoid;
	static assert(Void.sizeof == 0);

	// Abstraction layer for single/multi-value type holding one or many T.
	// Optimizer representation for Void.
	struct SingleOrMultiValue(bool multi, T)
	{
		alias ValueType = Select!(multi,
			// multi==true
			Select!(is(T == Void),
				size_t, // "store" the items by keeping track of their count only.
				T[],
			),

			// multi==false
			Select!(is(T == Void),
				Void,
				T[1],
			),
		);

		// Using free functions instead of struct methods,
		// as structs always have non-zero size.
	static:

		size_t length(ref const ValueType v) nothrow
		{
			static if (is(T == Void))
				static if (multi)
					return v; // count
				else
					return 1;
			else
				return v.length; // static or dynamic array
		}
	}
}

/// Base type for ordered/unordered single-value/multi-value map/set
/*private*/ struct HashCollection(K, V, bool ordered, bool multi)
{
private:
	enum bool haveValues = !is(V == void); // Not a set

	// The type for values used when a value variable is needed
	alias ValueVarType = Select!(haveValues, V, Void);

	// The type of a single element of the values of `this.lookup`.
	// When ordered==true, we use size_t (index into `this.items`).
	alias LookupItem = Select!(ordered, size_t, ValueVarType);

	// The type of the values of `this.lookup`.
	alias SM = SingleOrMultiValue!(multi, LookupItem);
	alias LookupValue = SM.ValueType;

	// Return type of assign operations, "in" operator, etc.
	static if (haveValues)
		alias ReturnType = V;
	else
		alias ReturnType = void;
	enum haveReturnType = !is(ReturnType == void);

	static if (ordered)
		alias OrderIndex = size_t;
	else
		alias OrderIndex = void;

	// DWIM: a[k] should mean key lookup for maps,
	// otherwise index lookup for ordered sets.
	static if (haveValues)
	{
		alias OpIndexKeyType = K;
		alias OpIndexValueType = V; // also the return type of opIndex
	}
	else
	{
		static if (ordered)
		{
			alias OpIndexKeyType = size_t;
			alias OpIndexValueType = K;
		}
		else
		{
			alias OpIndexKeyType = void;
			alias OpIndexValueType = void;
		}
	}
	enum haveIndexing = !is(OpIndexKeyType == void);
	static assert(haveIndexing == haveValues || ordered);
	alias IK = OpIndexKeyType;
	alias IV = OpIndexValueType;

	// The contract we try to follow is that adding/removing items in
	// one copy of the object will not affect other copies.
	// Therefore, when we have array fields, make sure they are dup'd
	// on copy, so that we don't trample older copies' data.
	enum bool needDupOnCopy = ordered;

	static if (ordered)
		/*  */ ref inout(ReturnType) lookupToReturnValue(in        LookupItem  lookupItem) inout { return items[lookupItem].returnValue; }
	else
	static if (haveValues)
		static ref inout(ReturnType) lookupToReturnValue(ref inout(LookupItem) lookupItem)       { return       lookupItem             ; }
	else
		static ref inout(ReturnType) lookupToReturnValue(ref inout(LookupItem) lookupItem)       {                                       }

	static if (ordered)
		/*  */ ref inout(IV) lookupToIndexValue(in        LookupItem  lookupItem) inout { return items[lookupItem].indexValue; }
	else
	static if (haveValues)
		static ref inout(IV) lookupToIndexValue(ref inout(LookupItem) lookupItem)       { return       lookupItem            ; }
	else
		static ref inout(IV) lookupToIndexValue(ref inout(LookupItem) lookupItem)       {                                      }

	// *** Data ***

	// This is used for all key hash lookups.
	LookupValue[K] lookup;

	static if (ordered)
	{
		struct Item
		{
			K key;
			ValueVarType value;

			static if (haveValues)
				alias /*ReturnType*/ returnValue = value;
			else
				@property ReturnType returnValue() const {}

			static if (haveValues)
				alias /*OpIndexValueType*/ indexValue = value;
			else
			static if (ordered)
				alias /*OpIndexValueType*/ indexValue = key;
		}
		Item[] items;

		enum bool canDup = is(typeof(lookup.dup)) && is(typeof(items.dup));
	}
	else
	{
		enum bool canDup = is(typeof(lookup.dup));
	}

public:

	// *** Lifetime ***

	/// Postblit
	static if (needDupOnCopy)
	{
		static if (canDup)
			this(this)
			{
				lookup = lookup.dup;
				items = items.dup;
			}
		else
			@disable this(this);
	}

	/// Create shallow copy
	static if (canDup)
	typeof(this) dup()
	{
		static if (needDupOnCopy)
			return this;
		else
		{
			typeof(this) copy;
			copy.lookup = lookup.dup;
			static if (ordered)
				copy.items = items.dup;
			return copy;
		}
	}
	
	// *** Conversions (from) ***

	/// Construct from something else
	this(Input)(Input input)
	if (is(typeof(opAssign(input))))
	{
		opAssign(input);
	}

	/// Null assignment
	ref typeof(this) opAssign(typeof(null) _)
	{
		clear();
		return this;
	}

	/// Convert from an associative type
	ref typeof(this) opAssign(AA)(AA aa)
	if (haveValues
		&& !is(AA : typeof(this))
		&& is(typeof({ foreach (ref k, ref v; aa) add(k, v); })))
	{
		clear();
		foreach (ref k, ref v; aa)
			add(k, v);
		return this;
	}

	/// Convert from an associative type of multiple items
	ref typeof(this) opAssign(AA)(AA aa)
	if (haveValues
		&& multi
		&& !is(AA : typeof(this))
		&& is(typeof({ foreach (ref k, ref vs; aa) foreach (ref v; vs) add(k, v); })))
	{
		clear();
		foreach (ref k, ref vs; aa)
			foreach (ref v; vs)
				add(k, v);
		return this;
	}

	/// Convert from a range of tuples
	ref typeof(this) opAssign(R)(R input)
	if (haveValues
		&& is(typeof({ foreach (ref pair; input) add(pair[0], pair[1]); }))
		&& !is(typeof({ foreach (ref k, ref v; input) add(k, v); }))
		&& is(typeof(input.front.length))
		&& input.front.length == 2)
	{
		clear();
		foreach (ref pair; input)
			add(pair[0], pair[1]);
		return this;
	}

	/// Convert from a range of key/value pairs
	ref typeof(this) opAssign(R)(R input)
	if (haveValues
		&& is(typeof({ foreach (ref pair; input) add(pair.key, pair.value); }))
		&& !is(typeof({ foreach (ref k, ref v; input) add(k, v); })))
	{
		clear();
		foreach (ref pair; input)
			add(pair.key, pair.value);
		return this;
	}

	/// Convert from a range of values
	ref typeof(this) opAssign(R)(R input)
	if (!haveValues
		&& !is(R : typeof(this))
		&& is(typeof({ foreach (ref v; input) add(v); })))
	{
		clear();
		foreach (ref v; input)
			add(v);
		return this;
	}

	// *** Conversions (to) ***

	/// Convert to bool (true if non-null)
	bool opCast(T)() const
	if (is(T == bool))
	{
		return lookup !is null;
	}

	/// Convert to D associative array
	static if (!ordered)
	{
		const(LookupValue[K]) toAA() const
		{
			return lookup;
		}

		static if (is(typeof(lookup.dup)))
		LookupValue[K] toAA()
		{
			return lookup.dup;
		}

		deprecated alias items = toAA;
	}

	// *** Query (basic) ***

	/// True when there are no items.
	bool empty() pure const nothrow @nogc @trusted
	{
		static if (ordered)
			return items.length == 0; // optimization
		else
			return lookup.byKey.empty; // generic version
	}

	/// Total number of items, including with duplicate keys.
	size_t length() pure const nothrow @nogc @trusted
	{
		static if (ordered)
			return items.length; // optimization
		else
		static if (!multi)
			return lookup.length; // optimization
		else // generic version
		{
			size_t result;
			foreach (ref v; lookup.byValue)
				result += SM.length(v);
			return result;
		}
	}

	// *** Query (by key) ***

	/// Check if item with this key has been added.
	/// When applicable, return a pointer to the last value added with this key.
	Select!(haveReturnType, inout(ReturnType)*, bool) opBinaryRight(string op : "in", _K)(auto ref _K key) inout
	if (is(typeof(key in lookup)))
	{
		enum missValue = select!haveReturnType(null, false);

		auto p = key in lookup;
		if (!p)
			return missValue;

		static if (haveReturnType)
			return &lookupToIndexValue((*p)[$-1]);
		else
			return true;
	}

	// *** Query (by index) ***

	/// Index access (for ordered collections).
	/// For maps, returns the key.
	static if (ordered)
	ref inout(K) atIndex()(size_t i) inout
	{
		return items[i].key;
	}

	static if (ordered)
	deprecated alias at = atIndex;

	/// ditto
	static if (ordered)
	auto ref inout(K) getAtIndex()(size_t i, auto ref K defaultValue) inout
	{
		return i < items.length ? items[i].key : defaultValue;
	}

	static if (ordered)
	deprecated alias getAt = getAtIndex;

	// *** Query (by key/index - DWIM) ***

	/// Index operator.
	/// The key must exist. Indexing with a key which does not exist
	/// is an error.
	static if (haveIndexing)
	ref inout(IV) opIndex()(auto ref const IK k) inout
	{
		static if (haveValues)
			return lookupToIndexValue(lookup[k][$-1]);
		else
			return items[k].indexValue;
	}

	/// Retrieve last value associated with key, or `defaultValue` if none.
	static if (haveIndexing)
	{
		static if (haveValues)
			auto ref IV get(this This, KK)(auto ref KK k, auto ref IV defaultValue)
			if (is(typeof(k in lookup)))
			{
				auto p = k in lookup;
				return p ? lookupToIndexValue((*p)[$-1]) : defaultValue;
			}
		else
			auto ref IV get(this This, KK)(auto ref KK k, auto ref IV defaultValue)
			if (is(typeof(items[k])))
			{
				return k < items.length ? items[k].returnValue : defaultValue;
			}
	}

	// *** Query (ranges) ***

	/// Return a range which iterates over key/value pairs.
	static if (haveValues)
	auto byKeyValue(this This)()
	{
		static if (ordered)
			return items;
		else
		{
			return lookup
				.byKeyValue
				.map!(pair =>
					pair
					.value
					.map!(value => KeyValuePair!(K, V)(pair.key, value))
				)
				.joiner;
		}
	}

	/// ditto
	static if (haveValues)
	auto byPair(this This)()
	{
		return byKeyValue
			.map!(pair => tuple!("key", "value")(pair.key, pair.value));
	}

	/// Return a range which iterates over all keys.
	/// Duplicate keys will occur several times in the range.
	auto byKey(this This)()
	{
		static if (ordered)
		{
			static ref getKey(MItem)(ref MItem item) { return item.key; }
			return items.map!getKey;
		}
		else
		{
			return lookup
				.byKeyValue
				.map!(pair =>
					pair.key.repeat(SM.length(pair.value))
				)
				.joiner;
		}
	}

	/// Return a range which iterates over all values.
	static if (haveValues)
	auto byValue(this This)()
	{
		static if (ordered)
		{
			static ref getValue(MItem)(ref MItem item) { return item.value; }
			return items.map!getValue;
		}
		else
		{
			return lookup
				.byKeyValue
				.map!(pair =>
					pair
					.value
				)
				.joiner;
		}
	}

	/// Returns all keys as an array.
	@property auto keys(this This)() { return byKey.array; }

	/// Returns all values as an array.
	@property auto values(this This)() { return byValue.array; }

	// *** Query (search by key) ***

	static if (ordered)
	{
		/// Returns index of key `k`.
		sizediff_t indexOf()(auto ref const K k) const
		{
			auto p = k in lookup;
			return p ? (*p)[0] : -1;
		}

		/// Returns all indices of key `k`.
		inout(size_t)[] indicesOf()(auto ref const K k) inout
		{
			auto p = k in lookup;
			return p ? (*p)[] : null;
		}
	}

	/// Return the number of items with the given key.
	/// When multi==false, always returns 0 or 1.
	size_t count()(auto ref K k)
	{
		static if (ordered)
			return indicesOf(k).length;
		else
		{
			auto p = k in lookup;
			return p ? SM.length(*p) : 0;
		}
	}

	/// Return a range with all values with the given key.
	/// If the key is not present, returns an empty range.
	static if (haveValues)
	auto byValueOf(this This)(auto ref K k)
	{
		static if (ordered)
			return indicesOf(k).map!(index => items[index].value);
		else
			return valuesOf(k);
	}

	/// Return an array with all values with the given key.
	/// If the key is not present, returns an empty array.
	static if (haveValues)
	V[] valuesOf()(auto ref K k)
	{
		static if (ordered)
			return byValueOf(k).array;
		else
		{
			static if (multi)
				return lookup.get(k, null);
			else
			{
				auto p = k in lookup;
				return p ? (*p)[] : null;
			}
		}
	}

	static if (haveValues)
	deprecated alias getAll = valuesOf;

	// *** Iteration ***

	// Note: When iterating over keys in an AA, you must choose
	// mutable OR ref, but not both. This is an important reason for
	// the complexity below.

	private enum isParameterRef(size_t index, fun...) = (){
		foreach (keyStorageClass; __traits(getParameterStorageClasses, fun[0], index))
			if (keyStorageClass == "ref")
				return true;
		return false;
	}();

	private int opApplyImpl(this This, Dg)(scope Dg dg)
	{
		enum single = arity!dg == 1;

		int result = 0;

		static if (ordered)
		{
			foreach (ref item; items)
			{
				static if (single)
					result = dg(item.indexValue);
				else
					result = dg(item.key, item.value);
				if (result)
					break;
			}
		}
		else
		{
			static if (single && haveValues)
			{
				// Dg accepts value only, so use whatever we want for the key iteration.
				alias LK = const(K);
				enum useRef = true;
			}
			else
			{
				// Dg accepts a key (and maybe a value), so use the Dg signature for iteration.
				alias LK = Parameters!Dg[0];
				enum useRef = isParameterRef!(0, Dg);
			}
			// LookupValue or const(LookupValue), depending on the constness of This
			alias LV = typeof(lookup.values[0]);

			bool handle()(ref LK key, ref LV values)
			{
				static if (haveValues)
				{
					foreach (ref value; values)
					{
						static if (single)
							result = dg(value);
						else
							result = dg(key, value);
						if (result)
							return false;
					}
				}
				else
				{
					foreach (iteration; 0 .. SM.length(values))
					{
						static assert(single);
						result = dg(key);
						if (result)
							return false;
					}
				}
				return true;
			}

			static if (useRef)
			{
				foreach (ref LK key, ref LV values; lookup)
					if (!handle(key, values))
						break;
			}
			else
			{
				foreach (LK key, ref LV values; lookup)
					if (!handle(key, values))
						break;
			}
		}
		return result;
	}

	private alias KeyIterationType(bool isConst, bool byRef) = typeof(*(){

		static if (isConst)
			const bool[K] aa;
		else
			bool[K] aa;

		static if (byRef)
			foreach (ref k, v; aa)
				return &k;
		else
			foreach (k, v; aa)
				return &k;

		assert(false);
	}());

	private enum needRefOverload(bool isConst) =
		// Unfortunately this doesn't work: https://issues.dlang.org/show_bug.cgi?id=21683
		// !is(KeyIterationType!(isConst, false) == KeyIterationType!(isConst, true));
		!isCopyable!K;

	private template needIter(bool isConst, bool byRef)
	{
		static if (!isCopyable!K)
			enum needIter = byRef;
		else
		static if (!byRef)
			enum needIter = true;
		else
			enum needIter = needRefOverload!isConst;
	}

	static if (haveValues)
	{
		/// Iterate over values (maps).
		int opApply(scope int delegate(      ref V)                  dg)                        { return opApplyImpl(dg); }
		int opApply(scope int delegate(      ref V)            @nogc dg)                  @nogc { return opApplyImpl(dg); } /// ditto
		int opApply(scope int delegate(      ref V)      @safe       dg)            @safe       { return opApplyImpl(dg); } /// ditto
		int opApply(scope int delegate(      ref V)      @safe @nogc dg)            @safe @nogc { return opApplyImpl(dg); } /// ditto
		int opApply(scope int delegate(      ref V) pure             dg)       pure             { return opApplyImpl(dg); } /// ditto
		int opApply(scope int delegate(      ref V) pure       @nogc dg)       pure       @nogc { return opApplyImpl(dg); } /// ditto
		int opApply(scope int delegate(      ref V) pure @safe       dg)       pure @safe       { return opApplyImpl(dg); } /// ditto
		int opApply(scope int delegate(      ref V) pure @safe @nogc dg)       pure @safe @nogc { return opApplyImpl(dg); } /// ditto
		int opApply(scope int delegate(const ref V)                  dg) const                  { return opApplyImpl(dg); } /// ditto
		int opApply(scope int delegate(const ref V)            @nogc dg) const            @nogc { return opApplyImpl(dg); } /// ditto
		int opApply(scope int delegate(const ref V)      @safe       dg) const      @safe       { return opApplyImpl(dg); } /// ditto
		int opApply(scope int delegate(const ref V)      @safe @nogc dg) const      @safe @nogc { return opApplyImpl(dg); } /// ditto
		int opApply(scope int delegate(const ref V) pure             dg) const pure             { return opApplyImpl(dg); } /// ditto
		int opApply(scope int delegate(const ref V) pure       @nogc dg) const pure       @nogc { return opApplyImpl(dg); } /// ditto
		int opApply(scope int delegate(const ref V) pure @safe       dg) const pure @safe       { return opApplyImpl(dg); } /// ditto
		int opApply(scope int delegate(const ref V) pure @safe @nogc dg) const pure @safe @nogc { return opApplyImpl(dg); } /// ditto
	}
	else // !haveValues (sets)
	{
		/// Iterate over keys (sets).
		static if (needIter!(false, false))
		{
			int opApply(scope int delegate(    KeyIterationType!(false, false))                  dg)                        { return opApplyImpl(dg); }
			int opApply(scope int delegate(    KeyIterationType!(false, false))            @nogc dg)                  @nogc { return opApplyImpl(dg); } /// ditto
			int opApply(scope int delegate(    KeyIterationType!(false, false))      @safe       dg)            @safe       { return opApplyImpl(dg); } /// ditto
			int opApply(scope int delegate(    KeyIterationType!(false, false))      @safe @nogc dg)            @safe @nogc { return opApplyImpl(dg); } /// ditto
			int opApply(scope int delegate(    KeyIterationType!(false, false)) pure             dg)       pure             { return opApplyImpl(dg); } /// ditto
			int opApply(scope int delegate(    KeyIterationType!(false, false)) pure       @nogc dg)       pure       @nogc { return opApplyImpl(dg); } /// ditto
			int opApply(scope int delegate(    KeyIterationType!(false, false)) pure @safe       dg)       pure @safe       { return opApplyImpl(dg); } /// ditto
			int opApply(scope int delegate(    KeyIterationType!(false, false)) pure @safe @nogc dg)       pure @safe @nogc { return opApplyImpl(dg); } /// ditto
		}
		static if (needIter!(true, false))
		{
			int opApply(scope int delegate(    KeyIterationType!(true, false))                  dg) const                  { return opApplyImpl(dg); } /// ditto
			int opApply(scope int delegate(    KeyIterationType!(true, false))            @nogc dg) const            @nogc { return opApplyImpl(dg); } /// ditto
			int opApply(scope int delegate(    KeyIterationType!(true, false))      @safe       dg) const      @safe       { return opApplyImpl(dg); } /// ditto
			int opApply(scope int delegate(    KeyIterationType!(true, false))      @safe @nogc dg) const      @safe @nogc { return opApplyImpl(dg); } /// ditto
			int opApply(scope int delegate(    KeyIterationType!(true, false)) pure             dg) const pure             { return opApplyImpl(dg); } /// ditto
			int opApply(scope int delegate(    KeyIterationType!(true, false)) pure       @nogc dg) const pure       @nogc { return opApplyImpl(dg); } /// ditto
			int opApply(scope int delegate(    KeyIterationType!(true, false)) pure @safe       dg) const pure @safe       { return opApplyImpl(dg); } /// ditto
			int opApply(scope int delegate(    KeyIterationType!(true, false)) pure @safe @nogc dg) const pure @safe @nogc { return opApplyImpl(dg); } /// ditto
		}
		static if (needIter!(false, true))
		{
			int opApply(scope int delegate(ref KeyIterationType!(false, true))                  dg)                        { return opApplyImpl(dg); }
			int opApply(scope int delegate(ref KeyIterationType!(false, true))            @nogc dg)                  @nogc { return opApplyImpl(dg); } /// ditto
			int opApply(scope int delegate(ref KeyIterationType!(false, true))      @safe       dg)            @safe       { return opApplyImpl(dg); } /// ditto
			int opApply(scope int delegate(ref KeyIterationType!(false, true))      @safe @nogc dg)            @safe @nogc { return opApplyImpl(dg); } /// ditto
			int opApply(scope int delegate(ref KeyIterationType!(false, true)) pure             dg)       pure             { return opApplyImpl(dg); } /// ditto
			int opApply(scope int delegate(ref KeyIterationType!(false, true)) pure       @nogc dg)       pure       @nogc { return opApplyImpl(dg); } /// ditto
			int opApply(scope int delegate(ref KeyIterationType!(false, true)) pure @safe       dg)       pure @safe       { return opApplyImpl(dg); } /// ditto
			int opApply(scope int delegate(ref KeyIterationType!(false, true)) pure @safe @nogc dg)       pure @safe @nogc { return opApplyImpl(dg); } /// ditto
		}
		static if (needIter!(true, true))
		{
			int opApply(scope int delegate(ref KeyIterationType!(true, true))                  dg) const                  { return opApplyImpl(dg); } /// ditto
			int opApply(scope int delegate(ref KeyIterationType!(true, true))            @nogc dg) const            @nogc { return opApplyImpl(dg); } /// ditto
			int opApply(scope int delegate(ref KeyIterationType!(true, true))      @safe       dg) const      @safe       { return opApplyImpl(dg); } /// ditto
			int opApply(scope int delegate(ref KeyIterationType!(true, true))      @safe @nogc dg) const      @safe @nogc { return opApplyImpl(dg); } /// ditto
			int opApply(scope int delegate(ref KeyIterationType!(true, true)) pure             dg) const pure             { return opApplyImpl(dg); } /// ditto
			int opApply(scope int delegate(ref KeyIterationType!(true, true)) pure       @nogc dg) const pure       @nogc { return opApplyImpl(dg); } /// ditto
			int opApply(scope int delegate(ref KeyIterationType!(true, true)) pure @safe       dg) const pure @safe       { return opApplyImpl(dg); } /// ditto
			int opApply(scope int delegate(ref KeyIterationType!(true, true)) pure @safe @nogc dg) const pure @safe @nogc { return opApplyImpl(dg); } /// ditto
		}
	}

	static if (haveValues)
	{
		/// Iterate over keys and values.
		static if (needIter!(false, false))
		{
			int opApply(scope int delegate(    KeyIterationType!(false, false),       ref V)                  dg)                        { return opApplyImpl(dg); }
			int opApply(scope int delegate(    KeyIterationType!(false, false),       ref V)            @nogc dg)                  @nogc { return opApplyImpl(dg); } /// ditto
			int opApply(scope int delegate(    KeyIterationType!(false, false),       ref V)      @safe       dg)            @safe       { return opApplyImpl(dg); } /// ditto
			int opApply(scope int delegate(    KeyIterationType!(false, false),       ref V)      @safe @nogc dg)            @safe @nogc { return opApplyImpl(dg); } /// ditto
			int opApply(scope int delegate(    KeyIterationType!(false, false),       ref V) pure             dg)       pure             { return opApplyImpl(dg); } /// ditto
			int opApply(scope int delegate(    KeyIterationType!(false, false),       ref V) pure       @nogc dg)       pure       @nogc { return opApplyImpl(dg); } /// ditto
			int opApply(scope int delegate(    KeyIterationType!(false, false),       ref V) pure @safe       dg)       pure @safe       { return opApplyImpl(dg); } /// ditto
			int opApply(scope int delegate(    KeyIterationType!(false, false),       ref V) pure @safe @nogc dg)       pure @safe @nogc { return opApplyImpl(dg); } /// ditto
		}
		static if (needIter!(true, false))
		{
			int opApply(scope int delegate(    KeyIterationType!(true, false), const ref V)                  dg) const                  { return opApplyImpl(dg); }
			int opApply(scope int delegate(    KeyIterationType!(true, false), const ref V)            @nogc dg) const            @nogc { return opApplyImpl(dg); } /// ditto
			int opApply(scope int delegate(    KeyIterationType!(true, false), const ref V)      @safe       dg) const      @safe       { return opApplyImpl(dg); } /// ditto
			int opApply(scope int delegate(    KeyIterationType!(true, false), const ref V)      @safe @nogc dg) const      @safe @nogc { return opApplyImpl(dg); } /// ditto
			int opApply(scope int delegate(    KeyIterationType!(true, false), const ref V) pure             dg) const pure             { return opApplyImpl(dg); } /// ditto
			int opApply(scope int delegate(    KeyIterationType!(true, false), const ref V) pure       @nogc dg) const pure       @nogc { return opApplyImpl(dg); } /// ditto
			int opApply(scope int delegate(    KeyIterationType!(true, false), const ref V) pure @safe       dg) const pure @safe       { return opApplyImpl(dg); } /// ditto
			int opApply(scope int delegate(    KeyIterationType!(true, false), const ref V) pure @safe @nogc dg) const pure @safe @nogc { return opApplyImpl(dg); } /// ditto
		}
		static if (needIter!(false, true))
		{
			int opApply(scope int delegate(ref KeyIterationType!(false, true),       ref V)                  dg)                        { return opApplyImpl(dg); }
			int opApply(scope int delegate(ref KeyIterationType!(false, true),       ref V)            @nogc dg)                  @nogc { return opApplyImpl(dg); } /// ditto
			int opApply(scope int delegate(ref KeyIterationType!(false, true),       ref V)      @safe       dg)            @safe       { return opApplyImpl(dg); } /// ditto
			int opApply(scope int delegate(ref KeyIterationType!(false, true),       ref V)      @safe @nogc dg)            @safe @nogc { return opApplyImpl(dg); } /// ditto
			int opApply(scope int delegate(ref KeyIterationType!(false, true),       ref V) pure             dg)       pure             { return opApplyImpl(dg); } /// ditto
			int opApply(scope int delegate(ref KeyIterationType!(false, true),       ref V) pure       @nogc dg)       pure       @nogc { return opApplyImpl(dg); } /// ditto
			int opApply(scope int delegate(ref KeyIterationType!(false, true),       ref V) pure @safe       dg)       pure @safe       { return opApplyImpl(dg); } /// ditto
			int opApply(scope int delegate(ref KeyIterationType!(false, true),       ref V) pure @safe @nogc dg)       pure @safe @nogc { return opApplyImpl(dg); } /// ditto
		}
		static if (needIter!(true, true))
		{
			int opApply(scope int delegate(ref KeyIterationType!(true, true), const ref V)                  dg) const                  { return opApplyImpl(dg); }
			int opApply(scope int delegate(ref KeyIterationType!(true, true), const ref V)            @nogc dg) const            @nogc { return opApplyImpl(dg); } /// ditto
			int opApply(scope int delegate(ref KeyIterationType!(true, true), const ref V)      @safe       dg) const      @safe       { return opApplyImpl(dg); } /// ditto
			int opApply(scope int delegate(ref KeyIterationType!(true, true), const ref V)      @safe @nogc dg) const      @safe @nogc { return opApplyImpl(dg); } /// ditto
			int opApply(scope int delegate(ref KeyIterationType!(true, true), const ref V) pure             dg) const pure             { return opApplyImpl(dg); } /// ditto
			int opApply(scope int delegate(ref KeyIterationType!(true, true), const ref V) pure       @nogc dg) const pure       @nogc { return opApplyImpl(dg); } /// ditto
			int opApply(scope int delegate(ref KeyIterationType!(true, true), const ref V) pure @safe       dg) const pure @safe       { return opApplyImpl(dg); } /// ditto
			int opApply(scope int delegate(ref KeyIterationType!(true, true), const ref V) pure @safe @nogc dg) const pure @safe @nogc { return opApplyImpl(dg); } /// ditto
		}
	}

	private struct ByRef(bool isConst)
	{
		static if (isConst)
			const(HashCollection)* c;
		else
			HashCollection* c;

		static if (haveValues)
		{
			static if (isConst)
			{
				int opApply(scope int delegate(ref KeyIterationType!(true , true ), const ref V)                  dg) const                  { return c.opApplyImpl(dg); }
				int opApply(scope int delegate(ref KeyIterationType!(true , true ), const ref V)            @nogc dg) const            @nogc { return c.opApplyImpl(dg); } /// ditto
				int opApply(scope int delegate(ref KeyIterationType!(true , true ), const ref V)      @safe       dg) const      @safe       { return c.opApplyImpl(dg); } /// ditto
				int opApply(scope int delegate(ref KeyIterationType!(true , true ), const ref V)      @safe @nogc dg) const      @safe @nogc { return c.opApplyImpl(dg); } /// ditto
				int opApply(scope int delegate(ref KeyIterationType!(true , true ), const ref V) pure             dg) const pure             { return c.opApplyImpl(dg); } /// ditto
				int opApply(scope int delegate(ref KeyIterationType!(true , true ), const ref V) pure       @nogc dg) const pure       @nogc { return c.opApplyImpl(dg); } /// ditto
				int opApply(scope int delegate(ref KeyIterationType!(true , true ), const ref V) pure @safe       dg) const pure @safe       { return c.opApplyImpl(dg); } /// ditto
				int opApply(scope int delegate(ref KeyIterationType!(true , true ), const ref V) pure @safe @nogc dg) const pure @safe @nogc { return c.opApplyImpl(dg); } /// ditto
			}
			else // !isConst
			{
				int opApply(scope int delegate(ref KeyIterationType!(false, true ),       ref V)                  dg)                        { return c.opApplyImpl(dg); }
				int opApply(scope int delegate(ref KeyIterationType!(false, true ),       ref V)            @nogc dg)                  @nogc { return c.opApplyImpl(dg); } /// ditto
				int opApply(scope int delegate(ref KeyIterationType!(false, true ),       ref V)      @safe       dg)            @safe       { return c.opApplyImpl(dg); } /// ditto
				int opApply(scope int delegate(ref KeyIterationType!(false, true ),       ref V)      @safe @nogc dg)            @safe @nogc { return c.opApplyImpl(dg); } /// ditto
				int opApply(scope int delegate(ref KeyIterationType!(false, true ),       ref V) pure             dg)       pure             { return c.opApplyImpl(dg); } /// ditto
				int opApply(scope int delegate(ref KeyIterationType!(false, true ),       ref V) pure       @nogc dg)       pure       @nogc { return c.opApplyImpl(dg); } /// ditto
				int opApply(scope int delegate(ref KeyIterationType!(false, true ),       ref V) pure @safe       dg)       pure @safe       { return c.opApplyImpl(dg); } /// ditto
				int opApply(scope int delegate(ref KeyIterationType!(false, true ),       ref V) pure @safe @nogc dg)       pure @safe @nogc { return c.opApplyImpl(dg); } /// ditto
			}
		}
		else // !haveValues (sets)
		{
			static if (isConst)
			{
				int opApply(scope int delegate(ref KeyIterationType!(true , true ))                  dg) const                  { return c.opApplyImpl(dg); }
				int opApply(scope int delegate(ref KeyIterationType!(true , true ))            @nogc dg) const            @nogc { return c.opApplyImpl(dg); } /// ditto
				int opApply(scope int delegate(ref KeyIterationType!(true , true ))      @safe       dg) const      @safe       { return c.opApplyImpl(dg); } /// ditto
				int opApply(scope int delegate(ref KeyIterationType!(true , true ))      @safe @nogc dg) const      @safe @nogc { return c.opApplyImpl(dg); } /// ditto
				int opApply(scope int delegate(ref KeyIterationType!(true , true )) pure             dg) const pure             { return c.opApplyImpl(dg); } /// ditto
				int opApply(scope int delegate(ref KeyIterationType!(true , true )) pure       @nogc dg) const pure       @nogc { return c.opApplyImpl(dg); } /// ditto
				int opApply(scope int delegate(ref KeyIterationType!(true , true )) pure @safe       dg) const pure @safe       { return c.opApplyImpl(dg); } /// ditto
				int opApply(scope int delegate(ref KeyIterationType!(true , true )) pure @safe @nogc dg) const pure @safe @nogc { return c.opApplyImpl(dg); } /// ditto
			}
			else // !isConst
			{
				int opApply(scope int delegate(ref KeyIterationType!(false, true ))                  dg)                        { return c.opApplyImpl(dg); }
				int opApply(scope int delegate(ref KeyIterationType!(false, true ))            @nogc dg)                  @nogc { return c.opApplyImpl(dg); } /// ditto
				int opApply(scope int delegate(ref KeyIterationType!(false, true ))      @safe       dg)            @safe       { return c.opApplyImpl(dg); } /// ditto
				int opApply(scope int delegate(ref KeyIterationType!(false, true ))      @safe @nogc dg)            @safe @nogc { return c.opApplyImpl(dg); } /// ditto
				int opApply(scope int delegate(ref KeyIterationType!(false, true )) pure             dg)       pure             { return c.opApplyImpl(dg); } /// ditto
				int opApply(scope int delegate(ref KeyIterationType!(false, true )) pure       @nogc dg)       pure       @nogc { return c.opApplyImpl(dg); } /// ditto
				int opApply(scope int delegate(ref KeyIterationType!(false, true )) pure @safe       dg)       pure @safe       { return c.opApplyImpl(dg); } /// ditto
				int opApply(scope int delegate(ref KeyIterationType!(false, true )) pure @safe @nogc dg)       pure @safe @nogc { return c.opApplyImpl(dg); } /// ditto
			}
		}
	}

	/// Returns an object that allows iterating over this collection with ref keys.
	/// Workaround for https://issues.dlang.org/show_bug.cgi?id=21683
	auto byRef()       return { return ByRef!false(&this); }
	auto byRef() const return { return ByRef!true (&this); } /// ditto

	// *** Mutation (addition) ***

	private enum AddMode
	{
		add,     /// Always add value
		replace, /// Replace all previous values
		require, /// Only add value if it did not exist before
		addNew,  /// Only add value if it did not exist before; call getValue in that case
	}

	private auto addImpl(AddMode mode, AK, GV)(ref AK key, scope GV getValue)
	if (is(AK : K))
	{
		static if (ordered)
		{
			size_t addedIndex;

			static if (multi && mode == AddMode.add)
			{
				addedIndex = items.length;
				lookup[key] ~= addedIndex;
				items ~= Item(key, getValue());
			}
			else
			{
				lookup.updateVoid(key,
					delegate LookupValue()
					{
						addedIndex = items.length;
						auto item = Item(key, getValue());
						items.length++;
						move(item, items[$-1]);
						return [addedIndex];
					},
					delegate void(ref LookupValue existingIndex)
					{
						addedIndex = existingIndex[0];
						static if (mode != AddMode.require && mode != AddMode.addNew)
						{
							static if (multi)
							{
								static assert(mode == AddMode.replace);
								existingIndex = existingIndex[0 .. 1];
							}
							items[addedIndex].value = getValue();
						}
					});
			}

			auto self = &this;
			static struct Result
			{
				size_t orderIndex;
				typeof(self) context;
				@property ref auto returnValue() { return context.items[orderIndex].returnValue; }
			}
			return Result(addedIndex, self);
		}
		else // ordered
		{
			static if (haveValues)
			{
				static struct Result
				{
					ReturnType* ptr;
					@property ref ReturnType returnValue() { return *ptr; }
				}

				static if (mode == AddMode.require || mode == AddMode.addNew)
					return Result(&(lookup.require(key, [getValue()]))[0]);
				else
				static if (multi && mode == AddMode.add)
					return Result(&(lookup[key] ~= getValue())[$-1]);
				else
					return Result(&(lookup[key] = [getValue()])[0]);
			}
			else
			{
				static if (multi)
				{
					static if (mode == AddMode.require)
						lookup.require(key, 1);
					else
					static if (mode == AddMode.addNew)
						lookup.require(key, progn(getValue(), 1));
					else
					static if (mode == AddMode.add)
						lookup[key]++;
					else
						lookup[key] = 1;
				}
				else
				{
					static if (mode == AddMode.addNew)
						lookup.require(key, progn(getValue(), LookupValue.init));
					else
						lookup[key] = LookupValue.init;
				}
				// This branch returns void, as there is no reasonable
				// ref to an AA key that we can return here.
				static struct Result { @property void returnValue(){} }
				return Result();
			}
		}
	}

	/*private*/ template _addSetFunc(AddMode mode)
	{
		static if (haveValues)
		{
			ref ReturnType _addSetFunc(AK, AV)(auto ref AK key, ref AV value)
			if (is(AK : K) && is(AV : V))
			{
				return addImpl!mode(key, () => value).returnValue;
			}

			ref ReturnType _addSetFunc(AK, AV)(auto ref AK key, AV value)
			if (is(AK : K) && is(AV : V))
			{
				return addImpl!mode(key, () => move(value)).returnValue;
			}
		}
		else
		{
			ref ReturnType _addSetFunc(AK)(auto ref AK key)
			if (is(AK : K))
			{
				ValueVarType value; // void[0]
				return addImpl!mode(key, () => value).returnValue;
			}
		}
	}

	/// Add an item.
	alias add = _addSetFunc!(AddMode.add);

	/// Ensure a key exists (with the given value).
	/// When `multi==true`, replaces all previous entries with this key.
	/// Otherwise, behaves identically to `add`.
	alias set = _addSetFunc!(AddMode.replace);

	/// Add `value` only if `key` is not present.
	static if (haveValues)
	ref V require()(auto ref K key, lazy V value = V.init)
	{
		return addImpl!(AddMode.require)(key, () => value).returnValue;
	}

	static if (ordered)
	size_t requireIndex()(auto ref K key, lazy ValueVarType value = ValueVarType.init)
	{
		return addImpl!(AddMode.require)(key, () => value).orderIndex;
	}

	deprecated alias getOrAdd = require;

	private alias UpdateFuncRT(U) = typeof({ U u = void; V v = void; return u(v); }());

	/// If `key` is present, call `update` for every value;
	/// otherwise, add new value with `create`.
	static if (haveValues)
	void update(C, U)(auto ref K key, scope C create, scope U update)
	if (is(typeof(create()) : V) && (is(UpdateFuncRT!U : V) || is(UpdateFuncRT!U == void)))
	{
		static if (ordered)
		{
			lookup.updateVoid(key,
				delegate LookupValue()
				{
					auto addedIndex = items.length;
					items ~= Item(key, create());
					return [addedIndex];
				},
				delegate void(ref LookupValue existingIndex)
				{
					foreach (i; existingIndex)
						static if (is(UpdateFuncRT!U == void))
							update(items[i].value);
						else
							items[i].value = update(items[i].value);
				});
		}
		else // ordered
		{
			lookup.updateVoid(key,
				delegate LookupValue ()
				{
					return [create()];
				},
				delegate void (ref LookupValue values)
				{
					foreach (ref value; values)
						static if (is(UpdateFuncRT!U == void))
							update(value);
						else
							value = update(value);
				});
		}
	}

	static if (haveValues)
	{
		bool addNew()(auto ref K key, lazy V value = V.init)
		{
			bool added = false;
			// update(key,
			// 	delegate V   (       ) { added = true ; return value; },
			// 	delegate void(ref V v) { added = false;               },
			// );
			addImpl!(AddMode.addNew)(key, { added = true; return value; });
			return added;
		}
	}
	else
	{
		bool addNew()(auto ref K key)
		{
			bool added = false;
			ValueVarType value; // void[0]
			addImpl!(AddMode.addNew)(key, { added = true; return value; });
			return added;
		}
	}

	// *** Mutation (editing) ***

	static if (haveIndexing)
	{
		static if (haveValues)
		{
			/// Same as `set(k, v)`.
			ref IV opIndexAssign(AK, AV)(ref AV v, auto ref AK k)
			if (is(AK : K) && is(AV : V))
			{
				return set(k, v);
			}

			ref IV opIndexAssign(AK, AV)(AV v, auto ref AK k)
			if (is(AK : K) && is(AV : V))
			{
				return set(k, move(v));
			} /// ditto

			/// Perform cumulative operation with value
			/// (initialized with `.init` if the key does not exist).
			ref IV opIndexOpAssign(string op, AK, AV)(auto ref AV v, auto ref AK k)
			if (is(AK : K) && is(AV : V))
			{
				auto pv = &require(k);
				return mixin("(*pv) " ~ op ~ "= v");
			}

			/// Perform unary operation with value
			/// (initialized with `.init` if the key does not exist).
			ref IV opIndexUnary(string op, AK)(auto ref AK k)
			if (is(AK : K))
			{
				auto pv = &require(k);
				mixin("(*pv) " ~ op ~ ";");
				return *pv;
			}
		}
		else
		{
			private ref K editIndex(size_t index, scope void delegate(ref K) edit)
			{
				auto item = &items[index];
				K oldKey = item.key;
				auto pOldIndices = oldKey in lookup;
				assert(pOldIndices);

				edit(item.key);

				// Add new value

				lookup.updateVoid(item.key,
					delegate LookupValue()
					{
						// New value did not exist.
						if ((*pOldIndices).length == 1)
						{
							// Optimization - migrate the Indexes value
							assert((*pOldIndices)[0] == index);
							return *pOldIndices;
						}
						else
							return [index];
					},
					delegate void(ref LookupValue existingIndex)
					{
						// Value(s) with the new key already existed
						static if (multi)
							existingIndex ~= index;
						else
							assert(false, "Collision after in-place edit of a non-multi ordered set element");
					});

				// Remove old value

				if ((*pOldIndices).length == 1)
					lookup.remove(oldKey);
				else
				static if (multi)
					*pOldIndices = (*pOldIndices).remove!(i => i == index);
				else
					assert(false); // Should be unreachable (`if` above will always be true)

				return item.key;
			}

			/// Allows writing to ordered sets by index.
			/// The total number of elements never changes as a result
			/// of such an operation - a consequence of which is that
			/// if multi==false, changing the value to one that's
			/// already in the set is an error.
			ref IV opIndexAssign()(auto ref IV v, auto ref IK k)
			{
				static if (haveValues)
					return set(k, v);
				else
					return editIndex(k, (ref IV e) { e = v; });
			}

			/// Perform cumulative operation with value at index.
			ref IV opIndexOpAssign(string op)(auto ref VV v, auto ref IK k)
			{
				return editIndex(k, (ref IV e) { mixin("e " ~ op ~ "= v;"); });
			}

			/// Perform unary operation with value at index.
			ref IV opIndexUnary(string op)(auto ref IK k)
			{
				return editIndex(k, (ref IV e) { mixin("e " ~ op ~ ";"); });
			}
		}
	}

	// *** Mutation (removal) ***

	/// Removes all elements with the given key.
	bool remove(AK)(auto ref AK key)
	if (is(typeof(lookup.remove(key))))
	{
		static if (ordered)
		{
			auto p = key in lookup;
			if (!p)
				return false;

			auto targets = *p;
			foreach (target; targets)
			{
				items = items.remove!(SwapStrategy.stable)(target);
				foreach (ref k, ref vs; lookup)
					foreach (ref v; vs)
						if (v > target)
							v--;
			}
			auto success = lookup.remove(key);
			assert(success);
			return true;
		}
		else
			return lookup.remove(key);
	}

	/// Removes all elements.
	void clear()
	{
		lookup.clear();
		static if (ordered)
			items = null;
	}
}

/// An associative array which retains the order in which elements were added.
alias OrderedMap(K, V) = HashCollection!(K, V, true, false);

debug(ae_unittest) unittest
{
	alias M = OrderedMap!(string, int);
	M m;
	m["a"] = 1;
	m["b"] = 2;
	m["c"] = 3;
	assert(m.length == 3);
	assert("a" in m);
	assert("d" !in m);

	assert( m.addNew("x", 1));
	assert(!m.addNew("x", 2));
	assert(m["x"] == 1);
	assert( m.remove("x"));
	assert(!m.remove("x"));

	{
		auto r = m.byKeyValue;
		assert(!r.empty);
		assert(r.front.key == "a");
		r.popFront();
		assert(!r.empty);
		assert(r.front.key == "b");
		r.popFront();
		assert(!r.empty);
		assert(r.front.key == "c");
		r.popFront();
		assert(r.empty);
	}

	assert(m.byKey.equal(["a", "b", "c"]));
	assert(m.byValue.equal([1, 2, 3]));
	assert(m.byKeyValue.map!(p => p.key).equal(m.byKey));
	assert(m.byKeyValue.map!(p => p.value).equal(m.byValue));
	assert(m.keys == ["a", "b", "c"]);
	assert(m.values == [1, 2, 3]);

	{
		const(M)* c = &m;
		assert(c.byKey.equal(["a", "b", "c"]));
		assert(c.byValue.equal([1, 2, 3]));
		assert(c.keys == ["a", "b", "c"]);
		assert(c.values == [1, 2, 3]);
	}

	m.byValue.front = 5;
	assert(m.byValue.equal([5, 2, 3]));

	m.remove("a");
	assert(m.length == 2);
	m["x"] -= 1;
	assert(m["x"] == -1);
	++m["y"];
	assert(m["y"] == 1);
	auto cm = cast(const)m.dup;
	foreach (k, v; cm)
		if (k == "x")
			assert(v == -1);
}

debug(ae_unittest) unittest
{
	OrderedMap!(string, int) m;
	m["a"] = 1;
	m["b"] = 2;
	m.remove("a");
	assert(m["b"] == 2);
}

debug(ae_unittest) unittest
{
	OrderedMap!(string, int) m;
	m["a"] = 1;
	auto m2 = m;
	m2.remove("a");
	m2["b"] = 2;
	assert(m["a"] == 1);
}

debug(ae_unittest) unittest
{
	OrderedMap!(string, int) m;
	m["a"] = 1;
	m["b"] = 2;
	auto m2 = m;
	m.remove("a");
	assert(m2["a"] == 1);
}

debug(ae_unittest) unittest
{
	class C {}
	const OrderedMap!(string, C) m;
	cast(void)m.byKeyValue;
}

debug(ae_unittest) unittest
{
	OrderedMap!(int, int) m;
	m.update(10,
		{ return 20; },
		(ref int k) { k++; return 30; },
	);
	assert(m.length == 1 && m[10] == 20);
	m.update(10,
		{ return 40; },
		(ref int k) { k++; return 50; },
	);
	assert(m.length == 1 && m[10] == 50);
}

// https://issues.dlang.org/show_bug.cgi?id=18606
debug(ae_unittest) unittest
{
	struct S
	{
		struct T
		{
			int foo;
			int[] bar;
		}

		OrderedMap!(int, T) m;
	}
}

debug(ae_unittest) unittest
{
	OrderedMap!(string, int) m;
	static assert(is(typeof(m.keys)));
	static assert(is(typeof(m.values)));
}

debug(ae_unittest) unittest
{
	OrderedMap!(string, int) m;
	foreach (k, v; m)
		k = k ~ k;
}

debug(ae_unittest) unittest
{
	struct S { @disable this(); }
	const OrderedMap!(string, S) m;
}

debug(ae_unittest) unittest
{
	class C {}
	OrderedMap!(string, C) m;
	m.get(null, new C);
}

/// Like assocArray
auto orderedMap(R)(R input)
if (is(typeof(input.front.length) : size_t) && input.front.length == 2)
{
	alias K = typeof(input.front[0]);
	alias V = typeof(input.front[1]);
	return OrderedMap!(K, V)(input);
}

auto orderedMap(R)(R input)
if (is(typeof(input.front.key)) && is(typeof(input.front.value)) && !is(typeof(input.front.length)))
{
	alias K = typeof(input.front.key);
	alias V = typeof(input.front.value);
	return OrderedMap!(K, V)(input);
} /// ditto

debug(ae_unittest) unittest
{
	auto map = 3.iota.map!(n => tuple(n, n + 1)).orderedMap;
	assert(map.length == 3 && map[1] == 2);
}

debug(ae_unittest) unittest
{
	OrderedMap!(string, int) m;
	m = m.byKeyValue.orderedMap;
	m = m.byPair.orderedMap;
}

debug(ae_unittest) unittest
{
	OrderedMap!(string, int) m;
	const(char)[] s;
	m.get(s, 0);
}

debug(ae_unittest) unittest
{
	OrderedMap!(string, OrderedMap!(string, string[][])) m;

	m.require("");
}

debug(ae_unittest) unittest
{
	struct Q { void* p; }
	struct S { OrderedMap!(string, Q) m; }
	OrderedMap!(string, S) objects;

	objects[""] = S();
}

// ***************************************************************************

/// Helper/wrapper for void[0][T]
alias HashSet(T) = HashCollection!(T, void, false, false);

debug(ae_unittest) unittest
{
	HashSet!int s;
	assert(!s);
	assert(s.length == 0);
	assert(!(1 in s));
	assert(1 !in s);
	s.add(1);
	assert(1 in s);
	assert(s.length == 1);
	foreach (k; s)
		assert(k == 1);
	foreach (ref k; s.byRef)
		assert(k == 1);
	s.remove(1);
	assert(s.length == 0);

	s.add(1);
	auto t = s.dup;
	s.add(2);
	assert(t.length==1);
	t.remove(1);
	assert(t.length==0);

	assert( t.addNew(5));
	assert(!t.addNew(5));
	assert(5 in t);
	assert( t.remove(5));
	assert(!t.remove(5));
}

debug(ae_unittest) unittest
{
	struct S { int[int] aa; }
	HashSet!S set;
	S s;
	set.add(s);
	assert(s in set);
}

/// Construct a set from the range `r`.
auto toSet(R)(R r)
{
	alias E = ElementType!R;
	return HashSet!E(r);
}

debug(ae_unittest) unittest
{
	auto set = [1, 2, 3].toSet();
	assert(2 in set);
	assert(4 !in set);
}

debug(ae_unittest) unittest
{
	HashSet!int m;
	const int i;
	m.remove(i);
}

debug(ae_unittest) unittest
{
	HashSet!Object m;
	Object o;
	m.remove(o);
}

debug(ae_unittest) unittest
{
	struct S
	{
		@disable this(this);
	}

	HashSet!S set;
}

// ***************************************************************************

/// An ordered set of `T`, which retains
/// the order in which elements are added.
alias OrderedSet(T) = HashCollection!(T, void, true, false);

debug(ae_unittest) unittest
{
	OrderedSet!int set;

	assert(1 !in set);
	set.add(1);
	assert(1 in set);
	set.remove(1);
	assert(1 !in set);

	set.add(1);
	set.clear();
	assert(1 !in set);

	set = set.init;
	assert(!set);
	set.add(1);
	assert(!!set);

	assert(set[0] == 1);
	set[0] = 2;
	assert(set[0] == 2);
	assert(1 !in set);
	assert(2 in set);

	assert(set.length == 1);
	set.remove(2);
	assert(set.length == 0);

	set.add(1);
	auto set2 = set;
	set.remove(1);
	set.add(2);
	assert(1 !in set && 2 in set);
	assert(1 in set2 && 2 !in set2);

	foreach (v; set)
		assert(v == 2);

	assert(set.length == 1);
	auto index1 = set.requireIndex(1);
	assert(set[index1] == 1);
	assert(set.length == 2);
	auto index2 = set.requireIndex(2);
	assert(set[index2] == 2);
	assert(set.length == 2);

	assert(set[set.indexOf(2)] == 2);

	void f(ref const OrderedSet!int set)
	{
		const size_t i = 0;
		assert(set[i] == 2);
	}

	assert(set.atIndex(set.indexOf(2)) == 2);
	assert(set.getAtIndex(set.indexOf(2), 99) == 2);
	assert(set.getAtIndex(99, 99) == 99);
}

/// Construct an ordered set from the range `r`.
auto orderedSet(R)(R r)
{
	alias E = ElementType!R;
	return OrderedSet!E(r);
}

// ***************************************************************************

/// An object which acts mostly as an associative array,
/// with the added property of being able to hold keys with
/// multiple values. These are only exposed explicitly and
/// through iteration
alias MultiAA(K, V) = HashCollection!(K, V, false, true);

debug(ae_unittest) unittest
{
	alias MASS = MultiAA!(string, int);
	MASS aa;
	aa.add("foo", 42);
	assert(aa["foo"] == 42);
	assert(aa.valuesOf("foo") == [42]);
	assert(aa.byPair.front.key == "foo");

	auto aa2 = MASS([tuple("foo", 42)]);
	aa2 = ["a":1,"b":2];

	const int i;
	aa["a"] = i;
}

debug(ae_unittest) unittest
{
	MultiAA!(int, int) m;
	int[][int] a;
	m = a;
}

// ***************************************************************************

/// Given an AA literal, construct an AA-like object which can be built
/// at compile-time and queried at run-time.
/// The AA literal is unrolled into code.
auto staticAA(alias aa)()
{
	alias K = typeof(aa.keys[0]);
	alias V = typeof(aa.values[0]);
	ref auto value(alias v)() // Work around "... is already defined in another scope in ..."
	{
		static immutable iv = v;
		return iv;
	}
	struct StaticMap
	{
		static immutable K[] keys = aa.keys;
		static immutable V[] values = aa.values;

		ref immutable(V) opIndex(K key) const
		{
			final switch (key)
			{
				static foreach (i, aaKey; aa.keys)
				{
					case aaKey:
						return value!(aa.values[i]);
				}
			}
		}

		bool opBinaryRight(string op : "in")(K key) inout
		{
			switch (key)
			{
				static foreach (aaKey; aa.keys)
				{
					case aaKey:
						return true;
				}
				default:
					return false;
			}
		}

		int opApply(scope int delegate(ref immutable K, ref immutable V) dg) const
		{
			static foreach (i, aaKey; aa.keys)
			{{
				int ret = dg(value!aaKey, value!(aa.values[i]));
				if (ret)
					return ret;
			}}
			return 0;
		}
	}
	return StaticMap();
}

debug(ae_unittest) unittest
{
	static immutable aa = staticAA!([
		"foo" : 1,
		"bar" : 2,
	]);

	assert(aa["foo"] == 1);

	assert("foo" in aa);
	assert("baz" !in aa);

	assert(aa.keys == ["foo", "bar"]);
	assert(aa.values == [1, 2]);

	foreach (key, value; aa)
		assert((key == "foo" && value == 1) || (key == "bar" && value == 2));
}
