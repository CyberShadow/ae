/**
 * Reusable filter infrastructure for the source/sink serialization framework.
 *
 * A filter sits between a source and a sink, receives events, optionally
 * transforms them, and forwards to a downstream sink. This module provides
 * mixin templates and generic wrapper structs that eliminate boilerplate
 * when writing serialization filters.
 *
 * Convention: filter structs must have:
 *   - a `downstream` member (the sink to forward to)
 *   - a `makeFilter(S)(S sink)` method (creates a new filter for nested levels)
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

module ae.utils.serialization.filter;

import std.conv;

import ae.utils.serialization.serialization;
import ae.utils.serialization.store;

// =========================================================================
// DrainSink — consumes and discards any value tree
// =========================================================================

/// Drain sink: consumes and discards any value tree. Useful when a filter
/// wants to skip a subtree but the source requires the reader to be called.
struct DrainSink
{
	void handle(V)(V v)
	{
		import ae.utils.serialization.serialization : isProtocolArray, isProtocolMap, isProtocolField;

		static if (isProtocolArray!V)
		{
			DrainSink ds;
			v.reader(&ds);
		}
		else static if (isProtocolMap!V)
		{
			DrainSink ds;
			v.reader(&ds);
		}
		else static if (isProtocolField!V)
		{
			DrainSink ds;
			v.nameReader(&ds);
			v.valueReader(&ds);
		}
		// Scalars (Null, Boolean, Numeric, String): discard
	}
}

// =========================================================================
// Generic wrapper structs
// =========================================================================

/// Wraps an array reader to insert a filter around each element sink.
/// Config must have `makeFilter(Sink)(Sink sink)`.
struct FilteredArrayReader(OrigReader, Config)
{
	OrigReader originalReader;
	Config config;

	void opCall(Sink)(Sink sink)
	{
		auto filter = config.makeFilter(sink);
		originalReader(&filter);
	}
}

/// Wraps a value reader to push events through a new filter instance.
struct FilteredValueReader(OrigReader, Config)
{
	OrigReader originalReader;
	Config config;

	void opCall(Sink)(Sink sink)
	{
		auto filter = config.makeFilter(sink);
		originalReader(&filter);
	}
}

/// Wraps an object reader to filter only field values (names pass through).
struct ValueFilteredObjectReader(OrigReader, Config)
{
	OrigReader originalReader;
	Config config;

	void opCall(Sink)(Sink sink)
	{
		ValueFilteredFieldSink!(Sink, Config) fs = {downstream: sink, config: config};
		originalReader(&fs);
	}
}

/// Field sink that filters values but passes names through unchanged.
struct ValueFilteredFieldSink(Sink, Config)
{
	Sink downstream;
	Config config;

	void handle(V)(V v)
	{
		import ae.utils.serialization.serialization : isProtocolField, Field;

		static if (isProtocolField!V)
		{
			alias VR = typeof(v.valueReader);
			FilteredValueReader!(VR, Config) wvr = {originalReader: v.valueReader, config: config};
			alias NR = typeof(v.nameReader);
			downstream.handle(Field!(NR, typeof(wvr))(v.nameReader, wvr));
		}
		else
			static assert(false, "ValueFilteredFieldSink: expected Field, got " ~ V.stringof);
	}
}

/// Wraps an object reader to filter both field names and values.
struct FullFilteredObjectReader(OrigReader, Config)
{
	OrigReader originalReader;
	Config config;

	void opCall(Sink)(Sink sink)
	{
		FullFilteredFieldSink!(Sink, Config) fs = {downstream: sink, config: config};
		originalReader(&fs);
	}
}

/// Field sink that filters both names and values.
struct FullFilteredFieldSink(Sink, Config)
{
	Sink downstream;
	Config config;

	void handle(V)(V v)
	{
		import ae.utils.serialization.serialization : isProtocolField, Field;

		static if (isProtocolField!V)
		{
			alias NR = typeof(v.nameReader);
			alias VR = typeof(v.valueReader);
			FilteredValueReader!(NR, Config) wnr = {originalReader: v.nameReader, config: config};
			FilteredValueReader!(VR, Config) wvr = {originalReader: v.valueReader, config: config};
			downstream.handle(Field!(typeof(wnr), typeof(wvr))(wnr, wvr));
		}
		else
			static assert(false, "FullFilteredFieldSink: expected Field, got " ~ V.stringof);
	}
}

// =========================================================================
// Mixin templates
// =========================================================================

/// Provides default pass-through for scalar sink events.
/// The mixing struct must have a `downstream` member.
/// For arrays and objects, simply forwards without filtering.
mixin template ScalarPassthrough()
{
	void handle(V)(V v)
	{
		downstream.handle(v);
	}
}

/// Provides default pass-through for all sink events with recursive filtering.
/// For arrays and objects, wraps readers to insert filters at nested levels.
/// Object handling filters values only (names pass through unchanged).
/// The mixing struct must have `downstream` and `makeFilter(S)(S sink)`.
mixin template RecursivePassthrough()
{
	void handle(V)(V v)
	{
		import ae.utils.serialization.serialization : isProtocolArray, isProtocolMap,
			rewrapArray, rewrapMap;

		static if (isProtocolArray!V)
		{
			auto self = &this;
			alias R = typeof(v.reader);
			FilteredArrayReader!(R, typeof(self)) wr = {originalReader: v.reader, config: self};
			downstream.handle(rewrapArray(v, wr));
		}
		else static if (isProtocolMap!V)
		{
			auto self = &this;
			alias R = typeof(v.reader);
			ValueFilteredObjectReader!(R, typeof(self)) wr = {originalReader: v.reader, config: self};
			downstream.handle(rewrapMap(v, wr));
		}
		else
			downstream.handle(v);
	}
}

// =========================================================================
// Utility: NameCaptureSink
// =========================================================================

/// A minimal sink that captures a string value (for reading field names).
struct NameCaptureSink
{
	string name;

	void handle(V)(V v)
	{
		import ae.utils.serialization.serialization : isProtocolString;

		static if (isProtocolString!V)
			name = v.text.to!string;
		// Other types: ignore (field names are always strings)
	}
}

/// Creates a reader callable that emits a string to any sink.
struct StringEmitter(S)
{
	S value;
	void opCall(Sink)(Sink sink)
	{
		import ae.utils.serialization.serialization : String;
		sink.handle(String!(typeof(value))(value));
	}
}

auto stringEmitter(S)(S value)
{
	StringEmitter!S r = {value: value};
	return r;
}

// =========================================================================
// Filter: RecursionLimiter
// =========================================================================

/// Filter that replaces nested structures beyond maxDepth with null.
struct RecursionLimiter(Sink)
{
	Sink downstream;
	uint maxDepth;
	uint currentDepth;

	auto makeFilter(S)(S sink)
	{
		return RecursionLimiter!S(sink, maxDepth, currentDepth + 1);
	}

	void handle(V)(V v)
	{
		import ae.utils.serialization.serialization : Null, isProtocolArray, isProtocolMap,
			rewrapArray, rewrapMap;

		static if (isProtocolArray!V)
		{
			if (currentDepth >= maxDepth)
			{
				DrainSink ds;
				v.reader(&ds);
				downstream.handle(Null());
				return;
			}
			auto self = &this;
			alias R = typeof(v.reader);
			FilteredArrayReader!(R, typeof(self)) wr = {originalReader: v.reader, config: self};
			downstream.handle(rewrapArray(v, wr));
		}
		else static if (isProtocolMap!V)
		{
			if (currentDepth >= maxDepth)
			{
				DrainSink ds;
				v.reader(&ds);
				downstream.handle(Null());
				return;
			}
			auto self = &this;
			alias R = typeof(v.reader);
			FullFilteredObjectReader!(R, typeof(self)) wr = {originalReader: v.reader, config: self};
			downstream.handle(rewrapMap(v, wr));
		}
		else
			downstream.handle(v);
	}
}

auto recursionLimiter(Sink)(Sink sink, uint maxDepth)
{
	return RecursionLimiter!Sink(sink, maxDepth, 0);
}

// =========================================================================
// Filter: FieldRenamer
// =========================================================================

/// Filter that renames object fields based on a runtime mapping.
/// Renaming applies recursively at all nesting levels.
struct FieldRenamer(Sink)
{
	Sink downstream;
	const(string)[] from;
	const(string)[] to;

	auto makeFilter(S)(S sink)
	{
		return FieldRenamer!S(sink, from, to);
	}

	void handle(V)(V v)
	{
		import ae.utils.serialization.serialization : isProtocolArray, isProtocolMap,
			rewrapArray, rewrapMap;

		static if (isProtocolArray!V)
		{
			auto self = &this;
			alias R = typeof(v.reader);
			FilteredArrayReader!(R, typeof(self)) wr = {originalReader: v.reader, config: self};
			downstream.handle(rewrapArray(v, wr));
		}
		else static if (isProtocolMap!V)
		{
			auto self = &this;
			alias R = typeof(v.reader);
			RenamerObjectReader!(R, typeof(self)) wr = {originalReader: v.reader, config: self};
			downstream.handle(rewrapMap(v, wr));
		}
		else
			downstream.handle(v);
	}

	private static struct RenamerObjectReader(OrigReader, Config)
	{
		OrigReader originalReader;
		Config config;

		void opCall(OSink)(OSink objSink)
		{
			RenamerFieldSink!(OSink, Config) fs = {objSink: objSink, config: config};
			originalReader(&fs);
		}
	}

	private static struct RenamerFieldSink(OSink, Config)
	{
		OSink objSink;
		Config config;

		void handle(V)(V v)
		{
			import ae.utils.serialization.serialization : isProtocolField, Field;

			static if (isProtocolField!V)
			{
				NameCaptureSink capture;
				v.nameReader(&capture);

				string name = capture.name;
				foreach (i, f; config.from)
					if (name == f)
					{
						name = config.to[i];
						break;
					}

				auto emitter = stringEmitter(name);
				alias VR = typeof(v.valueReader);
				FilteredValueReader!(VR, Config) wvr = {originalReader: v.valueReader, config: config};
				objSink.handle(Field!(typeof(emitter), typeof(wvr))(emitter, wvr));
			}
			else
				static assert(false, "RenamerFieldSink: expected Field, got " ~ V.stringof);
		}
	}
}

auto fieldRenamer(Sink)(Sink sink, const(string)[] from, const(string)[] to)
{
	return FieldRenamer!Sink(sink, from, to);
}

// =========================================================================
// Filter: TypeCoercer
// =========================================================================

/// Filter that converts between compatible scalar types.
struct TypeCoercer(Sink)
{
	Sink downstream;
	bool stringsToNumbers;
	bool stringsToBoolean;
	bool numbersToStrings;

	auto makeFilter(S)(S sink)
	{
		return TypeCoercer!S(sink, stringsToNumbers, stringsToBoolean, numbersToStrings);
	}

	void handle(V)(V v)
	{
		import ae.utils.serialization.serialization : isProtocolNull, isProtocolBoolean,
			isProtocolNumeric, isProtocolString, isProtocolArray, isProtocolMap,
			ProtocolTextType, Boolean, Numeric, String,
			rewrapArray, rewrapMap;

		static if (isProtocolNull!V || isProtocolBoolean!V)
			downstream.handle(v);
		else static if (isProtocolNumeric!V)
		{
			if (numbersToStrings)
			{
				alias S = ProtocolTextType!V;
				downstream.handle(String!(S)(v.text));
			}
			else
				downstream.handle(v);
		}
		else static if (isProtocolString!V)
		{
			alias S = ProtocolTextType!V;
			if (stringsToBoolean)
			{
				if (v.text == "true")  { downstream.handle(Boolean(true));  return; }
				if (v.text == "false") { downstream.handle(Boolean(false)); return; }
			}
			if (stringsToNumbers && isNumericString(v.text))
			{
				downstream.handle(Numeric!(S)(v.text));
				return;
			}
			downstream.handle(v);
		}
		else static if (isProtocolArray!V)
		{
			auto self = &this;
			alias R = typeof(v.reader);
			FilteredArrayReader!(R, typeof(self)) wr = {originalReader: v.reader, config: self};
			downstream.handle(rewrapArray(v, wr));
		}
		else static if (isProtocolMap!V)
		{
			auto self = &this;
			alias R = typeof(v.reader);
			ValueFilteredObjectReader!(R, typeof(self)) wr = {originalReader: v.reader, config: self};
			downstream.handle(rewrapMap(v, wr));
		}
		else
			downstream.handle(v);
	}

	private static bool isNumericString(S)(S s)
	{
		if (s.length == 0) return false;
		size_t i = 0;
		if (s[0] == '-' || s[0] == '+') i++;
		if (i >= s.length) return false;
		bool hasDigit = false;
		bool hasDot = false;
		while (i < s.length)
		{
			if (s[i] >= '0' && s[i] <= '9') { hasDigit = true; i++; }
			else if (s[i] == '.' && !hasDot) { hasDot = true; i++; }
			else if ((s[i] == 'e' || s[i] == 'E') && hasDigit)
			{
				i++;
				if (i < s.length && (s[i] == '+' || s[i] == '-')) i++;
				if (i >= s.length || s[i] < '0' || s[i] > '9') return false;
				while (i < s.length && s[i] >= '0' && s[i] <= '9') i++;
				return i == s.length;
			}
			else return false;
		}
		return hasDigit;
	}
}

auto typeCoercer(Sink)(Sink sink, bool strToNum = false, bool strToBool = false, bool numToStr = false)
{
	return TypeCoercer!Sink(sink, strToNum, strToBool, numToStr);
}

// =========================================================================
// Filter: FieldFilter
// =========================================================================

/// Filter that only passes through fields in an allow-list.
/// Fields not in the list are drained (skipped). Applies recursively.
struct FieldFilter(Sink)
{
	Sink downstream;
	const(string)[] allowedFields;

	auto makeFilter(S)(S sink)
	{
		return FieldFilter!S(sink, allowedFields);
	}

	void handle(V)(V v)
	{
		import ae.utils.serialization.serialization : isProtocolArray, isProtocolMap,
			rewrapArray, rewrapMap;

		static if (isProtocolArray!V)
		{
			auto self = &this;
			alias R = typeof(v.reader);
			FilteredArrayReader!(R, typeof(self)) wr = {originalReader: v.reader, config: self};
			downstream.handle(rewrapArray(v, wr));
		}
		else static if (isProtocolMap!V)
		{
			auto self = &this;
			alias R = typeof(v.reader);
			FieldFilterObjectReader!(R, typeof(self)) wr = {originalReader: v.reader, config: self};
			downstream.handle(rewrapMap(v, wr));
		}
		else
			downstream.handle(v);
	}

	private static struct FieldFilterObjectReader(OrigReader, Config)
	{
		OrigReader originalReader;
		Config config;

		void opCall(OSink)(OSink objSink)
		{
			FieldFilterFieldSink!(OSink, Config) fs = {objSink: objSink, config: config};
			originalReader(&fs);
		}
	}

	private static struct FieldFilterFieldSink(OSink, Config)
	{
		OSink objSink;
		Config config;

		void handle(V)(V v)
		{
			import ae.utils.serialization.serialization : isProtocolField, Field;

			static if (isProtocolField!V)
			{
				NameCaptureSink capture;
				v.nameReader(&capture);

				bool allowed = false;
				foreach (f; config.allowedFields)
					if (capture.name == f)
					{
						allowed = true;
						break;
					}

				if (allowed)
				{
					auto emitter = stringEmitter(capture.name);
					alias VR = typeof(v.valueReader);
					FilteredValueReader!(VR, Config) wvr = {originalReader: v.valueReader, config: config};
					objSink.handle(Field!(typeof(emitter), typeof(wvr))(emitter, wvr));
				}
				else
				{
					DrainSink ds;
					v.valueReader(&ds);
				}
			}
			else
				static assert(false, "FieldFilterFieldSink: expected Field, got " ~ V.stringof);
		}
	}
}

auto fieldFilter(Sink)(Sink sink, const(string)[] allowedFields)
{
	return FieldFilter!Sink(sink, allowedFields);
}

// =========================================================================
// Filter: TaggedUnionFilter
// =========================================================================

/// Filter that intercepts objects, reads a discriminator field, and rewrites
/// the event stream to wrap the remaining fields in a sub-object keyed by
/// the tag value. This turns `{"type":"image","url":"..."}` into
/// `{"image":{"url":"..."}}`, allowing downstream deserialization into a
/// struct with `@Optional` variant fields.
///
/// The filter buffers each object into a `SerializedObject`, reads the tag,
/// removes the tag field, then replays as a wrapper object.
struct TaggedUnionFilter(Sink)
{
	alias SO = SerializedObject!(immutable(char));

	Sink downstream;
	string tagField;
	/// Optional mapping from tag values to field names.
	/// If null/empty, tag values are used as field names directly.
	const(string[string]) tagToField;

	auto makeFilter(S)(S sink)
	{
		return TaggedUnionFilter!S(sink, tagField, tagToField);
	}

	void handle(V)(V v)
	{
		import ae.utils.serialization.serialization : isProtocolArray, isProtocolMap,
			rewrapArray, Map;

		static if (isProtocolArray!V)
		{
			auto self = &this;
			alias R = typeof(v.reader);
			FilteredArrayReader!(R, typeof(self)) wr = {originalReader: v.reader, config: self};
			downstream.handle(rewrapArray(v, wr));
		}
		else static if (isProtocolMap!V)
		{
			// Buffer the entire object into a SerializedObject
			SO store;
			store.handle(v);

			assert(store.type == SO.Type.object);
			auto tagSO = tagField in store._object;
			if (tagSO is null)
			{
				// No tag field — pass through with nested filtering
				auto self = &this;
				SOFilteredObjectReader!(typeof(self)) fr = {obj: &store, config: self};
				downstream.handle(Map!(typeof(fr))(fr));
				return;
			}

			string tagValue;
			auto tvSink = deserializer(&tagValue);
			tagSO.read(tvSink);

			// Determine the wrapper field name
			string fieldName;
			if (tagToField !is null && tagValue in tagToField)
				fieldName = tagToField[tagValue];
			else
				fieldName = tagValue;

			// Remove the tag field
			store._object.remove(tagField);

			// Emit: {"fieldName": {remaining fields...}} with recursive filtering
			auto self = &this;
			TaggedWrapperObjectReader!(typeof(self)) wor = {
				fieldName: fieldName, inner: &store, config: self
			};
			downstream.handle(Map!(typeof(wor))(wor));
		}
		else
			downstream.handle(v);
	}
}

/// Replays a buffered SO object through a filter, so nested objects get processed.
private struct SOFilteredObjectReader(Config)
{
	alias SO = SerializedObject!(immutable(char));
	SO* obj;
	Config config;

	void opCall(Sink)(Sink sink)
	{
		import ae.utils.serialization.serialization : Field;

		foreach (name, ref value; obj._object)
		{
			auto nameEmitter = stringEmitter(name);
			SOFilteredValueReader!(Config) vr = {value: &value, config: config};
			sink.handle(Field!(typeof(nameEmitter), typeof(vr))(nameEmitter, vr));
		}
	}
}

/// Replays a single SO value through a filter.
private struct SOFilteredValueReader(Config)
{
	alias SO = SerializedObject!(immutable(char));
	SO* value;
	Config config;

	void opCall(Sink)(Sink sink)
	{
		auto filter = config.makeFilter(sink);
		value.read(&filter);
	}
}

/// Reader that emits {"fieldName": {filtered inner object}} for the tag case.
private struct TaggedWrapperObjectReader(Config)
{
	alias SO = SerializedObject!(immutable(char));
	string fieldName;
	SO* inner;
	Config config;

	void opCall(Sink)(Sink sink)
	{
		import ae.utils.serialization.serialization : Field;

		auto nameEmitter = stringEmitter(fieldName);
		TaggedWrapperValueReader!(Config) vr = {obj: inner, config: config};
		sink.handle(Field!(typeof(nameEmitter), typeof(vr))(nameEmitter, vr));
	}
}

/// Replays a buffered SO object as a value (emits Map) with values filtered.
private struct TaggedWrapperValueReader(Config)
{
	alias SO = SerializedObject!(immutable(char));
	SO* obj;
	Config config;

	void opCall(Sink)(Sink sink)
	{
		import ae.utils.serialization.serialization : Map;

		SOFilteredObjectReader!(Config) fr = {obj: obj, config: config};
		sink.handle(Map!(typeof(fr))(fr));
	}
}

auto taggedUnionFilter(Sink)(Sink sink, string tagField, const(string[string]) tagToField = null)
{
	return TaggedUnionFilter!Sink(sink, tagField, tagToField);
}

// =========================================================================
// Filter: EnvelopeUnwrapFilter
// =========================================================================

/// Reverse of `TaggedUnionFilter`: intercepts objects that look like
/// `{"image":{"url":"..."}}` and rewrites to `{"type":"image","url":"..."}`.
/// Used for D struct -> JSON serialization of tagged unions.
struct EnvelopeUnwrapFilter(Sink)
{
	alias SO = SerializedObject!(immutable(char));

	Sink downstream;
	string tagField;
	/// Variant field names to recognize. If a single-field object has one of
	/// these as its key, it's treated as a tagged union envelope.
	const(string)[] variantFields;

	auto makeFilter(S)(S sink)
	{
		return EnvelopeUnwrapFilter!S(sink, tagField, variantFields);
	}

	void handle(V)(V v)
	{
		import ae.utils.serialization.serialization : isProtocolArray, isProtocolMap,
			rewrapArray, String;

		static if (isProtocolArray!V)
		{
			auto self = &this;
			alias R = typeof(v.reader);
			FilteredArrayReader!(R, typeof(self)) wr = {originalReader: v.reader, config: self};
			downstream.handle(rewrapArray(v, wr));
		}
		else static if (isProtocolMap!V)
		{
			// Buffer to inspect
			SO store;
			store.handle(v);
			assert(store.type == SO.Type.object);

			// Find which key is a variant field with an object value
			string activeVariant = null;
			foreach (f; variantFields)
			{
				if (auto p = f in store._object)
				{
					if (p.type == SO.Type.object)
					{
						activeVariant = f;
						break;
					}
				}
			}

			if (activeVariant is null)
			{
				// Not an envelope — pass through
				store.read(this.downstream);
				return;
			}

			// Unwrap: merge the inner object's fields with the tag field
			auto inner = &store._object[activeVariant];
			assert(inner.type == SO.Type.object);

			// Add tag field to inner
			SO tagVal;
			tagVal.handle(String!(string)(activeVariant));
			inner._object[tagField] = tagVal;

			// Remove the variant field from outer, replace with inner's fields
			store._object.remove(activeVariant);
			foreach (k, ref vv; inner._object)
				store._object[k] = vv;

			store.read(this.downstream);
		}
		else
			downstream.handle(v);
	}
}

auto envelopeUnwrapFilter(Sink)(Sink sink, string tagField, const(string)[] variantFields)
{
	return EnvelopeUnwrapFilter!Sink(sink, tagField, variantFields);
}

// =========================================================================
// Filter: ObjectTransformFilter
// =========================================================================

/// Filter that buffers objects into `SerializedObject`, calls a user-provided
/// transform function, then replays the result. Nested objects are also
/// recursively transformed.
struct ObjectTransformFilter(Sink, Fn)
{
	alias SO = SerializedObject!(immutable(char));

	Sink downstream;
	Fn transform;

	auto makeFilter(S)(S sink)
	{
		return ObjectTransformFilter!(S, Fn)(sink, transform);
	}

	void handle(V)(V v)
	{
		import ae.utils.serialization.serialization : isProtocolArray, isProtocolMap,
			rewrapArray, Map;

		static if (isProtocolArray!V)
		{
			auto self = &this;
			alias R = typeof(v.reader);
			FilteredArrayReader!(R, typeof(self)) wr = {originalReader: v.reader, config: self};
			downstream.handle(rewrapArray(v, wr));
		}
		else static if (isProtocolMap!V)
		{
			SO store;
			store.handle(v);

			SO result = transform(store);

			// Replay the transformed result with recursive filtering on nested values.
			if (result.type == SO.Type.object)
			{
				auto self = &this;
				SOFilteredObjectReader!(typeof(self)) fr = {obj: &result, config: self};
				downstream.handle(Map!(typeof(fr))(fr));
			}
			else
			{
				// Transform returned a non-object — replay directly
				result.read(this.downstream);
			}
		}
		else
			downstream.handle(v);
	}
}

auto objectTransformFilter(Fn, Sink)(Sink sink, Fn transform)
{
	return ObjectTransformFilter!(Sink, Fn)(sink, transform);
}

// =========================================================================
// Unit tests
// =========================================================================


// --- RecursionLimiter tests ---

debug(ae_unittest) unittest
{
	static struct S { int a; string b; }
	S original = S(42, "hello");
	S result;
	auto sink = deserializer(&result);
	auto filter = recursionLimiter(sink, 2);
	Serializer.Impl!Object.read(&filter, original);
	assert(result.a == 42);
	assert(result.b == "hello");
}

debug(ae_unittest) unittest
{
	static struct Inner { int x; }
	static struct Outer { int a; Inner inner; }

	Outer original = Outer(42, Inner(7));

	import std.typecons : Nullable;
	static struct FlatOuter { int a; Nullable!int inner; }

	FlatOuter result;
	auto sink = deserializer(&result);
	auto filter = recursionLimiter(sink, 1);
	Serializer.Impl!Object.read(&filter, original);

	assert(result.a == 42);
	assert(result.inner.isNull);
}

debug(ae_unittest) unittest
{
	import std.typecons : Nullable;

	int[][] original = [[1, 2], [3, 4]];

	Nullable!(int)[] result;
	auto sink = deserializer(&result);
	auto filter = recursionLimiter(sink, 1);
	Serializer.Impl!Object.read(&filter, original);

	assert(result.length == 2);
	assert(result[0].isNull);
	assert(result[1].isNull);
}

// --- FieldRenamer tests ---

debug(ae_unittest) unittest
{
	static struct Input { string first_name; string last_name; int age; }
	Input original = Input("John", "Doe", 30);

	string[string] result;
	auto sink = deserializer(&result);
	auto filter = fieldRenamer(sink,
		["first_name", "last_name"],
		["firstName", "lastName"]);
	Serializer.Impl!Object.read(&filter, original);

	assert(result["firstName"] == "John");
	assert(result["lastName"] == "Doe");
	assert(result["age"] == "30");
	assert("first_name" !in result);
	assert("last_name" !in result);
}

debug(ae_unittest) unittest
{
	static struct Address { string street_name; string city; }
	static struct Person { string first_name; Address address; }

	Person original = Person("John", Address("Main St", "NYC"));

	@IgnoreUnknown static struct FlatPerson { string firstName; }

	FlatPerson result;
	auto sink = deserializer(&result);
	auto filter = fieldRenamer(sink,
		["first_name", "street_name"],
		["firstName", "streetName"]);
	Serializer.Impl!Object.read(&filter, original);

	assert(result.firstName == "John");
}

// --- TypeCoercer tests ---

debug(ae_unittest) unittest
{
	static struct Input { int a; string name; }
	static struct Output { string a; string name; }

	Input original = Input(42, "hello");
	Output result;
	auto sink = deserializer(&result);
	auto filter = typeCoercer(sink, false, false, true);
	Serializer.Impl!Object.read(&filter, original);

	assert(result.a == "42");
	assert(result.name == "hello");
}

debug(ae_unittest) unittest
{
	static struct Input { string value; string name; }
	static struct Output { int value; string name; }

	Input original = Input("42", "hello");
	Output result;
	auto sink = deserializer(&result);
	auto filter = typeCoercer(sink, true, false, false);
	Serializer.Impl!Object.read(&filter, original);

	assert(result.value == 42);
	assert(result.name == "hello");
}

debug(ae_unittest) unittest
{
	static struct Input { string flag; string name; }
	static struct Output { bool flag; string name; }

	Input original = Input("true", "hello");
	Output result;
	auto sink = deserializer(&result);
	auto filter = typeCoercer(sink, false, true, false);
	Serializer.Impl!Object.read(&filter, original);

	assert(result.flag == true);
	assert(result.name == "hello");
}

debug(ae_unittest) unittest
{
	int[] intOriginal = [1, 2, 3];
	string[] result;
	auto sink = deserializer(&result);
	auto filter = typeCoercer(sink, false, false, true);
	Serializer.Impl!Object.read(&filter, intOriginal);

	assert(result == ["1", "2", "3"]);
}

// --- FieldFilter tests ---

debug(ae_unittest) unittest
{
	static struct Input { string name; int age; string secret; string role; }
	@IgnoreUnknown static struct Output { string name; int age; }

	Input original = Input("John", 30, "s3cr3t", "admin");
	Output result;
	auto sink = deserializer(&result);
	auto filter = fieldFilter(sink, ["name", "age"]);
	Serializer.Impl!Object.read(&filter, original);

	assert(result.name == "John");
	assert(result.age == 30);
}

debug(ae_unittest) unittest
{
	static struct Input { string name; int age; string secret; }

	Input original = Input("John", 30, "hidden");
	string[string] result;
	auto sink = deserializer(&result);
	auto filter = fieldFilter(sink, ["name", "age"]);
	Serializer.Impl!Object.read(&filter, original);

	assert("name" in result);
	assert("age" in result);
	assert("secret" !in result);
	assert(result.length == 2);
}

debug(ae_unittest) unittest
{
	static struct Inner { string x; string y; string z; }
	static struct Outer { string a; Inner inner; string b; }
	@IgnoreUnknown static struct OuterResult { string a; }

	Outer original = Outer("keep", Inner("1", "2", "3"), "drop");

	OuterResult result;
	auto sink = deserializer(&result);
	auto filter = fieldFilter(sink, ["a", "x", "inner"]);
	Serializer.Impl!Object.read(&filter, original);

	assert(result.a == "keep");
}

debug(ae_unittest) unittest
{
	static struct Input { string name; int age; }

	Input original = Input("John", 30);
	string[string] result;
	auto sink = deserializer(&result);
	auto filter = fieldFilter(sink, []);
	Serializer.Impl!Object.read(&filter, original);

	assert(result.length == 0);
}

// --- Composition tests ---

debug(ae_unittest) unittest
{
	static struct Input { string first_name; string age; }
	@IgnoreUnknown static struct Output { string firstName; int age; }

	Input original = Input("John", "30");

	Output result;
	auto sink = deserializer(&result);
	auto coercer = typeCoercer(sink, true, false, false);
	auto renamer = fieldRenamer(&coercer,
		["first_name"],
		["firstName"]);
	Serializer.Impl!Object.read(&renamer, original);

	assert(result.firstName == "John");
	assert(result.age == 30);
}

debug(ae_unittest) unittest
{
	static struct Input { string first_name; int age; string secret; }

	Input original = Input("John", 30, "hidden");

	string[string] result;
	auto sink = deserializer(&result);
	auto renamer = fieldRenamer(sink,
		["first_name"],
		["firstName"]);
	auto filter = fieldFilter(&renamer, ["first_name", "age"]);
	Serializer.Impl!Object.read(&filter, original);

	assert("firstName" in result);
	assert("age" in result);
	assert("secret" !in result);
	assert(result.length == 2);
}

debug(ae_unittest) unittest
{
	static struct Input { string user_name; string age; string secret; }
	@IgnoreUnknown static struct Output { string userName; int age; }

	Input original = Input("John", "30", "hidden");

	Output result;
	auto sink = deserializer(&result);
	auto coercer = typeCoercer(sink, true, false, false);
	auto renamer = fieldRenamer(&coercer, ["user_name"], ["userName"]);
	auto filter = fieldFilter(&renamer, ["user_name", "age"]);
	Serializer.Impl!Object.read(&filter, original);

	assert(result.userName == "John");
	assert(result.age == 30);
}

// --- TaggedUnionFilter tests ---

private
{
	struct ImagePayload
	{
		string url;
		int width;
	}

	struct TextPayload
	{
		string content;
	}

	@IgnoreUnknown struct Envelope
	{
		@Optional ImagePayload image;
		@Optional TextPayload text;
	}

	struct TaggedWrapper
	{
		string id;
		Envelope payload;
	}

	struct TaggedWrapperArray
	{
		Envelope[] items;
	}
}

// Tag first — basic image payload
debug(ae_unittest) unittest
{
	import ae.utils.serialization.json : JsonParser;

	auto json = `{"type":"image","url":"pic.jpg","width":800}`;
	auto parser = JsonParser!(immutable(char))(json, 0);

	Envelope result;
	auto sink = deserializer(&result);
	auto filter = taggedUnionFilter(sink, "type");
	parser.read(&filter);

	assert(result.image.url == "pic.jpg");
	assert(result.image.width == 800);
	assert(result.text == TextPayload.init);
}

// Tag last
debug(ae_unittest) unittest
{
	import ae.utils.serialization.json : JsonParser;

	auto json = `{"url":"pic.jpg","width":800,"type":"image"}`;
	auto parser = JsonParser!(immutable(char))(json, 0);

	Envelope result;
	auto sink = deserializer(&result);
	auto filter = taggedUnionFilter(sink, "type");
	parser.read(&filter);

	assert(result.image.url == "pic.jpg");
	assert(result.image.width == 800);
}

// Text variant
debug(ae_unittest) unittest
{
	import ae.utils.serialization.json : JsonParser;

	auto json = `{"type":"text","content":"hello world"}`;
	auto parser = JsonParser!(immutable(char))(json, 0);

	Envelope result;
	auto sink = deserializer(&result);
	auto filter = taggedUnionFilter(sink, "type");
	parser.read(&filter);

	assert(result.text.content == "hello world");
	assert(result.image == ImagePayload.init);
}

// Nested tagged union (inside another struct)
debug(ae_unittest) unittest
{
	import ae.utils.serialization.json : JsonParser;

	auto json = `{"id":"msg1","payload":{"type":"image","url":"pic.jpg","width":800}}`;
	auto parser = JsonParser!(immutable(char))(json, 0);

	TaggedWrapper result;
	auto sink = deserializer(&result);
	auto filter = taggedUnionFilter(sink, "type");
	parser.read(&filter);

	assert(result.id == "msg1");
	assert(result.payload.image.url == "pic.jpg");
	assert(result.payload.image.width == 800);
}

// Array of tagged unions
debug(ae_unittest) unittest
{
	import ae.utils.serialization.json : JsonParser;

	auto json = `{"items":[{"type":"image","url":"pic.jpg","width":800},{"type":"text","content":"hello"}]}`;
	auto parser = JsonParser!(immutable(char))(json, 0);

	TaggedWrapperArray result;
	auto sink = deserializer(&result);
	auto filter = taggedUnionFilter(sink, "type");
	parser.read(&filter);

	assert(result.items.length == 2);
	assert(result.items[0].image.url == "pic.jpg");
	assert(result.items[0].image.width == 800);
	assert(result.items[1].text.content == "hello");
}

// Tag value -> field name mapping
debug(ae_unittest) unittest
{
	import ae.utils.serialization.json : JsonParser;

	auto json = `{"kind":"img","url":"pic.jpg","width":800}`;
	auto parser = JsonParser!(immutable(char))(json, 0);

	Envelope result;
	auto sink = deserializer(&result);
	auto filter = taggedUnionFilter(sink, "kind", ["img": "image", "txt": "text"]);
	parser.read(&filter);

	assert(result.image.url == "pic.jpg");
	assert(result.image.width == 800);
}

// Top-level array of tagged unions
debug(ae_unittest) unittest
{
	import ae.utils.serialization.json : JsonParser;

	auto json = `[{"type":"image","url":"pic.jpg","width":800},{"type":"text","content":"hello"}]`;
	auto parser = JsonParser!(immutable(char))(json, 0);

	Envelope[] result;
	auto sink = deserializer(&result);
	auto filter = taggedUnionFilter(sink, "type");
	parser.read(&filter);

	assert(result.length == 2);
	assert(result[0].image.url == "pic.jpg");
	assert(result[1].text.content == "hello");
}

// --- EnvelopeUnwrapFilter tests ---

// D struct -> EnvelopeUnwrapFilter -> JSON (serialization)
debug(ae_unittest) unittest
{
	import ae.utils.serialization.json : JsonWriter, jsonParse;
	import ae.utils.textout : StringBuilder;

	Envelope original;
	original.image = ImagePayload("pic.jpg", 800);

	JsonWriter!StringBuilder writer;
	auto filter = envelopeUnwrapFilter(&writer, "type", ["image", "text"]);
	Serializer.Impl!Object.read(&filter, original);
	auto json = writer.get();

	auto parsed = jsonParse!(string[string])(json);
	assert(parsed["type"] == "image", parsed.get("type", "(missing)"));
	assert(parsed["url"] == "pic.jpg");
	assert(parsed["width"] == "800");
	assert("image" !in parsed);
}

// Round-trip: JSON -> TaggedUnionFilter -> D struct -> EnvelopeUnwrapFilter -> JSON
debug(ae_unittest) unittest
{
	import ae.utils.serialization.json : JsonParser, JsonWriter, jsonParse;
	import ae.utils.textout : StringBuilder;

	// Deserialize
	auto jsonIn = `{"type":"text","content":"hello world"}`;
	auto parser = JsonParser!(immutable(char))(jsonIn, 0);

	Envelope result;
	auto sink = deserializer(&result);
	auto readFilter = taggedUnionFilter(sink, "type");
	parser.read(&readFilter);

	assert(result.text.content == "hello world");

	// Serialize back
	JsonWriter!StringBuilder writer;
	auto writeFilter = envelopeUnwrapFilter(&writer, "type", ["image", "text"]);
	Serializer.Impl!Object.read(&writeFilter, result);
	auto jsonOut = writer.get();

	auto parsed = jsonParse!(string[string])(jsonOut);
	assert(parsed["type"] == "text");
	assert(parsed["content"] == "hello world");
}

// Round-trip with image variant, full cycle
debug(ae_unittest) unittest
{
	import ae.utils.serialization.json : JsonParser, JsonWriter, jsonParse;
	import ae.utils.textout : StringBuilder;

	auto jsonIn = `{"type":"image","url":"pic.jpg","width":800}`;
	auto parser = JsonParser!(immutable(char))(jsonIn, 0);

	Envelope result;
	auto sink = deserializer(&result);
	auto readFilter = taggedUnionFilter(sink, "type");
	parser.read(&readFilter);

	assert(result.image.url == "pic.jpg");
	assert(result.image.width == 800);

	// Serialize
	JsonWriter!StringBuilder writer;
	auto writeFilter = envelopeUnwrapFilter(&writer, "type", ["image", "text"]);
	Serializer.Impl!Object.read(&writeFilter, result);
	auto jsonOut = writer.get();

	// Re-deserialize
	auto parser2 = JsonParser!(immutable(char))(jsonOut, 0);
	Envelope result2;
	auto sink2 = deserializer(&result2);
	auto readFilter2 = taggedUnionFilter(sink2, "type");
	parser2.read(&readFilter2);

	assert(result2.image.url == "pic.jpg");
	assert(result2.image.width == 800);
}

// --- ObjectTransformFilter tests ---

// Generic transform — manual envelope wrapping
debug(ae_unittest) unittest
{
	import ae.utils.serialization.json : JsonParser;
	alias SO = SerializedObject!(immutable(char));

	auto json = `{"type":"image","url":"pic.jpg","width":800}`;
	auto parser = JsonParser!(immutable(char))(json, 0);

	Envelope result;
	auto sink = deserializer(&result);
	auto filter = objectTransformFilter(sink, (SO obj) {
		auto tagSO = "type" in obj._object;
		if (tagSO is null)
			return obj;
		string tagValue;
		auto tvSink = deserializer(&tagValue);
		tagSO.read(tvSink);

		SO inner;
		inner.type = SO.Type.object;
		foreach (k, ref v; obj._object)
			if (k != "type")
				inner._object[k] = v;

		SO wrapper;
		wrapper.type = SO.Type.object;
		wrapper._object[tagValue] = inner;
		return wrapper;
	});
	parser.read(&filter);

	assert(result.image.url == "pic.jpg");
	assert(result.image.width == 800);
}

// ObjectTransformFilter with nested tagged unions
debug(ae_unittest) unittest
{
	import ae.utils.serialization.json : JsonParser;
	alias SO = SerializedObject!(immutable(char));

	auto json = `{"id":"msg1","payload":{"type":"text","content":"hello"}}`;
	auto parser = JsonParser!(immutable(char))(json, 0);

	TaggedWrapper result;
	auto sink = deserializer(&result);
	auto filter = objectTransformFilter(sink, (SO obj) {
		auto tagSO = "type" in obj._object;
		if (tagSO is null)
			return obj;

		string tagValue;
		auto tvSink = deserializer(&tagValue);
		tagSO.read(tvSink);

		SO inner;
		inner.type = SO.Type.object;
		foreach (k, ref v; obj._object)
			if (k != "type")
				inner._object[k] = v;

		SO wrapper;
		wrapper.type = SO.Type.object;
		wrapper._object[tagValue] = inner;
		return wrapper;
	});
	parser.read(&filter);

	assert(result.id == "msg1");
	assert(result.payload.text.content == "hello");
}

// ObjectTransformFilter with integer tags
debug(ae_unittest) unittest
{
	import ae.utils.serialization.json : JsonParser;
	alias SO = SerializedObject!(immutable(char));

	auto json = `{"type":1,"url":"pic.jpg","width":800}`;
	auto parser = JsonParser!(immutable(char))(json, 0);

	Envelope result;
	auto sink = deserializer(&result);
	auto filter = objectTransformFilter(sink, (SO obj) {
		auto tagSO = "type" in obj._object;
		if (tagSO is null)
			return obj;
		string tagStr;
		auto tvSink = deserializer(&tagStr);
		tagSO.read(tvSink);

		string fieldName;
		if (tagStr == "1") fieldName = "image";
		else if (tagStr == "2") fieldName = "text";
		else return obj;

		SO inner;
		inner.type = SO.Type.object;
		foreach (k, ref v; obj._object)
			if (k != "type")
				inner._object[k] = v;
		SO wrapper;
		wrapper.type = SO.Type.object;
		wrapper._object[fieldName] = inner;
		return wrapper;
	});
	parser.read(&filter);

	assert(result.image.url == "pic.jpg");
	assert(result.image.width == 800);
}
