/**
 * Code to manage cached D component builds.
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

module ae.sys.d.cache;

import std.algorithm;
import std.array;
import std.exception;
import std.file;
import std.format;
import std.path;
import std.range;
import std.string;

import ae.sys.file;
import ae.utils.meta;

interface ICacheHost
{
	/// An optimization helper which provides a linear order in which keys should be optimized
	/// (cache entries most likely to have common data should be adjacent in the list).
	/// Returns: An array of groups, each group is an array of key prefixes.
	/// Params:
	///   key = If non-null, this function will only return keys relevant to the given key.
	string[][] getKeyOrder(string key);

	/// Log a string.
	void log(string s);
}

/// Abstract base class.
abstract class DCache
{
	string cacheDir;
	ICacheHost cacheHost;

	alias cacheHost this;

	this(string cacheDir, ICacheHost cacheHost)
	{
		this.cacheDir = cacheDir;
		this.cacheHost = cacheHost;
	}

	/// Get name of this cache engine.
	abstract @property string name() const;

	/// Get a list of keys for all cached entries.
	abstract string[] getEntries( const);

	/// Check if an entry with the given key exists.
	abstract bool haveEntry(string key) const;

	/// Get the full file listing for the given cache entry.
	/// Forward slashes only.
	abstract string[] listFiles(string key) const;

	/// Add files from a directory.
	/// This operation is destructive: the cache implementation
	/// is allowed to modify the source directory.
	abstract void add(string key, string sourcePath);

	/// Extract a cache entry to a target directory, with a filter for root files/directories.
	abstract void extract(string key, string targetPath, bool delegate(string) pathFilter);

	/// Delete a cache entry.
	abstract void remove(string key);

	/// Close the cache.
	/// Called after all operations are completed
	/// and the cache is no longer immediately needed.
	abstract void finalize();

	/// Optimize the cache (minimize disk space).
	/// This operation can be very slow (and should display progress).
	abstract void optimize();

	/// Utility function (copy file or directory)
	final void cp(string src, string dst, bool silent = false)
	{
		if (!silent)
			log("Copy: " ~ src ~ " -> " ~ dst);

		ensurePathExists(dst);
		if (src.isDir)
		{
			if (!dst.exists)
				dst.mkdir();
			foreach (de; src.dirEntries(SpanMode.shallow))
				cp(de.name, dst.buildPath(de.name.baseName), true);
		}
		else
		{
			copy(src, dst);
			version (Posix)
				dst.setAttributes(src.getAttributes());
		}
	}
}

/// Base class for a simple directory store.
abstract class DirCacheBase : DCache
{
	this(string cacheDir, ICacheHost cacheHost)
	{
		super(cacheDir, cacheHost);
		if (!cacheDir.exists)
			cacheDir.mkdirRecurse();
	}

	override string[] getEntries()
	{
		return cacheDir.dirEntries(SpanMode.shallow).filter!(de => de.isDir).map!(de => de.baseName).array;
	}

	override bool haveEntry(string key) const
	{
		return cacheDir.buildPath(key).I!(path => path.exists && path.isDir);
	}

	override string[] listFiles(string key) const
	{
		return cacheDir.buildPath(key).I!(path =>
			path
			.dirEntries(SpanMode.breadth)
			.filter!(de => de.isFile)
			.map!(de => de.name
				[path.length+1..$] // paths should be relative to cache entry dir root
				.replace(`\`, `/`)
			)
			.array
		);
	}

	abstract void optimizeKey(string key);

	override void add(string key, string sourcePath)
	{
		auto entryDir = cacheDir.buildPath(key);
		ensurePathExists(entryDir);
		sourcePath.rename(entryDir);
		optimizeKey(key);
	}

	override void extract(string key, string targetPath, bool delegate(string) pathFilter)
	{
		cacheDir.buildPath(key).dirEntries(SpanMode.shallow)
			.filter!(de => pathFilter(de.baseName))
			.each!(de => cp(de.name, buildPath(targetPath, de.baseName)));
	}

	override void remove(string key)
	{
		cacheDir.buildPath(key).rmdirRecurse();
	}
}

/// The bare minimum required for ae.sys.d to work.
/// Implement a temporary cache which is deleted
/// as soon as it's no longer immediately needed.
class TempCache : DirCacheBase
{
	mixin GenerateContructorProxies;
	alias cacheHost this; // https://issues.dlang.org/show_bug.cgi?id=5973

	override @property string name() const { return "none"; }

	override void finalize()
	{
		if (cacheDir.exists)
		{
			log("Clearing temporary cache");
			rmdirRecurse(cacheDir);
		}
	}

	override void optimize() { finalize(); }
	override void optimizeKey(string key) {}
}

/// Store cached builds in subdirectories.
/// Optimize things by hard-linking identical files.
class DirCache : DirCacheBase
{
	mixin GenerateContructorProxies;
	alias cacheHost this; // https://issues.dlang.org/show_bug.cgi?id=5973

	override @property string name() const { return "directory"; }

	size_t dedupedFiles;

	/// Replace all files that have duplicate subpaths and content
	/// which exist under both dirA and dirB with hard links.
	void dedupDirectories(string dirA, string dirB)
	{
		foreach (de; dirEntries(dirA, SpanMode.depth))
			if (de.isFile)
			{
				auto pathA = de.name;
				auto subPath = pathA[dirA.length..$];
				auto pathB = dirB ~ subPath;

				if (pathB.exists
				 && pathA.getSize() == pathB.getSize()
				 && pathA.getFileID() != pathB.getFileID()
				 && pathA.mdFileCached() == pathB.mdFileCached())
				{
					//debug log(pathB ~ " = " ~ pathA);
					pathB.remove();
					try
					{
						pathA.hardLink(pathB);
						dedupedFiles++;
					}
					catch (FileException e)
					{
						log(" -- Hard link failed: " ~ e.msg);
						pathA.copy(pathB);
					}
				}
			}
	}

	private final void optimizeCacheImpl(const(string)[] order, bool reverse = false, string onlyKey = null)
	{
		if (reverse)
			order = order.retro.array();

		string[] lastKeys;

		auto cacheDirEntries = cacheDir
			.dirEntries(SpanMode.shallow)
			.map!(de => de.baseName)
			.array
			.sort()
		;

		foreach (prefix; order)
		{
			auto cacheEntries = cacheDirEntries
				.filter!(name => name.startsWith(prefix))
				.array
			;

			bool optimizeThis = onlyKey is null || onlyKey.startsWith(prefix);

			if (optimizeThis)
			{
				auto targetEntries = lastKeys ~ cacheEntries;

				if (targetEntries.length)
					foreach (i, entry1; targetEntries[0..$-1])
						foreach (entry2; targetEntries[i+1..$])
							dedupDirectories(buildPath(cacheDir, entry1), buildPath(cacheDir, entry2));
			}

			if (cacheEntries.length)
				lastKeys = cacheEntries;
		}
	}

	override void finalize() {}

	/// Optimize entire cache.
	override void optimize()
	{
		bool[string] componentNames;
		foreach (de; dirEntries(cacheDir, SpanMode.shallow))
		{
			auto parts = de.baseName().split("-");
			if (parts.length >= 3)
				componentNames[parts[0..$-2].join("-")] = true;
		}

		log("Optimizing cache..."); dedupedFiles = 0;
		foreach (order; getKeyOrder(null))
			optimizeCacheImpl(order);
		log("Deduplicated %d files.".format(dedupedFiles));
	}

	/// Optimize specific revision.
	override void optimizeKey(string key)
	{
		log("Optimizing cache entry..."); dedupedFiles = 0;
		auto orders = getKeyOrder(key);
		foreach (order; orders) // Should be only one
		{
			optimizeCacheImpl(order, false, key);
			optimizeCacheImpl(order, true , key);
		}
		log("Deduplicated %d files.".format(dedupedFiles));
	}
}

/// Cache backed by a git repository.
/// Git's packfiles provide an efficient way to store binary
/// files with small differences, however adding and extracting
/// items is a little slower.
class GitCache : DCache
{
	import std.process;
	import ae.sys.git;

	Repository git;
	static const refPrefix = "refs/ae-sys-d-cache/";

	override @property string name() const { return "git"; }

	this(string cacheDir, ICacheHost cacheHost)
	{
		super(cacheDir, cacheHost);
		if (!cacheDir.exists)
		{
			cacheDir.mkdirRecurse();
			spawnProcess(["git", "init", cacheDir])
				.wait()
				.I!(code => (code==0).enforce("git init failed"))
			;
		}
		git = Repository(cacheDir);
	}

	override string[] getEntries()
	{
		auto chompPrefix(R)(R r, string prefix) { return r.filter!(s => s.startsWith(prefix)).map!(s => s[prefix.length..$]); }
		try
			return git
				.query("show-ref")
				.splitLines
				.map!(s => s[41..$])
				.I!chompPrefix(refPrefix)
				.array
			;
		catch (Exception e)
			return null; // show-ref will exit with status 1 for an empty repository
	}

	override bool haveEntry(string key) const
	{
		return git.check("show-ref", refPrefix ~ key);
	}

	override string[] listFiles(string key) const
	{
		return git
			.query("ls-tree", "--name-only", "-r", refPrefix ~ key)
			.splitLines
		;
	}

	override void add(string key, string sourcePath)
	{
		git.run("symbolic-ref", "HEAD", refPrefix ~ key);
		git.gitDir.buildPath("index").I!(index => { if (index.exists) index.remove(); }); // kill index
		git.run("--work-tree", sourcePath, "add", "--all");
		git.run("--work-tree", sourcePath, "commit", "--message", key);
	}

	override void extract(string key, string targetPath, bool delegate(string) pathFilter)
	{
		if (!targetPath.exists)
			targetPath.mkdirRecurse();
		targetPath = targetPath.absolutePath();
		targetPath = targetPath[$-1].isDirSeparator ? targetPath : targetPath ~ dirSeparator;

		git.run("reset", "--quiet", "--mixed", refPrefix ~ key);
		git.run(["checkout-index",
			"--prefix", targetPath,
			"--"] ~ listFiles(key).filter!(fn => pathFilter(fn.split("/")[0])).array);
	}

	override void remove(string key)
	{
		git.run("update-ref", "-d", refPrefix ~ key);
	}

	override void finalize() {}

	override void optimize()
	{
		git.run("prune");
		git.run("pack-refs", "--all");
		git.run("repack", "-a", "-d");
	}
}

/// Create a DCache instance according to the given name.
DCache createCache(string name, string cacheDir, ICacheHost cacheHost)
{
	switch (name)
	{
		case "":
		case "false": // compat
		case "none":      return new TempCache(cacheDir, cacheHost);
		case "true":  // compat
		case "directory": return new DirCache (cacheDir, cacheHost);
		case "git":       return new GitCache (cacheDir, cacheHost);
		default: throw new Exception("Unknown cache engine: " ~ name);
	}
}

unittest
{
	void testEngine(string name)
	{
		class Host : ICacheHost
		{
			string[][] getKeyOrder(string key) { return null; }
			void log(string s) {}
		}
		auto host = new Host;

		auto testDir = "test-cache";
		if (testDir.exists) testDir.forceDelete!false(true);
		testDir.mkdir();
		scope(exit) if (testDir.exists) testDir.forceDelete!false(true);

		auto cacheEngine = createCache(name, testDir.buildPath("cache"), host);
		assert(cacheEngine.getEntries().length == 0);
		assert(!cacheEngine.haveEntry("test-key"));

		auto sourceDir = testDir.buildPath("source");
		mkdir(sourceDir);
		write(sourceDir.buildPath("test.txt"), "Test");
		mkdir(sourceDir.buildPath("dir"));
		write(sourceDir.buildPath("dir", "test2.txt"), "Test 2");

		cacheEngine.add("test-key", sourceDir);
		assert(cacheEngine.getEntries() == ["test-key"]);
		assert(cacheEngine.haveEntry("test-key"));
		assert(cacheEngine.listFiles("test-key").sort().release == ["dir/test2.txt", "test.txt"]);

		auto targetDir = testDir.buildPath("target");
		mkdir(targetDir);
		cacheEngine.extract("test-key", targetDir, fn => true);
		assert(targetDir.buildPath("test.txt").readText == "Test");
		assert(targetDir.buildPath("dir", "test2.txt").readText == "Test 2");

		rmdirRecurse(targetDir);
		mkdir(targetDir);
		cacheEngine.extract("test-key", targetDir, fn => fn=="dir");
		assert(!targetDir.buildPath("test.txt").exists);
		assert(targetDir.buildPath("dir", "test2.txt").readText == "Test 2");

		cacheEngine.remove("test-key");
		assert(cacheEngine.getEntries().length == 0);
		assert(!cacheEngine.haveEntry("test-key"));

		cacheEngine.finalize();

		cacheEngine.optimize();
	}

	testEngine("none");
	testEngine("directory");
	testEngine("git");
}
