/**
 * Flat SAX-style event protocol for serialization.
 *
 * Alternative to the reader/callback pattern in serialization.d.
 * Instead of nested callbacks (handleArray(reader)), uses flat
 * start/end events that can be driven by a pure state machine.
 *
 * Provides bidirectional adapters between the two protocols:
 * - `FlatToCallbackAdapter` — receives flat events, emits callback protocol
 * - `CallbackToFlatAdapter` — receives callback protocol, emits flat events
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

module ae.utils.serialization.flat;

import std.conv;
import std.exception;
import std.format;

import ae.utils.serialization.serialization;

// ===========================================================================
// Flat Event Types
// ===========================================================================

private enum FlatEventType
{
	null_, boolean, numeric, string_,
	startArray, endArray,
	startObject, endObject,
	key,
}

private struct FlatEvent
{
	FlatEventType type;
	const(char)[] strData;
	bool boolData;
}

// ===========================================================================
// Flat-to-Callback Adapter
// ===========================================================================

/// Converts flat events into the reader/callback protocol.
/// Buffer flat events for composites, then replay them as
/// reader callbacks when the composite closes.
struct FlatToCallbackAdapter(CallbackSink)
{
	CallbackSink sink;

	FlatEvent[][] bufferStack;
	int compositeDepth;

	/// Unified protocol entry point (callback protocol).
	void handle(V)(V v)
	{
		import ae.utils.serialization.serialization : isProtocolNull, isProtocolBoolean,
			isProtocolNumeric, isProtocolString, isProtocolArray, isProtocolMap;

		static if (isProtocolNull!V)
			handleNull();
		else static if (isProtocolBoolean!V)
			handleBoolean(v.value);
		else static if (isProtocolNumeric!V)
			handleNumeric(v.text);
		else static if (isProtocolString!V)
			handleString(v.text);
		else static if (isProtocolArray!V)
		{
			// For callback protocol sources pushing Array/Map, replay through flat adapter
			startArray();
			auto elementAdapter = FlatToCallbackAdapter!CallbackSink();
			elementAdapter.sink = sink;
			v.reader(&elementAdapter);
			endArray();
		}
		else static if (isProtocolMap!V)
		{
			startObject();
			FlatFieldAdapter!(typeof(&this)) fa = {adapter: &this};
			v.reader(&fa);
			endObject();
		}
		else
			static assert(false, "FlatToCallbackAdapter: unsupported type " ~ V.stringof);
	}

	private static struct FlatFieldAdapter(Adapter)
	{
		Adapter adapter;

		void handle(V)(V v)
		{
			import ae.utils.serialization.serialization : isProtocolField;
			import ae.utils.serialization.filter : NameCaptureSink;

			static if (isProtocolField!V)
			{
				NameCaptureSink ns;
				v.nameReader(&ns);
				adapter.key(ns.name);

				auto valueAdapter = FlatToCallbackAdapter!(typeof(adapter.sink))();
				valueAdapter.sink = adapter.sink;
				v.valueReader(&valueAdapter);
			}
			else
				static assert(false, "FlatFieldAdapter: expected Field, got " ~ V.stringof);
		}
	}

	/// Flat API: buffer or forward scalars.
	void handleNull()
	{
		import ae.utils.serialization.serialization : Null;
		if (compositeDepth > 0)
			bufferStack[$ - 1] ~= FlatEvent(FlatEventType.null_);
		else
			sink.handle(Null());
	}

	void handleBoolean(bool v)
	{
		import ae.utils.serialization.serialization : Boolean;
		if (compositeDepth > 0)
			bufferStack[$ - 1] ~= FlatEvent(FlatEventType.boolean, null, v);
		else
			sink.handle(Boolean(v));
	}

	void handleNumeric(CC)(CC[] v)
	{
		import ae.utils.serialization.serialization : Numeric;
		if (compositeDepth > 0)
			bufferStack[$ - 1] ~= FlatEvent(FlatEventType.numeric, v.idup);
		else
			sink.handle(Numeric!(typeof(v))(v));
	}

	void handleString(CC)(CC[] v)
	{
		import ae.utils.serialization.serialization : String;
		if (compositeDepth > 0)
			bufferStack[$ - 1] ~= FlatEvent(FlatEventType.string_, v.idup);
		else
			sink.handle(String!(typeof(v))(v));
	}

	void startArray()
	{
		if (compositeDepth > 0)
		{
			bufferStack[$ - 1] ~= FlatEvent(FlatEventType.startArray);
			compositeDepth++;
			return;
		}
		bufferStack ~= (FlatEvent[]).init;
		compositeDepth = 1;
	}

	void endArray()
	{
		import ae.utils.serialization.serialization : Array;
		if (compositeDepth > 1)
		{
			bufferStack[$ - 1] ~= FlatEvent(FlatEventType.endArray);
			compositeDepth--;
			return;
		}
		auto events = bufferStack[$ - 1];
		bufferStack = bufferStack[0 .. $ - 1];
		compositeDepth = cast(int) bufferStack.length;

		FlatArrayReplayReader reader = {events: events};
		sink.handle(Array!(typeof(reader))(reader));
	}

	void startObject()
	{
		if (compositeDepth > 0)
		{
			bufferStack[$ - 1] ~= FlatEvent(FlatEventType.startObject);
			compositeDepth++;
			return;
		}
		bufferStack ~= (FlatEvent[]).init;
		compositeDepth = 1;
	}

	void endObject()
	{
		import ae.utils.serialization.serialization : Map;
		if (compositeDepth > 1)
		{
			bufferStack[$ - 1] ~= FlatEvent(FlatEventType.endObject);
			compositeDepth--;
			return;
		}
		auto events = bufferStack[$ - 1];
		bufferStack = bufferStack[0 .. $ - 1];
		compositeDepth = cast(int) bufferStack.length;

		FlatObjectReplayReader reader = {events: events};
		sink.handle(Map!(typeof(reader))(reader));
	}

	void key(CC)(CC[] k)
	{
		bufferStack[$ - 1] ~= FlatEvent(FlatEventType.key, k.idup);
	}
}

/// Create a FlatToCallbackAdapter wrapping a callback-style sink.
auto flatToCallback(S)(S sink)
{
	return FlatToCallbackAdapter!S(sink);
}

// ===========================================================================
// Callback-to-Flat Adapter
// ===========================================================================

/// Converts callback protocol events to flat events.
/// Wraps a flat sink to present the callback protocol interface.
struct CallbackToFlatAdapter(FlatSink)
{
	FlatSink sink;

	void handle(V)(V v)
	{
		import ae.utils.serialization.serialization : isProtocolNull, isProtocolBoolean,
			isProtocolNumeric, isProtocolString, isProtocolArray, isProtocolMap;

		static if (isProtocolNull!V)
			sink.handleNull();
		else static if (isProtocolBoolean!V)
			sink.handleBoolean(v.value);
		else static if (isProtocolNumeric!V)
			sink.handleNumeric(v.text);
		else static if (isProtocolString!V)
			sink.handleString(v.text);
		else static if (isProtocolArray!V)
		{
			sink.startArray();
			auto elementSink = CallbackToFlatAdapter!FlatSink(sink);
			v.reader(&elementSink);
			sink.endArray();
		}
		else static if (isProtocolMap!V)
		{
			sink.startObject();
			FieldAdapter!FlatSink fieldSink = {sink: sink};
			v.reader(&fieldSink);
			sink.endObject();
		}
		else
			static assert(false, "CallbackToFlatAdapter: unsupported type " ~ V.stringof);
	}

	static struct FieldAdapter(FS)
	{
		FS sink;

		void handle(V)(V v)
		{
			import ae.utils.serialization.serialization : isProtocolField, isProtocolNull,
				isProtocolBoolean, isProtocolNumeric, isProtocolString;

			static if (isProtocolField!V)
			{
				static struct NameSink
				{
					FS sink;
					void handle(VV)(VV vv)
					{
						import ae.utils.serialization.serialization : isProtocolString,
							isProtocolNull, isProtocolBoolean, isProtocolNumeric;
						static if (isProtocolString!VV)
							sink.key(vv.text);
						else static if (isProtocolNull!VV)
							sink.key("null");
						else static if (isProtocolBoolean!VV)
							sink.key(vv.value ? "true" : "false");
						else static if (isProtocolNumeric!VV)
							sink.key(vv.text);
						else
							static assert(false, "NameSink: unsupported key type " ~ VV.stringof);
					}
				}

				NameSink ns = {sink: sink};
				v.nameReader(&ns);

				auto valueSink = CallbackToFlatAdapter!FS(sink);
				v.valueReader(&valueSink);
			}
			else
				static assert(false, "FieldAdapter: expected Field, got " ~ V.stringof);
		}
	}
}

/// Create a CallbackToFlatAdapter wrapping a flat sink.
auto callbackToFlat(S)(S sink)
{
	return CallbackToFlatAdapter!S(sink);
}

// ===========================================================================
// Flat Event Collector (for testing)
// ===========================================================================

/// Collects flat events as strings for testing.
struct FlatEventCollector
{
	string[] events;

	void handleNull() { events ~= "null"; }
	void handleBoolean(bool v) { events ~= v ? "true" : "false"; }
	void handleNumeric(CC)(CC[] v) { events ~= "num:" ~ v.idup; }
	void handleString(CC)(CC[] v) { events ~= "str:" ~ v.idup; }
	void startArray() { events ~= "["; }
	void endArray() { events ~= "]"; }
	void startObject() { events ~= "{"; }
	void endObject() { events ~= "}"; }
	void key(CC)(CC[] k) { events ~= "key:" ~ k.idup; }
}

// ===========================================================================
// Replay helpers (module-level to avoid template nesting issues)
// ===========================================================================

private void replayValue(Sink)(FlatEvent[] events, ref size_t i, Sink sink)
{
	import ae.utils.serialization.serialization : Null, Boolean, Numeric,
		String, Array, Map;

	auto ev = events[i];
	i++;
	final switch (ev.type)
	{
	case FlatEventType.null_:
		sink.handle(Null());
		break;
	case FlatEventType.boolean:
		sink.handle(Boolean(ev.boolData));
		break;
	case FlatEventType.numeric:
		sink.handle(Numeric!(typeof(ev.strData))(ev.strData));
		break;
	case FlatEventType.string_:
		sink.handle(String!(typeof(ev.strData))(ev.strData));
		break;
	case FlatEventType.startArray:
	{
		auto subEvents = collectUntilEnd(events, i, FlatEventType.endArray, FlatEventType.startArray);
		FlatArrayReplayReader reader = {events: subEvents};
		sink.handle(Array!(typeof(reader))(reader));
		break;
	}
	case FlatEventType.startObject:
	{
		auto subEvents = collectUntilEnd(events, i, FlatEventType.endObject, FlatEventType.startObject);
		FlatObjectReplayReader reader = {events: subEvents};
		sink.handle(Map!(typeof(reader))(reader));
		break;
	}
	case FlatEventType.endArray:
	case FlatEventType.endObject:
	case FlatEventType.key:
		assert(false, "Unexpected event in value position");
	}
}

private FlatEvent[] collectUntilEnd(FlatEvent[] events, ref size_t i, FlatEventType endType, FlatEventType startType)
{
	auto start = i;
	int depth = 1;
	while (depth > 0)
	{
		if (events[i].type == startType)
			depth++;
		else if (events[i].type == endType)
			depth--;
		if (depth > 0)
			i++;
	}
	auto result = events[start .. i];
	i++; // skip the end event
	return result;
}

private struct FlatArrayReplayReader
{
	FlatEvent[] events;

	void opCall(Sink)(Sink sink)
	{
		size_t i;
		while (i < events.length)
			replayValue(events, i, sink);
	}
}

private struct FlatObjectReplayReader
{
	FlatEvent[] events;

	void opCall(Sink)(Sink sink)
	{
		import ae.utils.serialization.serialization : Field;

		size_t i;
		while (i < events.length)
		{
			enforce(events[i].type == FlatEventType.key);
			auto keyStr = events[i].strData;
			i++;

			FlatStringEmitter nameReader = {str: keyStr};
			FlatValueReplayReader valueReader = {events: events, pos: &i};
			sink.handle(Field!(typeof(nameReader), typeof(valueReader))(nameReader, valueReader));
		}
	}
}

private struct FlatStringEmitter
{
	const(char)[] str;

	void opCall(Sink)(Sink sink)
	{
		import ae.utils.serialization.serialization : String;
		sink.handle(String!(typeof(str))(str));
	}
}

private struct FlatValueReplayReader
{
	FlatEvent[] events;
	size_t* pos;

	void opCall(Sink)(Sink sink)
	{
		replayValue(events, *pos, sink);
	}
}

// ===========================================================================
// Unit Tests
// ===========================================================================


// Flat-to-Callback: simple struct
debug(ae_unittest) unittest
{
	static struct S { int x; string name; }

	S result;
	auto cbSink = deserializer(&result);
	auto adapter = flatToCallback(cbSink);

	adapter.startObject();
	adapter.key("x");
	adapter.handleNumeric("42");
	adapter.key("name");
	adapter.handleString("hello");
	adapter.endObject();

	assert(result.x == 42);
	assert(result.name == "hello");
}

// Flat-to-Callback: nested struct
debug(ae_unittest) unittest
{
	static struct Inner { int v; }
	static struct Outer { string name; Inner inner; int[] arr; }

	Outer result;
	auto cbSink = deserializer(&result);
	auto adapter = flatToCallback(cbSink);

	adapter.startObject();
	adapter.key("name");
	adapter.handleString("test");
	adapter.key("inner");
	adapter.startObject();
	adapter.key("v");
	adapter.handleNumeric("7");
	adapter.endObject();
	adapter.key("arr");
	adapter.startArray();
	adapter.handleNumeric("1");
	adapter.handleNumeric("2");
	adapter.handleNumeric("3");
	adapter.endArray();
	adapter.endObject();

	assert(result.name == "test");
	assert(result.inner.v == 7);
	assert(result.arr == [1, 2, 3]);
}

// Callback-to-Flat: struct -> flat events
debug(ae_unittest) unittest
{
	static struct S { int x; string name; }

	S original = S(42, "hello");
	FlatEventCollector collector;
	auto adapter = callbackToFlat(&collector);
	Serializer.Impl!Object.read(&adapter, original);

	assert(collector.events == [
		"{",
		"key:x", "num:42",
		"key:name", "str:hello",
		"}"
	], format("%s", collector.events));
}

// Callback-to-Flat: arrays
debug(ae_unittest) unittest
{
	FlatEventCollector collector;
	auto adapter = callbackToFlat(&collector);
	Serializer.Impl!Object.read(&adapter, [1, 2, 3]);

	assert(collector.events == [
		"[", "num:1", "num:2", "num:3", "]"
	]);
}

// Round-trip: Callback -> Flat -> Callback
debug(ae_unittest) unittest
{
	static struct Inner { int x; string s; }
	static struct Outer { int a; string name; Inner inner; int[] arr; }

	Outer original;
	original.a = 42;
	original.name = "hello";
	original.inner.x = 7;
	original.inner.s = "world";
	original.arr = [1, 2, 3];

	Outer result;
	auto cbSink = deserializer(&result);
	auto flat2cb = flatToCallback(cbSink);
	auto cb2flat = callbackToFlat(&flat2cb);
	Serializer.Impl!Object.read(&cb2flat, original);

	assert(result.a == 42);
	assert(result.name == "hello");
	assert(result.inner.x == 7);
	assert(result.inner.s == "world");
	assert(result.arr == [1, 2, 3]);
}
