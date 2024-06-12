/**
 * MapSet visitor type.
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

module ae.utils.mapset.visitor;

static if (__VERSION__ >= 2083):

import ae.utils.mapset.mapset;

import std.algorithm.iteration;
import std.algorithm.searching;
import std.algorithm.sorting;
import std.array;
import std.exception;
import std.typecons : tuple;

import ae.utils.aa;
import ae.utils.array : amap;

/// Allows executing a deterministic algorithm over all states in a given MapSet.
/// If a variable is not queried by the algorithm, states for all
/// variations of that variable are processed in one iteration.
struct MapSetVisitor(A, V, V nullValue = V.init)
{
	/// Underlying `MapSet`.
	alias Set = MapSet!(A, V, nullValue);
	Set set; /// ditto

	/// Internal state.
	/*private*/ public
	{
		// Iteration state for resolved values
		struct Var
		{
			A name; ///
			const(V)[] values; ///
			size_t pos; ///
		}
		Var[] stack;
		size_t stackPos;

		private enum Maybe { no, maybe, yes }

		struct VarState
		{
			// Variable holds this one value if `haveValue` is true.
			V value = nullValue;

			// Optimization.
			// For variables which have been resolved, or have been
			// set to some specific value, remember that value here
			// (in the `value` field).
			// Faster than checking workingSet.all(name)[0].
			// If this is set, it has a concrete value because
			// - we are iterating over it (it's in the stack)
			// - due to a `put` call
			// - it was never in the set (so it's implicitly at nullValue).
			bool haveValue = true;

			// Optimization.
			// Accumulate MapSet.set calls, and flush then in bulk.
			// The value to flush is stored in the `value` field.
			// If `dirty` is true, `haveValue` must be true.
			bool dirty;

			// Optimization.
			// Remember whether this variable is in the set or not.
			Maybe inSet = Maybe.no;

			void setInSet(bool inSet)
			{
				if (inSet)
					this.inSet = Maybe.yes;
				else
				{
					this.inSet = Maybe.no;
					assert(!this.dirty, "TODO");
					if (this.haveValue)
						assert(this.value == nullValue);
					else
					{
						this.haveValue = true;
						this.value = nullValue;
					}
				}
			}
		}
		VarState[A] varState, initialVarState;

		// The version of the set for the current iteration.
		private Set workingSet;
	}

	this(Set set)
	{
		this.set = set;
		foreach (dim, values; set.getDimsAndValues())
		{
			auto pstate = &initialVarState.require(dim);
			pstate.inSet = Maybe.yes;
			if (values.length == 1)
				pstate.value = values.byKey.front;
			else
				pstate.haveValue = false;
		}
	} ///

	@disable this(this);

	MapSetVisitor dup()
	{
		MapSetVisitor r;
		r.set = set;
		r.stack = stack.dup;
		r.stackPos = stackPos;
		r.varState = varState.dup;
		r.workingSet = workingSet;
		return r;
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
		varState = initialVarState.dup;
		stackPos = 0;
		return true;
	}

	private void flush()
	{
		auto toRemove = varState.byKeyValue
			.filter!(pair => pair.value.dirty && pair.value.inSet >= Maybe.maybe)
			.map!(pair => pair.key)
			.toSet;
		workingSet = workingSet.remove((A name) => name in toRemove);
		foreach (name, ref state; varState)
			if (state.dirty)
			{
				workingSet = workingSet.addDim(name, state.value);
				state.dirty = false;
				state.setInSet(state.value != nullValue); // addDim is a no-op with nullValue
			}
	}

	private void flush(A name)
	{
		if (auto pstate = name in varState)
			if (pstate.dirty)
			{
				pstate.dirty = false;
				if (pstate.inSet >= Maybe.maybe)
				{
					if (pstate.inSet == Maybe.yes)
					{
						auto oldSet = workingSet;
						auto newSet = workingSet.remove(name);
						assert(oldSet != newSet, "Actually wasn't in the set");
						workingSet = newSet;
					}
					else
						workingSet = workingSet.remove(name);
				}
				workingSet = workingSet.addDim(name, pstate.value);
				pstate.setInSet(pstate.value != nullValue); // addDim is a no-op with nullValue
			}
	}

	/// Peek at the subset the algorithm is currently working with.
	@property Set currentSubset()
	{
		assert(workingSet !is Set.emptySet, "Not iterating");
		flush();
		return workingSet;
	}

	/// Get all possible values for this variable at this point.
	/// Should be used mainly for debugging.
	/*private*/ const(V)[] getAll(A name)
	{
		assert(workingSet !is Set.emptySet, "Not iterating");
		if (auto pstate = name in varState)
			if (pstate.haveValue)
				return (&pstate.value)[0 .. 1];

		return workingSet.all(name);
	}

	/// Algorithm interface - get a value by name
	V get(A name)
	{
		assert(workingSet !is Set.emptySet, "Not iterating");
		auto pstate = &varState.require(name);
		if (pstate.haveValue)
			return pstate.value;

		// We are going to narrow the workingSet - update inSet appropriately
		foreach (varName, ref state; varState)
			if (varName == name)
				state.inSet = Maybe.maybe;
			else
			if (state.inSet == Maybe.yes)
				state.inSet = Maybe.maybe;

		if (stackPos == stack.length)
		{
			// Expand new variable
			auto values = workingSet.all(name);
			auto value = values[0];
			// auto pstate = varState
			pstate.value = value;
			pstate.haveValue = true;
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
		pstate.value = value;
		pstate.haveValue = true;
		stackPos++;
		return value;
	}

	/// Algorithm interface - set a value by name
	void put(A name, V value)
	{
		assert(workingSet !is Set.emptySet, "Not iterating");

		auto pstate = &varState.require(name);

		if (pstate.haveValue && pstate.value == value)
			return; // All OK

		pstate.value = value;
		pstate.haveValue = pstate.dirty = true;

		// Flush null values ASAP, to avoid non-null values
		// accumulating in the set and increasing the set size.
		if (value == nullValue)
			flush(name);
	}

	/// Prepare an unresolved variable for overwriting (with more than
	/// one value).
	private void destroy(A name)
	{
		auto pstate = &varState.require(name);
		pstate.haveValue = pstate.dirty = false;
		if (pstate.inSet >= Maybe.maybe)
		{
			workingSet = workingSet.remove(name);
			pstate.inSet = Maybe.no;
		}
	}

	/// A smarter `workingSet = workingSet.bringToFront(name)`, which
	/// checks if `name` is in the set first.
	private void bringToFront(A name)
	{
		auto pState = &varState.require(name);
		if (pState.inSet == Maybe.no)
			workingSet = Set(new immutable Set.Node(name, [Set.Pair(nullValue, workingSet)])).deduplicate;
		else
			workingSet = workingSet.bringToFront(name);
		pState.inSet = Maybe.yes;
	}

	/// Algorithm interface - copy a value target another name,
	/// without resolving it (unless it's already resolved).
	void copy(bool reorder = false)(A source, A target)
	{
		if (source == target)
			return;

		auto pSourceState = &varState.require(source);
		auto pTargetState = &varState.require(target);
		if (pSourceState.haveValue)
		{
			put(target, pSourceState.value);
			return;
		}

		assert(workingSet !is Set.emptySet, "Not iterating");

		static if (reorder)
		{
			destroy(target);

			bringToFront(source);
			auto newChildren = workingSet.root.children.dup;
			foreach (ref pair; newChildren)
			{
				auto set = Set(new immutable Set.Node(source, [Set.Pair(pair.value, pair.set)])).deduplicate;
				pair = Set.Pair(pair.value, set);
			}
			workingSet = Set(new immutable Set.Node(target, cast(immutable) newChildren)).deduplicate;
			pSourceState.inSet = Maybe.yes;
			pTargetState.inSet = Maybe.yes;
		}
		else
		{
			targetTransform!true(source, target,
				(ref const V inputValue, out V outputValue)
				{
					outputValue = inputValue;
				}
			);
		}
	}

	/// Apply a function over every possible value of the given
	/// variable, without resolving it (unless it's already resolved).
	void transform(A name, scope void delegate(ref V value) fun)
	{
		assert(workingSet !is Set.emptySet, "Not iterating");
		auto pState = &varState.require(name);
		if (pState.haveValue)
		{
			pState.dirty = true;
			fun(pState.value);
			return;
		}

		bringToFront(name);
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
		pState.inSet = Maybe.yes;
	}

	/// Apply a function over every possible value of the given
	/// variable, without resolving it (unless it's already resolved).
	/// The function is assumed to be injective (does not produce
	/// duplicate outputs for distinct inputs).
	void injectiveTransform(A name, scope void delegate(ref V value) fun)
	{
		assert(workingSet !is Set.emptySet, "Not iterating");
		auto pState = &varState.require(name);
		if (pState.haveValue)
		{
			pState.dirty = true;
			fun(pState.value);
			return;
		}

		bringToFront(name);
		auto newChildren = workingSet.root.children.dup;
		foreach (ref child; newChildren)
			fun(child.value);
		newChildren.sort();
		workingSet = Set(new immutable Set.Node(name, cast(immutable) newChildren)).deduplicate;
		pState.inSet = Maybe.yes;
	}

	/// Perform a transformation with one input and one output.
	/// Does not reorder the MapSet.
	void targetTransform(bool injective = false)(A input, A output, scope void delegate(ref const V inputValue, out V outputValue) fun)
	{
		assert(input != output, "Input is the same as output - use transform instead");

		flush(input);
		destroy(output);

		auto pInputState = &varState.require(input);
		auto pOutputState = &varState.require(output);

		if (pInputState.haveValue)
		{
			V outputValue;
			fun(pInputState.value, outputValue);
			put(output, outputValue);
			return;
		}

		bool sawInput, addedOutput;
		Set[Set] cache;
		Set visit(Set set)
		{
			return cache.require(set, {
				if (set == Set.unitSet)
				{
					V inputValue = nullValue;
					V outputValue;
					fun(inputValue, outputValue);
					if (outputValue != nullValue)
						addedOutput = true;
					return set.addDim(output, outputValue);
				}
				if (set.root.dim == input)
				{
					sawInput = true;
					static if (injective)
					{
						auto outputChildren = new Set.Pair[set.root.children.length];
						foreach (i, ref outputPair; outputChildren)
						{
							auto inputPair = &set.root.children[i];
							fun(inputPair.value, outputPair.value);
							outputPair.set = Set(new immutable Set.Node(input, inputPair[0..1])).deduplicate;
						}
						outputChildren.sort();
						addedOutput = true;
						return Set(new immutable Set.Node(output, cast(immutable) outputChildren)).deduplicate;
					}
					else
					{
						auto inputChildren = set.root.children;
						set = Set.emptySet;
						foreach (i, ref inputPair; inputChildren)
						{
							V outputValue;
							fun(inputPair.value, outputValue);
							auto inputSet = Set(new immutable Set.Node(input, (&inputPair)[0..1])).deduplicate;
							auto outputSet = inputSet.addDim(output, outputValue);
							set = set.merge(outputSet);
							if (outputValue != nullValue)
								addedOutput = true;
						}
						return set;
					}
				}
				else
					return set.lazyMap(&visit);
			}());
		}
		workingSet = visit(workingSet);
		pInputState.setInSet(sawInput);
		pOutputState.setInSet(addedOutput);
	}

	/// Perform a transformation with multiple inputs and outputs.
	/// Inputs and outputs must not overlap.
	/// Can be used to perform binary operations, copy-transforms, and more.
	void multiTransform(scope A[] inputs, scope A[] outputs, scope void delegate(scope V[] inputValues, scope V[] outputValues) fun)
	{
		assert(inputs.length > 0 && outputs.length > 0, "");
		foreach (output; outputs)
			assert(!inputs.canFind(output), "Inputs and outputs overlap");

		foreach (input; inputs)
			flush(input);
		foreach (output; outputs)
			destroy(output);
		foreach_reverse (input; inputs)
			bringToFront(input);

		Set resultSet = Set.emptySet;
		auto inputValues = new V[inputs.length];
		auto outputValues = new V[outputs.length];
		auto addedInput = new bool[inputs.length];
		auto addedOutput = new bool[outputs.length];

		void visit(Set set, size_t depth)
		{
			if (depth == inputs.length)
			{
				fun(inputValues, outputValues);
				foreach_reverse (i, input; inputs)
				{
					set = set.addDim(input, inputValues[i]);
					if (inputValues[i] != nullValue)
						addedInput[i] = true;
				}
				foreach_reverse (i, output; outputs)
				{
					set = set.addDim(output, outputValues[i]);
					if (outputValues[i] != nullValue)
						addedOutput[i] = true;
				}
				resultSet = resultSet.merge(set);
			}
			else
			{
				assert(set.root.dim == inputs[depth]);
				foreach (ref pair; set.root.children)
				{
					inputValues[depth] = pair.value;
					visit(pair.set, depth + 1);
				}
			}
		}
		visit(workingSet, 0);
		workingSet = resultSet;
		foreach (i, input; inputs)
			varState.require(input).setInSet(addedInput[i]);
		foreach (i, output; outputs)
			varState.require(output).setInSet(addedOutput[i]);
	}

	/// Inject a variable and values to iterate over.
	/// The variable must not have been resolved yet.
	void inject(A name, V[] values)
	{
		assert(values.length > 0, "Injecting zero values would result in an empty set");
		destroy(name);
		workingSet = workingSet.uncheckedCartesianProduct(name, values);
		varState.require(name).inSet = Maybe.yes;
	}
}

/// An algorithm which divides two numbers.
/// When the divisor is zero, we don't even query the dividend,
/// therefore processing all dividends in one iteration.
debug(ae_unittest) unittest
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

debug(ae_unittest) unittest
{
	import std.algorithm.sorting : sort;

	alias M = MapSet!(string, int);
	M m = M.unitSet.cartesianProduct("x", [1, 2, 3]);
	auto v = MapSetVisitor!(string, int)(m);
	v.next();
	v.transform("x", (ref int v) { v *= 2; });
	assert(v.currentSubset.all("x").dup.sort.release == [2, 4, 6]);
}

debug(ae_unittest) unittest
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

// Test that initialVarState does not interfere with flushing
debug(ae_unittest) unittest
{
	alias M = MapSet!(string, int);
	M m = M.unitSet.cartesianProduct("x", [1]);
	auto v = MapSetVisitor!(string, int)(m);
	assert(v.initialVarState["x"].haveValue);
	v.next();
	v.put("x", 2);
	v.currentSubset;
	assert(v.get("x") == 2);
}

// Test resolving the same variable several times
debug(ae_unittest) unittest
{
	alias M = MapSet!(string, int);
	M m = M.unitSet.cartesianProduct("x", [10, 20, 30]);
	auto v = MapSetVisitor!(string, int)(m);
	int[] result;
	while (v.next())
	{
		auto a = v.get("x"); // First resolve
		v.inject("x", [1, 2, 3]);
		auto b = v.get("x"); // Second resolve
		result ~= a + b;
	}
	assert(result == [11, 12, 13, 21, 22, 23, 31, 32, 33]);
}

// Same, with `copy`.
debug(ae_unittest) unittest
{
	alias M = MapSet!(string, int);
	M m = M.unitSet;
	m = m.cartesianProduct("x", [10, 20, 30]);
	m = m.cartesianProduct("y", [ 1,  2,  3]);
	auto v = MapSetVisitor!(string, int)(m);
	int[] result;
	while (v.next())
	{
		v.copy("x", "tmp");
		auto x = v.get("tmp"); // First resolve
		v.copy("y", "tmp");
		auto y = v.get("tmp"); // Second resolve
		result ~= x + y;
	}
	result.sort();
	assert(result == [11, 12, 13, 21, 22, 23, 31, 32, 33]);
}

// targetTransform
debug(ae_unittest) unittest
{
	import std.algorithm.sorting : sort;

	alias M = MapSet!(string, int);
	M m = M.unitSet.cartesianProduct("x", [1, 2, 3, 4, 5]);
	auto v = MapSetVisitor!(string, int)(m);
	v.next();
	v.targetTransform("x", "y", (ref const int input, out int output) { output = input + 1; });
	assert(v.currentSubset.all("y").dup.sort.release == [2, 3, 4, 5, 6]);
	assert(!v.next());
}

// multiTransform
debug(ae_unittest) unittest
{
	alias M = MapSet!(string, int);
	M m = M.unitSet.cartesianProduct("x", [1, 2, 3, 4, 5]);
	auto v = MapSetVisitor!(string, int)(m);
	v.next();
	v.copy("x", "y");
	v.transform("y", (ref int v) { v = 6 - v; });
	v.multiTransform(["x", "y"], ["z"], (int[] inputs, int[] outputs) { outputs[0] = inputs[0] + inputs[1]; });
	assert(v.currentSubset.all("z") == [6]);
	assert(!v.next());
}
