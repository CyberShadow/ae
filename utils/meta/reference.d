/**
 * Reference type abstraction
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

module ae.utils.meta.reference;

import std.traits;

/// typeof(new T) - what we use to refer to an allocated instance
template RefType(T)
{
	static if (is(T == class))
		alias T RefType;
	else
		alias T* RefType;
}

/// Reverse of RefType
template FromRefType(R)
{
	static if (is(T == class))
		alias T FromRefType;
	else
	{
		static assert(is(typeof(*(R.init))), R.stringof ~ " is not dereferenceable");
		alias typeof(*(R.init)) FromRefType;
	}
}

/// A type that can be used to store instances of T.
/// A struct with T's instance size if T is a class, T itself otherwise.
template StorageType(T)
{
	static if (is(T == class))
	{
		//alias void*[(__traits(classInstanceSize, T) + size_t.sizeof-1) / size_t.sizeof] StorageType;
		//static assert(__traits(classInstanceSize, T) % size_t.sizeof == 0, "TODO"); // union with a pointer

		// Use a struct to allow new-ing the type (you can't new a static array directly)
		struct StorageType
		{
			void*[(__traits(classInstanceSize, T) + size_t.sizeof-1) / size_t.sizeof] data;
		}
	}
	else
		alias T StorageType;
}

// ************************************************************************

/// Is T a reference type (a pointer or a class)?
template isReference(T)
{
	enum isReference = isPointer!T || is(T==class);
}

/// Allow passing a constructed object by reference, without redundant indirection.
/// The intended use is with types which support the dot operator
/// (a non-null class, a struct, or a non-null struct pointer).
T* reference(T)(ref T v)
	if (!isReference!T)
{
	return &v;
}

/// ditto
T reference(T)(T v)
	if (isReference!T)
{
	return v;
}

/// Reverse of "reference".
ref typeof(*T.init) dereference(T)(T v)
	if (!isReference!T)
{
	return *v;
}

/// ditto
T dereference(T)(T v)
	if (isReference!T)
{
	return v;
}

unittest
{
	Object o = new Object;
	assert(o.reference is o);
	assert(o.dereference is o);

	static struct S {}
	S s;
	auto p = s.reference;
	assert(p is &s);
	assert(p.reference is p);
}
