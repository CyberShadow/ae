/**
 * ae.sys.persistence.core
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

module ae.sys.persistence.core;

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
	static void[] readProxy(string fn) { return std.file.read(fn); }

	enum FN = "test.txt";
	auto cachedData = FileCache!readProxy(FN);

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
