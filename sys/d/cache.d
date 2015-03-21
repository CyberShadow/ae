/**
 * Cache manager for D builds.
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

import std.exception;
import std.file;
import std.path;
import std.string;

import ae.sys.d.manager;
import ae.sys.file;
import ae.sys.git;

class CacheManager
{
	enum UNBUILDABLE_MARKER = "unbuildable";

	bool enabled;
	string cacheDir, repoDir;
	bool ignoreFailed;

	/// Run a build process, but only if necessary.
	/// Throws an exception if the build was cached as unbuildable.
	void buildHook(DManager.BuildSpec spec, string buildDir, void delegate() buildAction)
	{
		// this build's cache location
		string currentCacheDir = cacheLocation(spec);

		if (enabled)
		{
			if (currentCacheDir.exists)
			{
				log("Found in cache: " ~ currentCacheDir);
				currentCacheDir.dirLink(buildDir);
				enforce(!buildPath(buildDir, UNBUILDABLE_MARKER).exists, "This build was cached as unbuildable.");
				return;
			}
			else
				log("Cache miss: " ~ currentCacheDir);
		}

		scope (exit)
		{
			if (currentCacheDir && buildDir.exists)
			{
				log("Saving to cache: " ~ currentCacheDir);
				ensurePathExists(currentCacheDir);
				buildDir.rename(currentCacheDir);
				currentCacheDir.dirLink(buildDir);
				optimizeRevision(spec.base);
			}
		}

		scope (failure)
		{
			// Don't cache failed build results during delve
			if (ignoreFailed)
				currentCacheDir = null;
		}

		// An incomplete build is useless, nuke the directory
		// and create a new one just for the UNBUILDABLE_MARKER.
		scope (failure)
		{
			if (buildDir.exists)
			{
				rmdirRecurse(buildDir);
				mkdir(buildDir);
				buildPath(buildDir, UNBUILDABLE_MARKER).touch();
			}
		}

		buildAction();
	}

	bool isCached(DManager.BuildSpec spec)
	{
		return enabled && cacheLocation(spec).exists;
	}

	string cacheLocation(DManager.BuildSpec spec)
	{
		auto buildID = spec.toString();
		return buildPath(cacheDir, buildID);
	}

	// ---------------------------------------------------------------------------

	/// Replace all files that have duplicate subpaths and content
	/// which exist under both dirA and dirB with hard links.
	private void dedupDirectories(string dirA, string dirB)
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
					debug log(pathB ~ " = " ~ pathA);
					pathB.remove();
					try
						pathA.hardLink(pathB);
					catch (FileException e)
					{
						log(" -- Hard link failed: " ~ e.msg);
						pathA.copy(pathB);
					}
				}
			}
	}

	private void optimizeCacheImpl(bool reverse = false, string onlyRev = null)
	{
		string[] history = Repository(repoDir).query("log", "--pretty=format:%H", "origin/master").splitLines();
		if (reverse)
			history.reverse;

		string[][string] cacheContent;
		foreach (de; dirEntries(cacheDir, SpanMode.shallow))
			cacheContent[de.baseName()[0..40]] ~= de.name;

		string[string] lastRevisions;

		foreach (rev; history)
		{
			auto cacheEntries = cacheContent.get(rev, null);
			bool optimizeThis = onlyRev is null || onlyRev == rev;

			// Optimize with previous revision
			foreach (entry; cacheEntries)
			{
				auto suffix = entry.baseName()[40..$];
				if (optimizeThis && suffix in lastRevisions)
					dedupDirectories(lastRevisions[suffix], entry);
				lastRevisions[suffix] = entry;
			}

			// Optimize with alternate builds of this revision
			if (optimizeThis && cacheEntries.length)
				foreach (i, entry; cacheEntries[0..$-1])
					foreach (entry2; cacheEntries[i+1..$])
						dedupDirectories(entry, entry2);
		}
	}

	/// Optimize entire cache.
	void optimizeCache()
	{
		optimizeCacheImpl();
	}

	/// Optimize specific revision.
	void optimizeRevision(string revision)
	{
		optimizeCacheImpl(false, revision);
		optimizeCacheImpl(true , revision);
	}

	/// Override me
	void log(string s) {}
}

private static ubyte[16] mdFileCached(string fn)
{
	static ubyte[16][ulong] cache;
	auto id = getFileID(fn);
	auto phash = id in cache;
	if (phash)
		return *phash;
	return cache[id] = mdFile(fn);
}
