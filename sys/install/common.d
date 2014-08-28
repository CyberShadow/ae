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
 *   Vladimir Panteleev <vladimir@thecybershadow.net>
 */

module ae.sys.install.common;

import ae.net.ietf.url;
import ae.sys.archive;
import ae.sys.file;
import ae.sys.net;
import ae.sys.persistence;
import ae.utils.meta;

import std.algorithm;
import std.array;
import std.file;
import std.path;
import std.process : environment;
import std.string;

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
	@property string name() { return this.classinfo.name.split(".")[$-1]; }

	/// The subdirectory where this component will be installed.
	@property string subdirectory() { return name.toLower(); }

	/// Subdirectories (under the installation subdirectory)
	/// containing executables which need to be added to PATH.
	@property string[] binPaths() { return [""]; }

	/// The full installation directory.
	@property string directory()
	{
		return buildPath(installationDirectory, subdirectory);
	}

	/// The list of executable names required to be present.
	/// Null if this component is never considered already
	/// available on the system.
	@property string[] requiredExecutables() { return null; }

	/*protected*/ static bool haveExecutable(string name)
	{
		version(Windows)
			enum executableSuffixes = [".exe", ".bat", ".cmd"];
		else
			enum executableSuffixes = [""];

		foreach (entry; environment["PATH"].split(pathSeparator))
			foreach (suffix; executableSuffixes)
				if ((buildPath(entry, name) ~ suffix).exists)
					return true;

		return false;
	}

	/// Whether the component is installed locally.
	@property final bool installedLocally()
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

		return requiredExecutables.all!haveExecutable();
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

	bool addedToPath;

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

		void installProxy(string target) { installImpl(target); }
		safeUpdate!installProxy(directory);

		log("Done installing " ~ name ~ ".");
	}

	protected void installImpl(string target)
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

	alias saveTo = cachedAction!(downloadFile, "Downloading %s to %s...");
	alias save = withTarget!(saveLocation, saveTo);

	static auto saveAs(string url, string fn)
	{
		auto target = buildPath(installationDirectory, fn);
		ensurePathExists(target);
		url.I!saveTo(target);
		return target;
	}

	alias unpackTo = cachedAction!(ae.sys.archive.unpack, "Unpacking %s to %s...");
	alias unpack = withTarget!(stripExtension, unpackTo);

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
