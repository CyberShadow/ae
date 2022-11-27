/**
 * ae.sys.install.common
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

module ae.sys.install.common;

import std.algorithm;
import std.array;
import std.exception;
import std.file;
import std.path;
import std.process : environment;
import std.string;

import ae.net.ietf.url;
import ae.sys.archive;
import ae.sys.file;
import ae.sys.net;
import ae.sys.persistence;
import ae.utils.meta;
import ae.utils.path;

/// Base class for an installer - a process to acquire and set up some
/// third-party software or component to some temporary location, so
/// that we can then invoke and use it.
class Installer
{
	/// Where all software will be unpacked
	/// (current directory, by default).
	static string installationDirectory = null;

	/// Log sink
	static void delegate(string) logger;

	static protected void log(string s)
	{
		if (logger) logger(s);
	}

	/// Component name. Used for logging.
	@property string name() { return this.classinfo.name.split(".")[$-1].chomp("Installer"); }

	/// The subdirectory where this component will be installed.
	@property string subdirectory() { return name.toLower(); }

	/// Subdirectories (under the installation subdirectory)
	/// containing executables which need to be added to PATH.
	@property string[] binPaths() { return [""]; }

	/// As above, but expanded to full absolute directory paths.
	@property final string[] binDirs() { return binPaths.map!(binPath => buildPath(directory, binPath)).array; }

	deprecated("Please use ae.utils.path.pathDirs")
	@property static string[] pathDirs() { return ae.utils.path.pathDirs; }

	/// The full installation directory.
	@property final string directory()
	{
		return buildPath(installationDirectory, subdirectory);
	}

	/// The list of executable names required to be present.
	/// Null if this component is never considered already
	/// available on the system.
	@property string[] requiredExecutables() { return null; }

	deprecated("Please use ae.utils.path.haveExecutable")
	/*protected*/ static bool haveExecutable(string name) { return ae.utils.path.haveExecutable(name); }

	deprecated("Please use ae.utils.path.findExecutable")
	static string findExecutable(string name, string[] dirs) { return ae.utils.path.findExecutable(name, dirs); }

	/// Get the full path to an executable.
	string exePath(string name)
	{
		return .findExecutable(name, installedLocally ? binDirs : .pathDirs);
	}

	/// Whether the component is installed locally.
	@property bool installedLocally()
	{
		// The directory should only be created atomically upon
		// the end of a successful installation, so an exists
		// check is sufficient.
		return directory.exists;
	}

	/// Whether the component is already present on the system.
	@property bool availableOnSystem()
	{
		if (requiredExecutables is null)
			return false;

		return requiredExecutables.all!(.haveExecutable)();
	}

	/// Whether the component is installed, locally or
	/// already present on the system.
	@property final bool available()
	{
		return installedLocally || availableOnSystem;
	}

	/// Install this component if necessary.
	final void require()
	{
		if (!available)
			install();

		assert(available);

		if (installedLocally)
			addToPath();
	}

	/// Install this component locally, if it isn't already installed.
	final void requireLocal(bool shouldAddToPath = true)
	{
		if (!installedLocally)
			install();

		if (shouldAddToPath)
			addToPath();
	}

	private bool addedToPath;

	/// Change this process's PATH environment variable to include the
	/// path to this component's executable directories.
	void addToPath()
	{
		if (addedToPath)
			return;
		foreach (binPath; binPaths)
		{
			auto path = buildPath(directory, binPath).absolutePath();
			log("Adding " ~ path ~ " to PATH.");
			// Override any system installations
			environment["PATH"] = path ~ pathSeparator ~ environment["PATH"];
		}
		addedToPath = true;
	}

	private void install()
	{
		mkdirRecurse(installationDirectory);

		log("Installing " ~ name ~ " to " ~ directory ~ "...");
		atomicInstallImpl();
		log("Done installing " ~ name ~ ".");
	}

	/// Install to `directory` atomically.
	protected void atomicInstallImpl()
	{
		void installProxy(string target) { installImpl(target); }
		atomic!installProxy(directory);
	}

	protected void installImpl(string /*target*/)
	{
		uninstallable();
	}

	// ----------------------------------------------------

final:
protected:
	static string saveLocation(string url)
	{
		return buildPath(installationDirectory, url.fileNameFromURL());
	}

	template cachedAction(alias fun, string fmt)
	{
		static void cachedAction(Args...)(Args args, string target)
		{
			if (target.exists)
				return;
			log(fmt.format(args, target));
			atomic!fun(args, target);
		}
	}

	static string[string] urlDigests;

	static void saveFile(string url, string target)
	{
		downloadFile(url, target);
		auto pDigest = url in urlDigests;
		if (pDigest)
		{
			auto digest = *pDigest;
			if (!digest)
				return;
			log("Verifying " ~ target.baseName() ~ "...");

			import std.digest.sha : SHA1;
			import std.digest : toHexString, LetterCase;
			import std.stdio : File;
			SHA1 sha;
			sha.start();
			foreach (chunk; File(target, "rb").byChunk(0x10000))
				sha.put(chunk[]);
			auto hash = sha.finish();
			enforce(hash[].toHexString!(LetterCase.lower) == digest,
				"Could not verify integrity of " ~ target ~ ".\n" ~
				"Expected: " ~ digest ~ "\n" ~
				"Got     : " ~ hash.toHexString!(LetterCase.lower));
		}
		else
			log("WARNING: Not verifying integrity of " ~ url ~ ".");
	}

	alias saveTo = cachedAction!(saveFile, "Downloading %s to %s...");
	alias save = withTarget!(saveLocation, saveTo);

	static auto saveAs(string url, string fn)
	{
		auto target = buildPath(installationDirectory, fn);
		ensurePathExists(target);
		url.I!saveTo(target);
		return target;
	}

	static string stripArchiveExtension(string fn)
	{
		fn = fn.stripExtension();
		if (fn.extension == ".tar")
			fn = fn.stripExtension();
		return fn;
	}

	alias unpackTo = cachedAction!(ae.sys.archive.unpack, "Unpacking %s to %s...");
	alias unpack = withTarget!(stripArchiveExtension, unpackTo);

	static string resolveRedirectImpl(string url)
	{
		return net.resolveRedirect(url);
	}
	static string resolveRedirect(string url)
	{
		alias P = PersistentMemoized!(resolveRedirectImpl, FlushPolicy.atThreadExit);
		static P* p;
		if (!p)
			p = new P(buildPath(installationDirectory, "redirects.json"));
		return (*p)(url);
	}

	void windowsOnly()
	{
		version(Windows)
			return;
		else
		{
			log(name ~ " is not installable on this platform.");
			uninstallable();
		}
	}

	void uninstallable()
	{
		throw new Exception("Please install " ~ name ~ " and make sure it is on your PATH.");
	}
}

/// Move a directory and its contents into another directory recursively,
/// overwriting any existing files.
package void moveInto(string source, string target)
{
	foreach (de; source.dirEntries(SpanMode.shallow))
	{
		auto targetPath = target.buildPath(de.baseName);
		if (de.isDir && targetPath.exists)
			de.moveInto(targetPath);
		else
			de.name.rename(targetPath);
	}
	source.rmdir();
}

/// As above, but do not leave behind partially-merged
/// directories. In case of failure, both source and target
/// are deleted.
package void atomicMoveInto(string source, string target)
{
	auto tmpSource = source ~ ".tmp";
	auto tmpTarget = target ~ ".tmp";
	if (tmpSource.exists) tmpSource.rmdirRecurse();
	if (tmpTarget.exists) tmpTarget.rmdirRecurse();
	source.rename(tmpSource);
	target.rename(tmpTarget);
	{
		scope(failure) tmpSource.rmdirRecurse();
		scope(failure) tmpTarget.rmdirRecurse();
		tmpSource.moveInto(tmpTarget);
	}
	tmpTarget.rename(target);
}
