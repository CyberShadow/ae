/**
 * Type serializer and deserializer.
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

module ae.utils.serialization.serialization;

import std.conv;
import std.string;

import ae.utils.meta;

/// Serialization sink which deserializes into a given type.
struct Deserializer(alias source)
{
	static template Impl(alias anchor)
	{
		alias C = source.Char;

		T deserialize(T)()
		{
			T t;
			auto sink = makeSink(&t);
			source.read(&sink);
			return t;
		}

		mixin template SinkHandlers(T)
		{
			template unparseable(string inputType)
			{
				void unparseable(alias reader)()
				{
					throw new Exception("Can't parse %s from %s".format(T.stringof, inputType));
				}
			}

			static if (is(T : C[]))
				void handleStringFragments(alias reader)()
				{
					static struct FragmentSink
					{
						C[] buf;

						void handleStringFragment(CC)(CC[] s)
						{
							buf ~= s;
						}
					}
					FragmentSink sink;
					reader.connect(parent).call(&sink);
					handleValue(sink.buf);
				}
			else
				alias handleStringFragments = unparseable!"string";

			static if (is(T U : U[]))
				void handleArray(alias reader)()
				{
					auto sink = ArraySink!(U, Parent)(parent);
					reader.connect(parent).call(&sink);
					handleValue(sink.arr);
				}
			else
				alias handleArray = unparseable!"array";

			static if (is(T V : V[K], K))
				void handleObject(alias reader)()
				{
					static struct FieldSink
					{
						Parent parent;
						T aa;

						void handleField(alias nameReader, alias valueReader)()
						{
							K k;
							V v;
							nameReader .connect(parent).call(__traits(child, parent, makeSink!K)(&k));
							valueReader.connect(parent).call(__traits(child, parent, makeSink!V)(&v));
							aa[k] = v;
						}
					}

					auto sink = FieldSink(parent);
					reader.connect(parent).call(&sink);
					handleValue(sink.aa);
				}
			else
			static if (is(T == struct))
			{
				void handleObject(alias reader)()
				{
					static struct FieldSink
					{
						Parent parent;
						T s;

						void handleField(alias nameReader, alias valueReader)()
						{
							alias N = const(C)[];
							N name;
							nameReader .connect(parent).call(__traits(child, parent, makeSink!N)(&name));

							// TODO: generate switch
							foreach (i, field; s.tupleof)
							{
								// TODO: Name customization UDAs
								enum fieldName = to!N(__traits(identifier, s.tupleof[i]));
								if (name == fieldName)
								{
									alias V = typeof(field);
									valueReader.connect(parent).call(__traits(child, parent, makeSink!V)(&s.tupleof[i]));
									return;
								}
							}
							throw new Exception("Unknown field %s".format(name));
						}
					}

					auto sink = FieldSink(parent);
					reader.connect(parent).call(&sink);
					handleValue(sink.s);
				}
			}
			else
				alias handleObject = unparseable!"object";

			void handleNull()
			{
				static if (is(typeof({T v = null;})))
				{
					T v = null;
					handleValue(v);
				}
				else
					throw new Exception("Can't parse %s from %s".format(T.stringof, "null"));
			}

			void handleBoolean(bool v)
			{
				static if (is(T : bool))
					handleValue(v);
				else
					throw new Exception("Can't parse %s from %s".format(T.stringof, "boolean"));
			}

			void handleNumeric(C[] v)
			{
				static if (is(typeof(to!T(v))))
				{
					T t = to!T(v);
					handleValue(t);
				}
				else
					throw new Exception("Can't parse %s from %s".format(T.stringof, "numeric"));
			}
		}

		static struct ArraySink(T, Parent)
		{
			Parent parent;
			T[] arr;

			void handleValue(ref T v) { arr ~= v; }

			mixin SinkHandlers!T;
		}

		auto makeSink(T)(T* p)
		{
			alias Parent = RefType!(typeof(this));

			static struct Sink
			{
				T* p;
				Parent parent;

				// TODO: avoid redundant copying for large types
				void handleValue(ref T v) { *p = v; }

				mixin SinkHandlers!T;
			}

			return Sink(p, this.reference);
		}
	}
}
