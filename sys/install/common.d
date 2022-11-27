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

/// Manages a directory hosting downloads and locally installed
/// software.
final class Installer
{
	/// Where all software will be unpacked.
	string installationDirectory;

	this(string installationDirectory)
	{
		this.installationDirectory = installationDirectory;
	}

	/// Log sink
	void delegate(string) logger;

	private void log(string s)
	{
		if (logger) logger(s);
	}
}

/// `Installer` instance used by the current thread.
Installer installer;

/// Base class for an installer package - a process to acquire and set
/// up some third-party software or component to some temporary
/// location, so that we can then invoke and use it.
class Package
{
	/// Component name. Used for logging.
	@property string name() { return this.classinfo.name.split(".")[$-1].chomp("Installer"); }

	/// The subdirectory where this component will be installed.
	@property string subdirectory() { return name.toLower(); }

	/// Subdirectories (under the installation subdirectory)
	/// containing executables which need to be added to PATH.
	@property string[] binPaths() { return [""]; }

	/// As above, but expanded to full absolute directory paths.
	@property final string[] binDirs() { return binPaths.map!(binPath => buildPath(directory, binPath)).array; }

	/// The full installation directory.
	@property final string directory()
	{
		return buildPath(installer.installationDirectory, subdirectory);
	}

	// The list of executable names required to be present.
	// Null if this component is never considered already
	// available on the system.
	deprecated @property string[] requiredExecutables() { return null; }

	/// Get the full path to an executable.
	/// If the package is not installed locally, the PATH variable
	/// from the process environment is searched instead.
	deprecated("Use getExecutable instead")
	string exePath(string name)
	{
		return .findExecutable(name, installedLocally ? binDirs : .pathDirs);
	}

	/// Get the full path to an executable.
	/// The returned value is suitable for passing to std.process.spawnProcess.
	string getExecutable(string name)
	{
		assert(installedLocally, "This package is not yet installed, call requireInstalled first");
		return .findExecutable(name, binDirs);
	}

	/// Get an environment suitable for executing programs in this package.
	/// The returned value is suitable for passing to
	/// `std.process.spawnProcess` (with Config.newEnv).
	/// Hint: pass `std.process.environment.toAA()` to build onto the
	/// current environment.
	string[string] getEnvironment(string[string] baseEnvironment = null)
	{
		auto environment = baseEnvironment.dup;
		assert(installedLocally, "This package is not yet installed, call requireInstalled first");
		foreach_reverse (binPath; binPaths)
		{
			auto path = buildPath(directory, binPath).absolutePath();
			// Override any system installations
			if ("PATH" in environment)
				environment["PATH"] = path ~ pathSeparator ~ environment["PATH"];
			else
				environment["PATH"] = path;
		}
		return environment;
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
	deprecated("Check system availability explicitly at call site")
	@property bool availableOnSystem()
	{
		if (requiredExecutables is null)
			return false;

		return requiredExecutables.all!(.haveExecutable)();
	}

	/// Whether the component is installed, locally or
	/// already present on the system.
	deprecated("Check system availability explicitly at call site")
	@property final bool available()
	{
		return installedLocally || availableOnSystem;
	}

	/// Install this component if necessary.
	deprecated("Check system availability explicitly at call site")
	final void require()
	{
		if (!available)
			install();

		assert(available);

		if (installedLocally)
			addToPath();
	}

	/// Install this component locally, if it isn't already installed.
	deprecated("Use requireInstalled instead")
	final void requireLocal(bool shouldAddToPath = true)
	{
		if (!installedLocally)
			install();

		if (shouldAddToPath)
			addToPath();
	}

	/// Install this component locally, if it isn't already installed.
	/// Returns `this`, to allow chaining `getExecutable` or `getEnvironment`.
	final This requireInstalled(this This)()
	{
		if (!installedLocally)
			install();
		return cast(This)this;
	}

	deprecated private bool addedToPath;

	/// Change this process's PATH environment variable to include the
	/// path to this component's executable directories.
	deprecated("Use getEnvironment / getExecutable instead")
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
		mkdirRecurse(installer.installationDirectory);

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
	// Implementation helpers

final:
protected:
	static void log(string s)
	{
		installer.log(s);
	}

	static string saveLocation(string url)
	{
		return buildPath(installer.installationDirectory, url.fileNameFromURL());
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
		auto target = buildPath(installer.installationDirectory, fn);
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
			p = new P(buildPath(installer.installationDirectory, "redirects.json"));
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
		throw new Exception("Cannot install " ~ name ~ ".");
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
