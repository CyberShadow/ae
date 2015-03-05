/**
 * Code to build DMD/Phobos/Druntime.
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

module ae.sys.d.builder;

import std.algorithm;
import std.array;
import std.datetime;
import std.exception;
import std.file;
import std.path;
import std.process;
import std.string;

import ae.sys.file;

/// Class which builds D from source.
class DBuilder
{
	/// DBuilder configuration.
	struct Config
	{
		/// Build configuration.
		struct Build
		{
			version (Windows)
				enum defaultModel = "32";
			else
			version (D_LP64)
				enum defaultModel = "64";
			else
				enum defaultModel = "32";

			string model = defaultModel; /// Target model ("32" or "64").
			bool debugDMD = false;       /// Whether to build a debug DMD.
			                             /// Debug builds are faster to build,
			                             /// but run slower. Windows only.

			string[] makeArgs; /// Additional make parameters,
			                   /// e.g. "-j8" or "HOST_CC=g++48"

			/// Returns a string representation of this build configuration
			/// usable for a cache directory name. Must reflect all fields.
			string toString() const
			{
				string buildID = model;
				if (debugDMD)
					buildID ~= "-debug";
				return buildID;
			}
		}
		Build build; /// ditto

		/// Local configuration.
		struct Local
		{
			string repoDir;  /// D source location (as checked out from GitHub).
			string buildDir; /// Build target directory.
			string dmcDir;   /// Where dmc.zip is unpacked.
			string vsDir;    /// Where Visual Studio is installed
			string sdkDir;   /// Where the Windows SDK is installed

			/// D build environment.
			string[string] env;
		}
		Local local; /// ditto
	}
	Config config;

	@property string make()
	{
		return config.local.env.get("MAKE", environment.get("MAKE", "make"));
	}

	@property string[] platformMakeVars()
	{
		string[] args;

		args ~= "MODEL=" ~ config.build.model;

		version (Windows)
			if (config.build.model == "64")
			{
				args ~= "VCDIR="  ~ config.local.vsDir .absolutePath() ~ `\VC`;
				args ~= "SDKDIR=" ~ config.local.sdkDir.absolutePath();
			}

		return args;
	}

	/// Build everything.
	void build()
	{
		buildDMD();
		buildPhobosIncludes();
		buildDruntime();
		buildPhobos();
		buildTools();
	}

	void buildDMD()
	{
		{
			auto owd = pushd(buildPath(config.local.repoDir, "dmd", "src"));
			string[] targets = config.build.debugDMD ? [] : ["dmd"];
			run([make, "-f", makeFileName, "MODEL=" ~ config.build.model] ~ config.build.makeArgs ~ targets);
		}

		install(
			buildPath(config.local.repoDir, "dmd", "src", "dmd" ~ binExt),
			buildPath(config.local.buildDir, "bin", "dmd" ~ binExt),
		);

		version (Windows)
		{
			auto ini = q"EOS
[Environment]
LIB="%@P%\..\lib"
DFLAGS="-I%@P%\..\import"
DMC=__DMC__
LINKCMD=%DMC%\link.exe
[Environment64]
LIB="%@P%\..\lib"
DFLAGS=%DFLAGS% -L/OPT:NOICF
VSINSTALLDIR=__VS__\
VCINSTALLDIR=%VSINSTALLDIR%VC\
PATH=%PATH%;%VCINSTALLDIR%\bin\amd64
WindowsSdkDir=__SDK__
LINKCMD=%VCINSTALLDIR%\bin\amd64\link.exe
LIB=%LIB%;"%VCINSTALLDIR%\lib\amd64"
LIB=%LIB%;"%WindowsSdkDir%\Lib\winv6.3\um\x64"
LIB=%LIB%;"%WindowsSdkDir%\Lib\win8\um\x64"
LIB=%LIB%;"%WindowsSdkDir%\Lib\x64"
EOS";
			ini = ini.replace("__DMC__", config.local.dmcDir.buildPath(`bin`).absolutePath());
			ini = ini.replace("__VS__" , config.local.vsDir .absolutePath());
			ini = ini.replace("__SDK__", config.local.sdkDir.absolutePath());

			buildPath(config.local.buildDir, "bin", "sc.ini").write(ini);
		}
		else version (OSX)
		{
			auto ini = q"EOS
[Environment]
DFLAGS="-I%@P%/../import" "-L-L%@P%/../lib"
EOS";
			buildPath(config.local.buildDir, "bin", "dmd.conf").write(ini);
		}
		else
		{
			auto ini = q"EOS
[Environment]
DFLAGS="-I%@P%/../import" "-L-L%@P%/../lib" -L--export-dynamic
EOS";
			buildPath(config.local.buildDir, "bin", "dmd.conf").write(ini);
		}

		log("DMD OK!");
	}

	void buildDruntime()
	{
		{
			auto owd = pushd(buildPath(config.local.repoDir, "druntime"));

			mkdirRecurse("import");
			mkdirRecurse("lib");

			setTimes(buildPath("src", "rt", "minit.obj"), Clock.currTime(), Clock.currTime());

			run([make, "-f", makeFileNameModel] ~ config.build.makeArgs ~ platformMakeVars);
		}

		install(
			buildPath(config.local.repoDir, "druntime", "import"),
			buildPath(config.local.buildDir, "import"),
		);


		log("Druntime OK!");
	}

	void buildPhobosIncludes()
	{
		// In older versions of D, Druntime depended on Phobos modules.
		foreach (f; ["std", "etc", "crc32.d"])
			if (buildPath(config.local.repoDir, "phobos", f).exists)
				install(
					buildPath(config.local.repoDir, "phobos", f),
					buildPath(config.local.buildDir, "import", f),
				);
	}

	void buildPhobos()
	{
		string[] targets;

		{
			auto owd = pushd(buildPath(config.local.repoDir, "phobos"));
			version (Windows)
			{
				auto lib = "phobos%s.lib".format(modelSuffix);
				run([make, "-f", makeFileNameModel, lib] ~ config.build.makeArgs ~ platformMakeVars);
				enforce(lib.exists);
				targets = [lib];
			}
			else
			{
				run([make, "-f", makeFileNameModel] ~ config.build.makeArgs ~ platformMakeVars);
				targets = "generated".dirEntries(SpanMode.depth).filter!(de => de.name.endsWith(".a")).map!(de => de.name).array();
			}
		}

		foreach (lib; targets)
			install(
				buildPath(config.local.repoDir, "phobos", lib),
				buildPath(config.local.buildDir, "lib", lib.baseName()),
			);

		log("Phobos OK!");
	}

	void buildTools()
	{
		// Just build rdmd
		{
			auto owd = pushd(buildPath(config.local.repoDir, "tools"));
			run(["dmd", "-m" ~ config.build.model, "rdmd"]);
		}
		install(
			buildPath(config.local.repoDir, "tools", "rdmd" ~ binExt),
			buildPath(config.local.buildDir, "bin", "rdmd" ~ binExt),
		);

		log("Tools OK!");
	}

protected:
	@property string modelSuffix() { return config.build.model == config.init.build.model ? "" : config.build.model; }
	version (Windows)
	{
		enum string makeFileName = "win32.mak";
		@property string makeFileNameModel() { return "win"~config.build.model~".mak"; }
		enum string binExt = ".exe";
	}
	else
	{
		enum string makeFileName = "posix.mak";
		enum string makeFileNameModel = "posix.mak";
		enum string binExt = "";
	}

	void run(string[] args, ref string[string] newEnv)
	{
		if (newEnv is null) newEnv = environment.toAA();
		string oldPath = environment["PATH"];
		scope(exit) environment["PATH"] = oldPath;
		environment["PATH"] = newEnv["PATH"];
		log("PATH=" ~ newEnv["PATH"]);

		auto status = spawnProcess(args, newEnv, .Config.newEnv).wait();
		enforce(status == 0, "Command %s failed with status %d".format(args, status));
	}

	void run(string[] args...)
	{
		run(args, config.local.env);
	}

	void install(string src, string dst)
	{
		ensurePathExists(dst);
		if (src.isDir)
		{
			if (!dst.exists)
				dst.mkdirRecurse();
			foreach (de; src.dirEntries(SpanMode.shallow))
				install(de.name, dst.buildPath(de.name.baseName));
		}
		else
		{
			debug log(src ~ " -> " ~ dst);
			try
				hardLink(src, dst);
			catch (FileException e)
				copy(src, dst);
		}
	}

	/// Override to add logging.
	void log(string line)
	{
	}
}
