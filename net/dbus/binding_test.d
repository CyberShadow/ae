/**
 * Compile-time proof that ae.net.dbus.binding accepts well-formed
 * D-Bus interface declarations and rejects every disallowed shape.
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

module ae.net.dbus.binding_test;

debug(ae_unittest)
import ae.net.dbus;
debug(ae_unittest)
import ae.utils.promise : Promise;

debug(ae_unittest)
@DbusStruct
private struct DbusBindingTestTrackInfo
{
	string title;
	uint length;
}

debug(ae_unittest)
@DbusInterface("com.example.Player1")
private interface DbusBindingTestPlayer
{
	Promise!void Play();

	@DbusMember("GetTrack")
	Promise!DbusBindingTestTrackInfo track();

	Promise!(DbusOut!(uint, string)) GetPosition();
	Promise!(string[]) GetTags();
	Promise!(int[string]) GetCounts();
	Promise!void Seek(long offset, string mode, DbusBindingTestTrackInfo hint);

	@DbusMember("EchoString")
	Promise!string echo(string value);
	@DbusMember("EchoInt")
	Promise!int echo(int value);

	alias TrackChanged = DbusSignal!("TrackChanged", DbusObjectPath);
}

debug(ae_unittest) unittest
{
	DbusConnection connection;
	auto proxy = dbusProxy!DbusBindingTestPlayer(connection,
		DbusBusName.parse("com.example.Player"), DbusObjectPath.parse("/Player"));

	static assert(is(typeof(proxy.Play()) == Promise!void));
	static assert(is(typeof(proxy.track()) == Promise!DbusBindingTestTrackInfo));
	static assert(is(typeof(proxy.GetPosition()) == Promise!(DbusOut!(uint, string))));
	static assert(is(typeof(proxy.GetTags()) == Promise!(string[])));
	static assert(is(typeof(proxy.GetCounts()) == Promise!(int[string])));
	static assert(is(typeof(proxy.Seek(0, "abs", DbusBindingTestTrackInfo.init)) == Promise!void));
	static assert(is(typeof(proxy.echo("x")) == Promise!string));
	static assert(is(typeof(proxy.echo(1)) == Promise!int));

	static assert(is(typeof(subscribe!(DbusBindingTestPlayer.TrackChanged)(proxy, (DbusObjectPath path) {})) == Promise!DbusSubscription));

	static assert(is(typeof(getProperty!(string, DbusBindingTestPlayer)(proxy, "Foo")) == Promise!string));

	static assert(is(typeof(setProperty!string(proxy, "Foo", "bar")) == Promise!void));

	static assert(is(typeof(getAllProperties(proxy)) == Promise!(DbusVariant[string])));

	void delegate(DbusVariant[string], string[]) changedHandler = (a, b) {};
	static assert(is(typeof(subscribePropertiesChanged(proxy, changedHandler)) == Promise!DbusSubscription));

	static assert(is(typeof(introspect(proxy)) == Promise!string));
}

debug(ae_unittest)
@DbusInterface("com.example.Base")
private interface DbusBindingTestBase { Promise!void Foo(); }

debug(ae_unittest)
@DbusInterface("com.example.BadInherit")
private interface DbusBindingTestBadInherit : DbusBindingTestBase { Promise!void Bar(); }

debug(ae_unittest)
@DbusInterface("com.example.BadDup")
private interface DbusBindingTestBadDup { Promise!void Foo(); @DbusMember("Foo") Promise!void Bar(); }

debug(ae_unittest)
@DbusInterface("com.example.BadRef")
private interface DbusBindingTestBadRef { Promise!void Foo(ref int x); }

debug(ae_unittest)
@DbusInterface("com.example.BadDefault")
private interface DbusBindingTestBadDefault { Promise!void Foo(int x = 5); }

debug(ae_unittest)
private class DbusBindingTestCustomError : Exception { this() { super(null); } }
debug(ae_unittest)
@DbusInterface("com.example.BadError")
private interface DbusBindingTestBadError { Promise!(int, DbusBindingTestCustomError) Foo(); }

debug(ae_unittest)
@DbusInterface("com.example.BadVariadic")
private interface DbusBindingTestBadVariadic { Promise!void Foo(int[] x...); }

debug(ae_unittest)
@DbusInterface("com.example.BadTemplate")
private interface DbusBindingTestBadTemplate { Promise!T Foo(T)(T x); }

debug(ae_unittest)
@DbusInterface("com.example.BadNonPromise")
private interface DbusBindingTestBadNonPromise { int Foo(); }

debug(ae_unittest)
@DbusInterface("com.example.BadSafe")
private interface DbusBindingTestBadSafe { Promise!void Foo() @safe; }

debug(ae_unittest)
private interface DbusBindingTestNoUda { Promise!void Foo(); }

debug(ae_unittest)
private struct DbusBindingTestUnregisteredStruct { string value; }
debug(ae_unittest)
@DbusInterface("com.example.BadUnregisteredStructParam")
private interface DbusBindingTestBadUnregisteredStructParam { Promise!void Foo(DbusBindingTestUnregisteredStruct x); }

debug(ae_unittest)
@DbusStruct
private struct DbusBindingTestPrivateFieldStruct { private string value; }
debug(ae_unittest)
@DbusInterface("com.example.BadPrivateFieldStructParam")
private interface DbusBindingTestBadPrivateFieldStructParam { Promise!void Foo(DbusBindingTestPrivateFieldStruct x); }

debug(ae_unittest)
@DbusStruct
private struct DbusBindingTestEmptyStruct { }
debug(ae_unittest)
@DbusInterface("com.example.BadEmptyStructParam")
private interface DbusBindingTestBadEmptyStructParam { Promise!void Foo(DbusBindingTestEmptyStruct x); }

debug(ae_unittest)
@DbusInterface("com.example.BadPromiseType")
private interface DbusBindingTestBadPromiseType { Promise!Object Foo(); }

debug(ae_unittest)
@DbusInterface("com.example.BadOutParam")
private interface DbusBindingTestBadOutParam { Promise!void Foo(out int x); }

debug(ae_unittest)
@DbusInterface("com.example.BadLazyParam")
private interface DbusBindingTestBadLazyParam { Promise!void Foo(lazy int x); }

debug(ae_unittest)
@DbusInterface("com.example.BadScopeParam")
private interface DbusBindingTestBadScopeParam { Promise!void Foo(scope int[] x); }

debug(ae_unittest)
@DbusInterface("com.example.BadConstParam")
private interface DbusBindingTestBadConstParam { Promise!void Foo(const int x); }

debug(ae_unittest)
@DbusInterface("com.example.BadConstMethod")
private interface DbusBindingTestBadConstMethod { Promise!void Foo() const; }

debug(ae_unittest)
@DbusInterface("com.example.BadRefReturn")
private interface DbusBindingTestBadRefReturn { ref Promise!void Foo(); }

debug(ae_unittest)
@DbusInterface("com.example.BadDuplicateUda1")
@DbusInterface("com.example.BadDuplicateUda2")
private interface DbusBindingTestBadDuplicateUda { Promise!void Foo(); }

debug(ae_unittest)
@DbusInterface("com.example.BadPartialOverloadUda")
private interface DbusBindingTestBadPartialOverloadUda
{
	Promise!void Foo();
	@DbusMember("Bar") Promise!void Foo(int);
}

debug(ae_unittest)
@DbusInterface("com.example.BadFinalMethod")
private interface DbusBindingTestBadFinalMethod { final Promise!void Foo() { return null; } }

debug(ae_unittest)
@DbusInterface("com.example.BadStaticMethod")
private interface DbusBindingTestBadStaticMethod { static Promise!void Foo() { return null; } }

debug(ae_unittest)
@DbusInterface("com.example.BadInParam")
private interface DbusBindingTestBadInParam { Promise!void Foo(in int x); }

debug(ae_unittest)
@DbusInterface("com.example.BadReturnParam")
private interface DbusBindingTestBadReturnParam { Promise!void Foo(return int x); }

debug(ae_unittest)
@DbusInterface("com.example.BadInoutParam")
private interface DbusBindingTestBadInoutParam { Promise!void Foo(inout int x); }

debug(ae_unittest)
@DbusInterface("com.example.BadSharedParam")
private interface DbusBindingTestBadSharedParam { Promise!void Foo(shared int x); }

debug(ae_unittest)
@DbusInterface("com.example.BadProperty")
private interface DbusBindingTestBadProperty { @property Promise!void Foo(); }

debug(ae_unittest)
@DbusInterface("com.example.BadTrusted")
private interface DbusBindingTestBadTrusted { Promise!void Foo() @trusted; }

debug(ae_unittest)
@DbusInterface("com.example.BadPure")
private interface DbusBindingTestBadPure { Promise!void Foo() pure; }

debug(ae_unittest)
@DbusInterface("com.example.BadNothrow")
private interface DbusBindingTestBadNothrow { Promise!void Foo() nothrow; }

debug(ae_unittest)
@DbusInterface("com.example.BadNogc")
private interface DbusBindingTestBadNogc { Promise!void Foo() @nogc; }

debug(ae_unittest) unittest
{
	static assert(!__traits(compiles, DbusProxy!DbusBindingTestBadInherit));
	static assert(!__traits(compiles, DbusProxy!DbusBindingTestBadDup));
	static assert(!__traits(compiles, DbusProxy!DbusBindingTestBadRef));
	static assert(!__traits(compiles, DbusProxy!DbusBindingTestBadDefault));
	static assert(!__traits(compiles, DbusProxy!DbusBindingTestBadError));
	static assert(!__traits(compiles, DbusProxy!DbusBindingTestBadVariadic));
	static assert(!__traits(compiles, DbusProxy!DbusBindingTestBadTemplate));
	static assert(!__traits(compiles, DbusProxy!DbusBindingTestBadNonPromise));
	static assert(!__traits(compiles, DbusProxy!DbusBindingTestBadSafe));
	static assert(!__traits(compiles, DbusProxy!DbusBindingTestNoUda));
	static assert(!__traits(compiles, DbusProxy!DbusBindingTestBadUnregisteredStructParam));
	static assert(!__traits(compiles, DbusProxy!DbusBindingTestBadPrivateFieldStructParam));
	static assert(!__traits(compiles, DbusProxy!DbusBindingTestBadEmptyStructParam));
	static assert(!__traits(compiles, DbusProxy!DbusBindingTestBadPromiseType));
	static assert(!__traits(compiles, DbusProxy!DbusBindingTestBadOutParam));
	static assert(!__traits(compiles, DbusProxy!DbusBindingTestBadLazyParam));
	static assert(!__traits(compiles, DbusProxy!DbusBindingTestBadScopeParam));
	static assert(!__traits(compiles, DbusProxy!DbusBindingTestBadConstParam));
	static assert(!__traits(compiles, DbusProxy!DbusBindingTestBadConstMethod));
	static assert(!__traits(compiles, DbusProxy!DbusBindingTestBadRefReturn));
	static assert(!__traits(compiles, DbusProxy!DbusBindingTestBadDuplicateUda));
	static assert(!__traits(compiles, DbusProxy!DbusBindingTestBadPartialOverloadUda));
	static assert(!__traits(compiles, DbusProxy!DbusBindingTestBadFinalMethod));
	static assert(!__traits(compiles, DbusProxy!DbusBindingTestBadStaticMethod));
	static assert(!__traits(compiles, DbusProxy!DbusBindingTestBadInParam));
	// Bare `return` on a by-value parameter is only preserved as
	// ParameterStorageClass.return_ starting with frontend 2.104; older
	// frontends (dmd 2.096, and ldc 1.32.2's 2.102 frontend) silently drop
	// it, so there is nothing for DbusProxy to detect and reject there.
	static if (__VERSION__ >= 2104)
		static assert(!__traits(compiles, DbusProxy!DbusBindingTestBadReturnParam));
	static assert(!__traits(compiles, DbusProxy!DbusBindingTestBadInoutParam));
	static assert(!__traits(compiles, DbusProxy!DbusBindingTestBadSharedParam));
	static assert(!__traits(compiles, DbusProxy!DbusBindingTestBadProperty));
	static assert(!__traits(compiles, DbusProxy!DbusBindingTestBadTrusted));
	static assert(!__traits(compiles, DbusProxy!DbusBindingTestBadPure));
	static assert(!__traits(compiles, DbusProxy!DbusBindingTestBadNothrow));
	static assert(!__traits(compiles, DbusProxy!DbusBindingTestBadNogc));

	static assert(__traits(compiles, DbusProxy!DbusBindingTestBase));
}
