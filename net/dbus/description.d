/**
 * Compile-time descriptions of D-Bus interfaces declared as D interfaces.
 *
 * A D-Bus interface is declared once, as a D `interface` annotated with
 * `@DbusInterface`. Its methods return `Promise`s, and its signals are
 * `DbusSignal` aliases. This module validates such declarations and
 * reflects them in two forms:
 *
 * - `DbusMethodInfos!I` and `DbusSignalInfos!I`: package-level alias lists,
 *   used to generate code (proxies, exporters).
 * - `dbusInterfaceDescription!I`: a plain-data value, built from those same
 *   lists at compile time. It is used for introspection and by the object
 *   registry, which also accepts descriptions built at run time.
 *
 * Because every consumer goes through these lists, a proxy, an exported
 * object and the introspection data derived from the same `I` cannot
 * disagree about wire names or signatures.
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

module ae.net.dbus.description;

import std.meta : AliasSeq, staticMap;
import std.traits : BaseTypeTuple, FunctionAttribute, ParameterDefaults,
	ParameterIdentifierTuple, ParameterStorageClass, ParameterStorageClassTuple,
	ParameterTypeTuple, ReturnType, Unqual, Variadic, functionAttributes,
	variadicFunctionStyle;

import ae.net.dbus.common : DbusInterfaceName, DbusMemberName, DbusSignature;
import ae.net.dbus.signature : DbusOut, dbusSignature;
import ae.utils.meta : getAttribute, hasAttribute;
import ae.utils.promise : PromiseError, PromiseValue, isPromise;

/// Names the D-Bus interface described by a D interface.
struct DbusInterface
{
	string name;
}

/// Overrides the D-Bus member name of a method, when it must differ from
/// the D method name (for example, to disambiguate D overloads).
struct DbusMember
{
	string name;
}

/// Describes a D-Bus signal as metadata on an interface, rather than as a
/// callable method.
struct DbusSignal(string memberName, Args...)
{
	enum name = memberName;
	alias Types = Args;
}

/// One argument of a method or signal.
struct DbusArgumentDescription
{
	/// The argument name, or empty if the argument is unnamed.
	string name;
	/// The single complete type of the argument.
	DbusSignature type;
}

/// A method: its member name and its input and output arguments.
struct DbusMethodDescription
{
	DbusMemberName name;
	DbusArgumentDescription[] inArgs;
	DbusArgumentDescription[] outArgs;
}

/// A signal: its member name and its arguments.
struct DbusSignalDescription
{
	DbusMemberName name;
	DbusArgumentDescription[] args;
}

/// The members of one D-Bus interface, in declaration order.
struct DbusInterfaceDescription
{
	DbusInterfaceName name;
	DbusMethodDescription[] methods;
	DbusSignalDescription[] signals;
}

/// The description of the D-Bus interface declared by the D interface `I`.
/// Evaluated at compile time; invalid declarations fail to compile.
enum DbusInterfaceDescription dbusInterfaceDescription(I) = describeDbusInterface!I();

/// The body signature formed by a sequence of arguments.
package(ae.net.dbus) DbusSignature dbusArgumentsSignature(scope const(DbusArgumentDescription)[] args)
{
	string text;
	foreach (arg; args)
		text ~= arg.type.text;
	return DbusSignature.parse(text);
}

/// Argument names used in introspection must be empty or ASCII C identifiers.
package(ae.net.dbus) bool isDbusArgumentName(string name)
{
	foreach (index, char c; name)
		if (!(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c == '_' ||
				index > 0 && c >= '0' && c <= '9'))
			return false;
	return true;
}

/// The body signature formed by values of the given D types.
package(ae.net.dbus) template dbusTypesSignature(Types...)
{
	enum dbusTypesSignature = () {
		string result;
		static foreach (Type; Types)
			result ~= dbusSignature!Type;
		return result;
	}();
}

/// The D-Bus interface name declared on `I` with `@DbusInterface`.
package(ae.net.dbus) template dbusInterfaceName(I)
{
	static assert(hasAttribute!(DbusInterface, I),
		"D-Bus interfaces must be annotated with @DbusInterface");
	static assert(dbusAttributeCount!(DbusInterface, I) == 1,
		"D-Bus interfaces must have exactly one @DbusInterface annotation");
	enum dbusInterfaceName = getAttribute!(DbusInterface, I).name;
}

/// Reflection of one D-Bus method: overload `overloadIndex` of the
/// member `ident` of `I`.
package(ae.net.dbus) template DbusMethodInfo(I, string ident, size_t overloadIndex)
{
	alias Method = __traits(getOverloads, I, ident)[overloadIndex];
	private enum validated = dbusValidateFunction!(Method, ident)();

	enum identifier = ident;
	alias Params = ParameterTypeTuple!Method;
	enum string[] paramNames = [ParameterIdentifierTuple!Method];
	static foreach (name; paramNames)
		static assert(isDbusArgumentName(name),
			"D-Bus argument names must be empty or ASCII C identifiers");
	alias Result = PromiseValue!(ReturnType!Method);
	static if (is(Result == DbusOut!Types, Types...))
		alias ResultTypes = Result.Types;
	else static if (is(Result == void))
		alias ResultTypes = AliasSeq!();
	else
		alias ResultTypes = AliasSeq!Result;
	enum wireName = dbusMemberWireName!Method;

	static foreach (Type; ResultTypes)
		static assert(__traits(compiles, dbusSignature!Type),
			"D-Bus interface method " ~ ident ~ " has a result type with no D-Bus signature");
}

/// Reflection of one D-Bus signal: the `DbusSignal` alias `ident` of `I`.
package(ae.net.dbus) template DbusSignalInfo(I, string ident)
{
	alias Signal = __traits(getMember, I, ident);
	enum identifier = ident;
	alias Types = Signal.Types;
	enum wireName = Signal.name;

	static foreach (Type; Types)
		static assert(__traits(compiles, dbusSignature!Type),
			"D-Bus signal " ~ ident ~ " has an argument type with no D-Bus signature");
}

/// The methods of `I`, as `DbusMethodInfo` instances, in member and
/// overload declaration order. Index `i` describes
/// `dbusInterfaceDescription!I.methods[i]`.
package(ae.net.dbus) template DbusMethodInfos(I)
{
	private enum validated = dbusValidateInterface!I();
	alias DbusMethodInfos = dbusCollectMethods!I;
}

/// The signals of `I`, as `DbusSignalInfo` instances, in declaration order.
/// Index `i` describes `dbusInterfaceDescription!I.signals[i]`.
package(ae.net.dbus) template DbusSignalInfos(I)
{
	private enum validated = dbusValidateInterface!I();
	alias DbusSignalInfos = dbusCollectSignals!I;
}

private:

template dbusAttributeCount(T, alias D)
{
	enum dbusAttributeCount = () {
		size_t count;
		static foreach (attribute; __traits(getAttributes, D))
			static if (is(typeof(attribute) == T))
				count++;
		return count;
	}();
}

template dbusMemberWireName(alias Method)
{
	static if (hasAttribute!(DbusMember, Method))
		enum dbusMemberWireName = getAttribute!(DbusMember, Method).name;
	else
		enum dbusMemberWireName = __traits(identifier, Method);
}

template dbusIsFunctionMember(I, string ident)
{
	enum dbusIsFunctionMember = __traits(getOverloads, I, ident).length > 0;
}

template dbusIsSignalMember(I, string ident)
{
	static if (__traits(getOverloads, I, ident).length)
		enum dbusIsSignalMember = false;
	else static if (is(__traits(getMember, I, ident) == DbusSignal!(N, A), string N, A...))
		enum dbusIsSignalMember = true;
	else
		enum dbusIsSignalMember = false;
}

template dbusIsTemplateMember(I, string ident)
{
	static if (__traits(compiles, __traits(isTemplate, __traits(getMember, I, ident))))
		enum dbusIsTemplateMember = __traits(isTemplate, __traits(getMember, I, ident));
	else
		enum dbusIsTemplateMember = false;
}

template dbusMethodOverloadInfos(I, string ident, size_t index, size_t count)
{
	static if (index == count)
		alias dbusMethodOverloadInfos = AliasSeq!();
	else
		alias dbusMethodOverloadInfos = AliasSeq!(DbusMethodInfo!(I, ident, index),
			dbusMethodOverloadInfos!(I, ident, index + 1, count));
}

template dbusCollectMethods(I)
{
	template of(string ident)
	{
		static if (dbusIsFunctionMember!(I, ident))
			alias of = dbusMethodOverloadInfos!(I, ident, 0,
				__traits(getOverloads, I, ident).length);
		else
			alias of = AliasSeq!();
	}
	alias dbusCollectMethods = staticMap!(of, __traits(allMembers, I));
}

template dbusCollectSignals(I)
{
	template of(string ident)
	{
		static if (dbusIsSignalMember!(I, ident))
			alias of = AliasSeq!(DbusSignalInfo!(I, ident));
		else
			alias of = AliasSeq!();
	}
	alias dbusCollectSignals = staticMap!(of, __traits(allMembers, I));
}

/// Checks the shape of one interface function. A function, so that callers
/// can force the checks (via CTFE) before reflecting on the signature.
bool dbusValidateFunction(alias Method, string ident)()
{
	alias Params = ParameterTypeTuple!Method;
	alias Return = ReturnType!Method;

	static assert(__traits(isVirtualMethod, Method),
		"D-Bus interface method " ~ ident ~
		" must not be final or static; non-virtual interface methods are not supported");

	static if (isPromise!Return)
		static assert(is(PromiseError!Return == Exception),
			"D-Bus interface method " ~ ident ~
			" must return a Promise with the default Exception error type");
	else
		static assert(false,
			"D-Bus interface method " ~ ident ~ " must return a Promise!T");

	static foreach (Param; Params)
		static assert(is(Unqual!Param == Param),
			"D-Bus interface method " ~ ident ~
			" must not use qualified (const/immutable/inout/shared) parameter types");
	static foreach (Param; Params)
		static assert(__traits(compiles, dbusSignature!Param),
			"D-Bus interface method " ~ ident ~
			" has a parameter type with no D-Bus signature");

	static assert(functionAttributes!Method == FunctionAttribute.system,
		"D-Bus interface method " ~ ident ~
		" must not use qualifiers or non-default function attributes");
	static assert(variadicFunctionStyle!Method == Variadic.no,
		"D-Bus interface method " ~ ident ~ " must not be variadic");
	static foreach (storage; ParameterStorageClassTuple!Method)
		static assert(storage == ParameterStorageClass.none,
			"D-Bus interface method " ~ ident ~
			" must not use explicit parameter storage classes");
	static foreach (default_; ParameterDefaults!Method)
		static assert(is(default_ == void),
			"D-Bus interface method " ~ ident ~ " must not use parameter default values");
	return true;
}

bool dbusNamesAreUnique(scope const(string)[] names)
{
	foreach (i; 0 .. names.length)
		foreach (j; i + 1 .. names.length)
			if (names[i] == names[j])
				return false;
	return true;
}

template dbusWireNames(Infos...)
{
	enum string[] dbusWireNames = () {
		string[] names;
		static foreach (Info; Infos)
			names ~= Info.wireName;
		return names;
	}();
}

template dbusOverloadWireNamesAreExplicit(I)
{
	enum dbusOverloadWireNamesAreExplicit = () {
		bool result = true;
		static foreach (ident; __traits(allMembers, I))
			static if (dbusIsFunctionMember!(I, ident) &&
				__traits(getOverloads, I, ident).length > 1)
				static foreach (overload; __traits(getOverloads, I, ident))
					static if (!hasAttribute!(DbusMember, overload))
						result = false;
		return result;
	}();
}

/// Checks the interface-wide rules for `I`.
bool dbusValidateInterface(I)()
{
	static assert(is(I == interface), "D-Bus interfaces must be D interfaces");
	static assert(BaseTypeTuple!I.length == 0,
		"D-Bus interfaces must not inherit from other interfaces");
	enum name = dbusInterfaceName!I;
	static foreach (ident; __traits(allMembers, I))
		static assert(!dbusIsTemplateMember!(I, ident),
			"D-Bus interface methods must not be templated: " ~ ident);

	static assert(dbusNamesAreUnique(dbusWireNames!(dbusCollectMethods!I)),
		"D-Bus interface methods must have unique wire names; use @DbusMember to disambiguate overloads");
	static assert(dbusOverloadWireNamesAreExplicit!I,
		"D-Bus interface methods with more than one overload must have an explicit, distinct @DbusMember wire name on every overload");
	static assert(dbusNamesAreUnique(dbusWireNames!(dbusCollectSignals!I)),
		"D-Bus interface signals must have unique wire names");
	return true;
}

DbusArgumentDescription[] describeDbusArguments(Types...)(scope const(string)[] names)
{
	DbusArgumentDescription[] result;
	static foreach (index, Type; Types)
		result ~= DbusArgumentDescription(names[index],
			DbusSignature.parse(dbusSignature!Type));
	return result;
}

DbusInterfaceDescription describeDbusInterface(I)()
{
	DbusInterfaceDescription description;
	description.name = DbusInterfaceName.parse(dbusInterfaceName!I);
	static foreach (Info; DbusMethodInfos!I)
		description.methods ~= DbusMethodDescription(
			DbusMemberName.parse(Info.wireName),
			describeDbusArguments!(Info.Params)(Info.paramNames),
			describeDbusArguments!(Info.ResultTypes)(new string[Info.ResultTypes.length]));
	static foreach (Info; DbusSignalInfos!I)
		description.signals ~= DbusSignalDescription(
			DbusMemberName.parse(Info.wireName),
			describeDbusArguments!(Info.Types)(new string[Info.Types.length]));
	return description;
}

debug(ae_unittest) import ae.utils.promise : Promise;

debug(ae_unittest)
@DbusInterface("org.example.Described")
interface DbusDescriptionTestInterface
{
	Promise!void Play();
	Promise!(DbusOut!(uint, string)) GetPosition();
	Promise!void Seek(long offset, string mode);
	@DbusMember("EchoString") Promise!string echo(string value);
	@DbusMember("EchoInt") Promise!int echo(int);
	alias Seeked = DbusSignal!("Seeked", long);
	alias Renamed = DbusSignal!("Moved", string, uint);
}

debug(ae_unittest)
@DbusInterface("org.example.InvalidArgument")
interface DbusDescriptionTestInvalidArgument
{
	Promise!void Act(string café);
}

debug(ae_unittest) unittest
{
	static assert(!__traits(compiles,
		dbusInterfaceDescription!DbusDescriptionTestInvalidArgument));
}

debug(ae_unittest) unittest
{
	enum description = dbusInterfaceDescription!DbusDescriptionTestInterface;
	static assert(description.name.text == "org.example.Described");

	static assert(description.methods.length == 5);
	static assert(description.methods[0].name.text == "Play");
	static assert(description.methods[0].inArgs.length == 0);
	static assert(description.methods[0].outArgs.length == 0);

	static assert(description.methods[1].name.text == "GetPosition");
	static assert(description.methods[1].outArgs.length == 2);
	static assert(description.methods[1].outArgs[0].name == "");
	static assert(description.methods[1].outArgs[0].type.text == "u");
	static assert(description.methods[1].outArgs[1].type.text == "s");

	static assert(description.methods[2].name.text == "Seek");
	static assert(description.methods[2].inArgs[0].name == "offset");
	static assert(description.methods[2].inArgs[0].type.text == "x");
	static assert(description.methods[2].inArgs[1].name == "mode");
	static assert(dbusArgumentsSignature(description.methods[2].inArgs).text == "xs");

	static assert(description.methods[3].name.text == "EchoString");
	static assert(description.methods[4].name.text == "EchoInt");
	static assert(description.methods[4].inArgs[0].name == "");
	static assert(description.methods[4].inArgs[0].type.text == "i");
	static assert(description.methods[4].outArgs[0].type.text == "i");

	static assert(description.signals.length == 2);
	static assert(description.signals[0].name.text == "Seeked");
	static assert(description.signals[0].args[0].type.text == "x");
	static assert(description.signals[1].name.text == "Moved");
	static assert(dbusArgumentsSignature(description.signals[1].args).text == "su");

	alias methods = DbusMethodInfos!DbusDescriptionTestInterface;
	static assert(methods.length == description.methods.length);
	static assert(methods[3].identifier == "echo" && methods[3].wireName == "EchoString");
	alias signals = DbusSignalInfos!DbusDescriptionTestInterface;
	static assert(signals[1].identifier == "Renamed" && signals[1].wireName == "Moved");
}
