/**
 * Var-like helper for visitor.
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

module ae.utils.mapset.vars;

static if (__VERSION__ >= 2083):

import core.lifetime;

import std.meta;
import std.traits;

import ae.utils.mapset.mapset;
import ae.utils.mapset.visitor;

/// A wrapper around a MapSetVisitor which allows interacting with it
/// using a more conventional interface.
struct MapSetVars(
	/// `MapSet` `DimName` parameter.
	/// Must also provide `tempVarStart` and `tempVarEnd`
	/// static fields for temporary variable allocation.
	VarName_,
	/// `MapSet` `DimValue` parameter.
	Value_,
	/// `MapSet` `nullValue` parameter.
	Value_ nullValue = Value_.init,
)
{
	@disable this(this); // Do not copy!

	alias VarName = VarName_;
	alias Value = Value_;

	alias Set = MapSet!(VarName, Value, nullValue);
	alias Visitor = MapSetVisitor!(VarName, Value, nullValue);

	Visitor visitor;
	VarName varCounter;

	private VarName allocateName()
	{
		assert(varCounter < VarName.tempVarEnd, "Too many temporary variables");
		return varCounter++;
	}

	private void deallocate(VarName name)
	{
		// best-effort de-bump-the-pointer
		auto next = name; next++;
		if (next > name && next == varCounter)
			varCounter = name;
	}

	bool next()
	{
		varCounter = VarName.tempVarStart;
		return visitor.next();
	}

	Var get(VarName name)
	{
		return Var(&this, name);
	}

	alias opIndex = get;

	private struct Dispatcher
	{
		private MapSetVars* vars;

		Var opDispatch(string name)()
		if (__traits(hasMember, VarName, name))
		{
			return vars.get(__traits(getMember, VarName, name));
		}

		Var opDispatch(string name, V)(auto ref V v)
		if (__traits(hasMember, VarName, name) && is(typeof(vars.get(VarName.init) = v)))
		{
			return vars.get(__traits(getMember, VarName, name)) = v;
		}
	}

	@property Dispatcher var() { return Dispatcher(&this); }

	Var allocate(Value value = nullValue)
	{
		return Var(&this, allocateName(), value);
	}

	Var inject(Value[] values)
	{
		auto var = Var(&this, allocateName());
		visitor.inject(var.name, values);
		return var;
	}

	private Var eval(size_t n)(Repeat!(n, Var) vars, scope Value delegate(Repeat!(n, Value) values) fun)
	{
		foreach (ref var; vars)
			assert(var.vars is &this, "Cross-domain operation");
		VarName[n] inputs;
		foreach (i, ref var; vars)
			inputs[i] = var.name;
		auto result = allocate();
		visitor.multiTransform(inputs, [result.name],
			(scope Value[] inputValues, scope Value[] outputValues)
			{
				Repeat!(n, Value) values;
				static foreach (i; 0 .. n)
					values[i] = inputValues[i];
				outputValues[0] = fun(values);
			}
		);
		return result;
	}

	struct Var
	{
		// --- Lifetime

		MapSetVars* vars;
		VarName name;

		private this(MapSetVars* vars, VarName name, Value value = nullValue)
		{
			this.vars = vars;
			this.name = name;
			if (value != nullValue)
				this = value;
		}

		this(this)
		{
			auto newName = vars.allocateName();
			vars.visitor.copy(this.name, newName);
			this.name = newName;
		}

		~this()
		{
			// Must not be in GC!
			if (vars && name >= VarName.tempVarStart && name < VarName.tempVarEnd)
			{
				vars.visitor.put(name, nullValue);
				vars.deallocate(name);
			}
		}

		// --- Transformation operations

		private enum bool unaryIsInjective(string op) = op == "+" || op == "-" || op == "~";
		private enum bool binaryIsInjective(string op) = op == "+" || op == "-" || op == "^" || op == "~";

		Var opUnary(string op)()
		if (is(typeof(mixin(op ~ ` Value.init`)) : Value))
		{
			auto result = allocate();
			visitor.targetTransform!(unaryIsInjective!op)(this.name, result.name,
				(ref const Value inputValue, out Value outputValue)
				{
					mixin(`outputValue = ` ~ op ~ ` inputValue;`);
				}
			);
			return result;
		}

		template opBinary(string op)
		if (is(typeof(mixin(`Value.init ` ~ op ~ ` Value.init`)) : Value))
		{
			Var opBinary(Var other)
			{
				assert(vars is other.vars, "Cross-domain operation");
				auto result = vars.allocate();
				vars.visitor.multiTransform([this.name, other.name], [result.name],
					(scope Value[] inputValues, scope Value[] outputValues)
					{
						mixin(`outputValues[0] = inputValues[0] ` ~ op ~ ` inputValues[1];`);
					}
				);
				return result;
			}

			Var opBinary(Value other)
			{
				auto result = vars.allocate();
				vars.visitor.targetTransform!(binaryIsInjective!op)(this.name, result.name,
					(ref const Value inputValue, out Value outputValue)
					{
						mixin(`outputValue = inputValue ` ~ op ~ ` other;`);
					}
				);
				return result;
			}
		}

		Var opBinaryRight(string op)(Value other)
		if (is(typeof(mixin(`Value.init ` ~ op ~ ` Value.init`)) : Value))
		{
			auto result = vars.allocate();
			vars.visitor.targetTransform!(binaryIsInjective!op)(this.name, result.name,
				(ref const Value inputValue, out Value outputValue)
				{
					mixin(`outputValue = other ` ~ op ~ ` inputValue;`);
				}
			);
			return result;
		}

		void opOpAssign(string op)(Value other)
		if (is(typeof(mixin(`{ Value v; v ` ~ op ~ `= Value.init; }`))))
		{
			static if (binaryIsInjective!op)
				vars.visitor.injectiveTransform(name, (ref Value value) { mixin(`value ` ~ op ~ `= other;`); });
			else
				vars.visitor.         transform(name, (ref Value value) { mixin(`value ` ~ op ~ `= other;`); });
		}

		alias opEquals = opBinary!"==";

		static if (Value.min < 0)
		{
			static struct CompareResult
			{
				Var var;
				alias var this;
			}

			CompareResult /*opCmp*/cmp(Var other)
			{
				auto result = vars.allocate();
				vars.visitor.multiTransform([this.name, other.name], [result.name],
					(scope Value[] inputValues, scope Value[] outputValues)
					{
						outputValues[0] =
							inputValues[0] < inputValues[1] ? -1 :
							inputValues[0] > inputValues[1] ? +1 :
							0;
					}
				);
				return CompareResult(result);
			}

			CompareResult /*opCmp*/cmp(Value other)
			{
				auto result = vars.allocate();
				vars.visitor.multiTransform([this.name], [result.name],
					(scope Value[] inputValues, scope Value[] outputValues)
					{
						outputValues[0] =
							inputValues[0] < other ? -1 :
							inputValues[0] > other ? +1 :
							0;
					}
				);
				return CompareResult(result);
			}
		}

		// D does not allow overloading comparison operators :( :( :( :( :(
		alias lt = opBinary!"<";
		alias gt = opBinary!">";
		alias le = opBinary!"<=";
		alias ge = opBinary!">=";
		alias eq = opBinary!"==";
		alias ne = opBinary!"!=";

		// Can't overload ! either
		Var not() { return map(d => !d); }

		/// Ternary.
		Var choose(Value ifTrue, Value ifFalse)
		{
			return map(d => d ? ifTrue : ifFalse);
		}

		// --- Fundamental operations

		Var opAssign(Var value)
		{
			if (!vars)
			{
				// Auto-allocate if uninitialized.
				// Note, we can't do the same thing for the Value opAssign.
				vars = value.vars;
				name = vars.allocateName();
			}

			vars.visitor.copy(value.name, this.name);
			return this;
		}

		Var opAssign(Value value)
		{
			vars.visitor.put(this.name, value);
			return this;
		}

		Value resolve()
		{
			return vars.visitor.get(this.name);
		}

		// Transform and copy one variable.
		Var map(scope Value delegate(Value) fun)
		{
			auto result = vars.allocate();
			vars.visitor.targetTransform(this.name, result.name,
				(ref const Value inputValue, out Value outputValue)
				{
					outputValue = fun(inputValue);
				}
			);
			return result;
		}
	}
}

/// An example.
/// Note that, unlike the similar Visitor test case, this iterates only once,
/// thanks to the opBinary support.
debug(ae_unittest) unittest
{
	// Setup

	enum VarName : uint { x, y, z, tempVarStart = 100, tempVarEnd = 200 }
	MapSetVars!(VarName, int) v;
	alias M = MapSetVars!(VarName, int).Set;
	M m = v.Set.unitSet;
	m = m.cartesianProduct(VarName.x, [1, 2, 3]);
	m = m.cartesianProduct(VarName.y, [10, 20, 30]);
    v.visitor = v.Visitor(m);

	// The algorithm that runs on the mapset

	void theAlgorithm()
	{
		v.var.z = v.var.x + v.var.y;
	}

	// The evaluation loop

	M results;
	size_t numIterations;
	while (v.next())
	{
		theAlgorithm();

		results = results.merge(v.visitor.currentSubset);
		numIterations++;
	}

	assert(numIterations == 1);
	assert(results.all(VarName.z) == [11, 12, 13, 21, 22, 23, 31, 32, 33]);
}

debug(ae_unittest) unittest
{
	enum VarName : uint { tempVarStart = 100, tempVarEnd = 200 }
	MapSetVars!(VarName, int) v;
    v.visitor = v.Visitor(v.Set.unitSet);
    v.next();

    auto a = v.allocate();
    a = 5;
    auto b = a;
    a = 6;
    assert(b.resolve == 5);
}

debug(ae_unittest) unittest
{
	enum VarName : uint { tempVarStart = 100, tempVarEnd = 200 }
	MapSetVars!(VarName, int) v;
    v.visitor = v.Visitor(v.Set.unitSet);
    v.next();

    auto a = v.get(cast(VarName)0);

    v.get(a.name) = 5;
    assert(a.resolve == 5);

    v.get(a.name) = v.allocate(7);
    assert(a.resolve == 7);
}

debug(ae_unittest) unittest
{
	enum VarName : uint { tempVarStart = 100, tempVarEnd = 200 }
	MapSetVars!(VarName, int) v;
    v.visitor = v.Visitor(v.Set.unitSet);
    v.next();

    auto a = v.get(cast(VarName)0);
    v.Var b;
    b = a;
}

/// Array indexing
Var at(T)(T[] array, Var index)
if (is(T : Value))
{
    return index.map(value => array[value]);
}

debug(ae_unittest) unittest
{
	enum VarName : uint { tempVarStart = 100, tempVarEnd = 200 }
	MapSetVars!(VarName, int) v;
    v.visitor = v.Visitor(v.Set.unitSet);
    v.next();

    auto a = v.get(cast(VarName)0);
    v.Var b;
    b = a;
}

template varCall(alias fun)
// if (valueLike!(ReturnType!fun) && allSatisfy!(valueLike, Parameters!fun))
{
	template isValidVarArgs(VarArgs...)
	{
		alias Vars = __traits(parent, VarArgs[0]);
		enum isVar(VarArg) = is(VarArg == Vars.Var);
		enum isValidVarArgs = allSatisfy!(isVar, VarArgs);
	}

    // Var varCall(Repeat!(Parameters!fun.length, Var) vars)
    VarArgs[0] varCall(VarArgs...)(VarArgs varArgs)
	if (isValidVarArgs!VarArgs)
    {
		alias Vars = __traits(parent, VarArgs[0]);
		alias Var = Vars.Var;
		auto vars = varArgs[0].vars;
        return vars.eval!(Parameters!fun.length)(varArgs,
            (Repeat!(Parameters!fun.length, Vars.Value) values)
            {
                Parameters!fun params;
                foreach (i, ref param; params)
                    param = cast(typeof(param)) values[i]; // Value -> Integer
                return cast(Vars.Value)fun(params);
            });
    }
}

debug(ae_unittest) unittest
{
    static int fun(int i) { return i + 1; }

	enum VarName : uint { tempVarStart = 100, tempVarEnd = 200 }
	MapSetVars!(VarName, int) v;
    v.visitor = v.Visitor(v.Set.unitSet);
    v.next();

    auto a = v.allocate();
    a = 5;
    auto b = varCall!fun(a);
    assert(b.resolve == 6);
}
