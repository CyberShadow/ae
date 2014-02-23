/**
 * Wrappers for automatically loading/saving data.
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

module ae.sys.persistence;

import std.traits;

enum FlushPolicy
{
	none,
	manual,
	atScopeExit,
	atThreadExit,
	// TODO: immediate flushing. Could work only with values without mutable indirections.
	// TODO: this can actually be a bitmask
}

bool delayed(FlushPolicy policy) { return policy > FlushPolicy.manual; }

struct None {}

/// Cache values in-memory, and automatically load/save them as needed via the specified functions.
/// Actual loading/saving is done via alias functions.
/// KeyGetter may return .init (of its return type) if the resource does not yet exist,
/// but once it returns non-.init it may not return .init again.
/// A bool key can be used to load a resource from disk only once (lazily),
/// as is currently done with LoadPolicy.once.
/// Delayed flush policies require a bool key, to avoid mid-air collisions.
mixin template CacheCore(alias DataGetter, alias KeyGetter, alias DataPutter = None, FlushPolicy flushPolicy = FlushPolicy.none)
{
	import std.traits;
	import ae.sys.memory;

	alias _CacheCore_Data = ReturnType!DataGetter;
	alias _CacheCore_Key  = ReturnType!KeyGetter;

	enum _CacheCore_readOnly = flushPolicy == FlushPolicy.none;

	_CacheCore_Data cachedData;
	_CacheCore_Key cachedDataKey;

	void _CacheCore_update()
	{
		auto newKey = KeyGetter();

		// No going back to Key.init after returning non-.init
		assert(cachedDataKey == _CacheCore_Key.init || newKey != _CacheCore_Key.init);

		if (newKey != cachedDataKey)
		{
			static if (flushPolicy == FlushPolicy.atThreadExit)
			{
				if (cachedDataKey == _CacheCore_Key.init) // first load
					_CacheCore_registerFlush();
			}
			cachedData = DataGetter();
			cachedDataKey = newKey;
		}
	}

	static if (_CacheCore_readOnly)
		@property     auto _CacheCore_data() { _CacheCore_update(); return cast(immutable)cachedData; }
	else
		@property ref auto _CacheCore_data() { _CacheCore_update(); return                cachedData; }

	static if (!_CacheCore_readOnly)
	{
		void save(bool exiting=false)()
		{
			if (cachedDataKey != _CacheCore_Key.init || cachedData != _CacheCore_Data.init)
			{
				DataPutter(cachedData);
				static if (!exiting)
					cachedDataKey = KeyGetter();
			}
		}

		static if (flushPolicy.delayed())
		{
			// A bool key implies that data will be loaded only once (lazy loading).
			static assert(is(_CacheCore_Key==bool), "Delayed flush with automatic reload allows mid-air collisions");
		}

		static if (flushPolicy == FlushPolicy.atScopeExit)
		{
			~this()
			{
				save!true();
			}
		}

		static if (flushPolicy == FlushPolicy.atThreadExit)
		{
			void _CacheCore_registerFlush()
			{
				// https://d.puremagic.com/issues/show_bug.cgi?id=12038
				assert(!onStack(cast(void*)&this));
				_CacheCore_pending ~= &this;
			}

			static typeof(this)*[] _CacheCore_pending;

			static ~this()
			{
				foreach (p; _CacheCore_pending)
					p.save!true();
			}
		}
	}
}

/// FileCache policy for when to (re)load data from disk.
enum LoadPolicy
{
	automatic, /// "onModification" for FlushPolicy.none/manual, "once" for delayed
	once,
	onModification,
}

struct FileCache(alias DataGetter, alias DataPutter = None, FlushPolicy flushPolicy = FlushPolicy.none, LoadPolicy loadPolicy = LoadPolicy.automatic)
{
	string fileName;

	static if (loadPolicy == LoadPolicy.automatic)
		enum _FileCache_loadPolicy = flushPolicy.delayed() ? LoadPolicy.once : LoadPolicy.onModification;
	else
		enum _FileCache_loadPolicy = loadPolicy;

	ReturnType!DataGetter _FileCache_dataGetter()
	{
		import std.file : exists;
		assert(fileName, "Filename not set");
		static if (flushPolicy == FlushPolicy.none)
			return DataGetter(fileName); // no existence checks if we are never saving it ourselves
		else
		if (fileName.exists)
			return DataGetter(fileName);
		else
			return ReturnType!DataGetter.init;
	}

	static if (is(DataPutter == None))
		alias _FileCache_dataPutter = None;
	else
		void _FileCache_dataPutter(T)(T t)
		{
			assert(fileName, "Filename not set");
			DataPutter(fileName, t);
		}

	static if (_FileCache_loadPolicy == LoadPolicy.onModification)
	{
		import std.datetime : SysTime;

		SysTime _FileCache_keyGetter()
		{
			import std.file  : exists, timeLastModified;

			SysTime result;
			if (fileName.exists)
				result = fileName.timeLastModified();
			return result;
		}
	}
	else
	{
		bool _FileCache_keyGetter() { return true; }
	}

	mixin CacheCore!(_FileCache_dataGetter, _FileCache_keyGetter, _FileCache_dataPutter, flushPolicy);

	alias _CacheCore_data this;
}

// Sleep between writes to make sure timestamps differ
version(unittest) import core.thread;

unittest
{
	import std.file;

	enum FN = "test.txt";
	auto cachedData = FileCache!read(FN);

	std.file.write(FN, "One");
	scope(exit) remove(FN);
	assert(cachedData == "One");

	Thread.sleep(10.msecs);
	std.file.write(FN, "Two");
	assert(cachedData == "Two");
	auto mtime = FN.timeLastModified();

	Thread.sleep(10.msecs);
	std.file.write(FN, "Three");
	FN.setTimes(mtime, mtime);
	assert(cachedData == "Two");
}

// ****************************************************************************

template JsonFileCache(T, FlushPolicy flushPolicy = FlushPolicy.none)
{
	import std.file;
	import ae.utils.json;

	static T getJson(T)(string fileName)
	{
		return fileName.readText.jsonParse!T;
	}

	static void putJson(T)(string fileName, in T t)
	{
		std.file.write(fileName, t.toJson());
	}

	alias JsonFileCache = FileCache!(getJson!T, putJson!T, flushPolicy);
}

unittest
{
	import std.file;

	enum FN = "test1.json";
	std.file.write(FN, "{}");
	scope(exit) remove(FN);

	auto cache = JsonFileCache!(string[string])(FN);
	assert(cache.length == 0);
}

unittest
{
	import std.file;

	enum FN = "test2.json";
	scope(exit) if (FN.exists) remove(FN);

	auto cache = JsonFileCache!(string[string], FlushPolicy.manual)(FN);
	assert(cache.length == 0);
	cache["foo"] = "bar";
	cache.save();

	auto cache2 = JsonFileCache!(string[string])(FN);
	assert(cache2["foo"] == "bar");
}

unittest
{
	import std.file;

	enum FN = "test3.json";
	scope(exit) if (FN.exists) remove(FN);

	{
		auto cache = JsonFileCache!(string[string], FlushPolicy.atScopeExit)(FN);
		cache["foo"] = "bar";
	}

	auto cache2 = JsonFileCache!(string[string])(FN);
	assert(cache2["foo"] == "bar");
}

// ****************************************************************************

/// std.functional.memoize variant with automatic persistence
struct PersistentMemoized(alias fun, FlushPolicy flushPolicy = FlushPolicy.atThreadExit)
{
	import std.traits;
	import std.typecons;
	import ae.utils.json;

	alias ReturnType!fun[string] AA;
	private JsonFileCache!(AA, flushPolicy) memo;

	this(string fileName) { memo.fileName = fileName; }

	ReturnType!fun opCall(ParameterTypeTuple!fun args)
	{
		string key;
		static if (args.length==1 && is(typeof(args[0]) : string))
			key = args[0];
		else
			key = toJson(tuple(args));
		auto p = key in memo;
		if (p) return *p;
		auto r = fun(args);
		return memo[key] = r;
	}
}

unittest
{
	import std.file;

	static int value = 42;
	int getValue(int x) { return value; }

	enum FN = "test4.json";
	scope(exit) if (FN.exists) remove(FN);

	{
		auto getValueMemoized = PersistentMemoized!(getValue, FlushPolicy.atScopeExit)(FN);

		assert(getValueMemoized(1) == 42);
		value = 24;
		assert(getValueMemoized(1) == 42);
		assert(getValueMemoized(2) == 24);
	}

	value = 0;

	{
		auto getValueMemoized = PersistentMemoized!(getValue, FlushPolicy.atScopeExit)(FN);
		assert(getValueMemoized(1) == 42);
		assert(getValueMemoized(2) == 24);
	}
}

// ****************************************************************************

/// A string hashset, stored one line per entry.
struct PersistentStringSet
{
	import ae.utils.aa : HashSet;

	static HashSet!string load(string fileName)
	{
		import std.file : readText;
		import std.string : splitLines;

		return HashSet!string(fileName.readText().splitLines());
	}

	static void save(string fileName, HashSet!string data)
	{
		import std.array : join;
		import ae.sys.file : atomicWrite;

		atomicWrite(fileName, data.keys.join("\n"));
	}

	alias Cache = FileCache!(load, save, FlushPolicy.manual);
	Cache cache;

	this(string fileName) { cache = Cache(fileName); }

	auto opIn_r(string key)
	{
		return key in cache;
	}

	void add(string key)
	{
		assert(key !in cache);
		cache.add(key);
		cache.save();
	}

	void remove(string key)
	{
		assert(key in cache);
		cache.remove(key);
		cache.save();
	}

	@property size_t length() { return cache.length; }
}

unittest
{
	import std.file;

	enum FN = "test.txt";
	scope(exit) if (FN.exists) remove(FN);

	{
		auto s = PersistentStringSet(FN);
		assert("foo" !in s);
		assert(s.length == 0);
		s.add("foo");
	}
	{
		auto s = PersistentStringSet(FN);
		assert("foo" in s);
		assert(s.length == 1);
		s.remove("foo");
	}
}
