/**
 * Deserialization into an existing D variable.
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

module ae.utils.sd.serialization.deserializer;

import std.algorithm.comparison;
import std.algorithm.iteration;
import std.traits : Unqual;

/// Sink for handling array items up to a given length
private struct MaxLengthArrayHandler(
	/// Array element type
	T,
	/// Maximum number of elements to receive and store
	size_t maxLength,
	/// This will be called if the buffer is exceeded, with the buffer so far and the overflow
	alias onOverflow,
)
{
private:
	T[maxLength] buf;
	size_t pos;

public: // Handler interface
	enum canHandleSlice(U) = is(Unqual!U == T);
	void handleSlice(U)(U[] slice)
	if (canHandleSlice!U)
	{
		auto end = pos + slice.length;
		if (end > maxLength)
			onOverflow(data, slice);
		buf[pos .. end] = slice[];
		pos = end;
	}

	private struct ElementHandler
	{
		MaxLengthArrayHandler* arrayHandler;

		enum bool canHandleValue(U) = is(Unqual!U == T);
		void handleValue(U)(auto ref U value)
		if (canHandleValue!U)
		{
			if (arrayHandler.pos == maxLength)
				onOverflow(arrayHandler.data, (&value)[0..1]);
			arrayHandler.buf[arrayHandler.pos++] = value;
		}
	}

	void handleElement(Reader)(Reader reader)
	{
		reader.read(ElementHandler(&this));
	}

	void handleEnd() {}

public: // Caller API
	/// Get elements received so far
	T[] data() { return buf[0 .. pos]; }
}

/// Sink for deserializing data into a variable of type `T`.
struct Deserializer(T)
{
	pragma(msg, "Deserializer!" ~ T.stringof);
	T* target;

	// Implements the top-level context handler

	enum bool canHandleValue(U) = is(U : T);
	void handleValue(U)(auto ref U value)
	if (canHandleValue!U)
	{
		*target = value;
	}

	static if (is(T : real))
	{
		void handleNumeric(Reader)(Reader reader)
		{
			// The longest number we can reasonably expect in the
			// input which would still reasonably be parsed into a D
			// numeric type.  Integers already are bounded by a hard
			// length limit, however, floating-point numbers can occur
			// in inputs with arbitrary precision. Go with 64 total
			// characters, which is more than double the amount of
			// information that could be contained in the biggest D
			// numeric type when expressed as a string.
			enum maxLength = 64;
			alias NumericArrayHandler = MaxLengthArrayHandler!(
				char,
				maxLength,
				(in char[] data, in char[] overflow) { throw new Exception("Numeric value is too long"); },
			);

			NumericArrayHandler handler;
			reader.read(&handler);

			import std.conv : to;
			*target = handler.data.to!T;
		}
	}

	static if (is(T == struct))
	{
		static immutable string[] fieldNames = {
			string[] result;
			foreach (i, field; T.init.tupleof)
				result ~= __traits(identifier, T.tupleof[i]);
			return result;
		}();

		enum maxLength = fieldNames.map!((string name) => name.length).fold!max(size_t(0));

		struct FieldNameHandler
		{
			alias FieldNameArrayHandler = MaxLengthArrayHandler!(
				char, maxLength,
				(in char[] data, in char[] overflow) { throw new Exception("No field with prefix " ~ cast(string)data ~ cast(string)overflow); },
			);
			FieldNameArrayHandler arrayHandler;

			void handleArray(Reader)(Reader reader)
			{
				reader.read(&arrayHandler);
			}
		}

		struct FieldHandler
		{
			T* target;

			FieldNameHandler nameHandler;

			void handlePairKey(Reader)(Reader reader)
			{
				reader.read(&nameHandler);
			}

			void handlePairValue(Reader)(Reader reader)
			{
				auto name = nameHandler.arrayHandler.data;
				switch (name)
				{
					static foreach (i, fieldName; fieldNames)
						case fieldName:
							return reader.read(Deserializer!(typeof(T.tupleof[i]))(&target.tupleof[i]));
					default:
						throw new Exception("No field with prefix " ~ name.idup);
				}
			}
		}

		struct StructHandler
		{
			T* target;

			void handlePair(Reader)(Reader reader)
			{
				reader.read(FieldHandler(target));
			}

			void handleEnd() {}
		}

		void handleMap(Reader)(Reader reader)
		{
			reader.read(StructHandler(target));
		}
	}
	else
	static if (is(T E : E[]))
	{
		struct ArrayHandler
		{
			T* target;

			// TODO handleSlice

			void handleElement(Reader)(Reader reader)
			{
				target.length++;
				alias U = Unqual!E;
				reader.read(.Deserializer!U(cast(U*)&(*target)[$ - 1]));
			}

			void handleEnd() {}
		}

		void handleArray(Reader)(Reader reader)
		{
			reader.read(ArrayHandler(target));
		}
	}
}

/// Accept a data source and absorb received data into the given variable.
void deserializeInto(Source, T)(Source source, ref T target)
{
	source.read(Deserializer!T(&target));
}

/// Accept a data source and absorb received data into a new variable of type `T`.
T deserializeNew(T, Source)(Source source)
{
	T target;
	source.read(Deserializer!T(&target));
	return target;
}
