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
import ae.sys.file;

import std.algorithm;
import std.array;
import std.file;
import std.path;
import std.process : environment;
import std.string;

/// Where all software will be unpacked
/// (current directory, by default).
string installationDirectory = null;

class Installer
{
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

	/// Set this to true to always install this component
	/// locally, ignoring whether it may be already available
	/// on the system.
	bool ignoreSystemInstallation = false;

	/// Whether the component is installed locally.
	@property final bool installedLocally()
	{
		// The directory should only be created atomically upon
		// the end of a successful installation, so an exists
		// check is sufficient.
		return directory.exists;
	}

	/// Whether the component is installed, locally or
	/// already present on the system.
	@property final bool available()
	{
		if (installedLocally)
			return true;

		if (!ignoreSystemInstallation)
			return availableOnSystem;

		return false;
	}

	@property bool availableOnSystem()
	{
		if (requiredExecutables is null)
			return false;

		return requiredExecutables.all!haveExecutable();
	}

	/// Install this component if necessary.
	final void require()
	{
		if (!available)
			install();

		assert(available);

		if (installedLocally)
			foreach (binPath; binPaths)
			{
				auto path = buildPath(directory, binPath).absolutePath();
				log("Adding " ~ path ~ " to PATH.");
				// Override any system installations
				environment["PATH"] = path ~ pathSeparator ~ environment["PATH"];
			}
	}

	private void install()
	{
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
	protected void windowsOnly()
	{
		version(Windows)
			return;
		else
		{
			log(name ~ " is not installable on this platform.");
			uninstallable();
		}
	}

	protected void uninstallable()
	{
		throw new Exception("Please install " ~ name ~ " and make sure it is on your PATH.");
	}
}
