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

module ae.sys.d.build;

import std.algorithm;
import std.array;
import std.datetime;
import std.exception;
import std.file;
import std.path;
import std.process;
import std.string;

import ae.sys.cmd;
import ae.sys.file;

class DBuilder
{
	struct Config
	{
		version (Windows)
			enum defaultModel = "32";
		else
		version (D_LP64)
			enum defaultModel = "64";
		else
			enum defaultModel = "32";

		string model = defaultModel;
		bool debugDMD = false;
	}
	Config config;

	string repoDir;
	string buildDir;
	string dmcDir;

	string[string] dEnv;

	@property string model() { return config.model; }
	@property string modelSuffix() { return config.model == config.init.model ? "" : config.model; }
	version (Windows)
	{
		enum string makeFileName = "win32.mak";
		@property string makeFileNameModel() { return "win"~model~".mak"; }
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

		auto status = spawnProcess(args, newEnv, .Config.newEnv).wait();
		enforce(status == 0, "Command %s failed with status %d".format(args, status));
	}

	void run(string[] args...)
	{
		run(args, dEnv);
	}

	void build()
	{
		buildDMD();
		buildPhobosIncludes();
		buildDruntime();
		buildPhobos();
		buildTools();
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
			hardLink(src, dst);
		}
	}

	void log(string line)
	{
		import std.stdio;
		stderr.writeln(line);
	}

	void buildDMD()
	{
		{
			auto owd = pushd(buildPath(repoDir, "dmd", "src"));
			string[] targets = config.debugDMD ? [] : ["dmd"];
			run(["make", "-f", makeFileName, "MODEL=" ~ model] ~ targets, dEnv);
		}

		install(
			buildPath(repoDir, "dmd", "src", "dmd" ~ binExt),
			buildPath(buildDir, "bin", "dmd" ~ binExt),
		);

		version (Windows)
		{
			// TODO: either properly detect where VS and the SDK are installed,
			// or obtain and create a portable install with only the necessary components,
			// as done here: https://github.com/CyberShadow/FarCI
			auto ini = q"EOS
[Environment]
LIB="%@P%\..\lib"
DFLAGS="-I%@P%\..\import"
LINKCMD=%DMC%\link.exe
[Environment64]
LIB="%@P%\..\lib"
DFLAGS=%DFLAGS% -L/OPT:NOICF
VCINSTALLDIR=\Program Files (x86)\Microsoft Visual Studio 10.0\VC\
PATH=%PATH%;%VCINSTALLDIR%\bin\amd64
WindowsSdkDir=\Program Files (x86)\Microsoft SDKs\Windows\v7.0A
LINKCMD=%VCINSTALLDIR%\bin\amd64\link.exe
LIB=%LIB%;"%VCINSTALLDIR%\lib\amd64"
LIB=%LIB%;"%WindowsSdkDir%\Lib\winv6.3\um\x64"
LIB=%LIB%;"%WindowsSdkDir%\Lib\win8\um\x64"
LIB=%LIB%;"%WindowsSdkDir%\Lib\x64"
EOS";
			ini = ini.replace("%DMC%", buildPath(dmcDir, `bin`).absolutePath());
			buildPath(buildDir, "bin", "sc.ini").write(ini);
		}
		else
		{
			auto ini = q"EOS
[Environment]
DFLAGS="-I%@P%/../import" "-L-L%@P%/../lib"
EOS";
			buildPath(buildDir, "bin", "dmd.conf").write(ini);
		}

		log("DMD OK!");
	}

	void buildDruntime()
	{
		{
			auto owd = pushd(buildPath(repoDir, "druntime"));

			mkdirRecurse("import");
			mkdirRecurse("lib");

			setTimes(buildPath("src", "rt", "minit.obj"), Clock.currTime(), Clock.currTime());

			run(["make", "-f", makeFileNameModel, "MODEL=" ~ model], dEnv);
		}

		install(
			buildPath(repoDir, "druntime", "import"),
			buildPath(buildDir, "import"),
		);


		log("Druntime OK!");
	}

	void buildPhobosIncludes()
	{
		// In older versions of D, Druntime depended on Phobos modules.
		foreach (f; ["std", "etc", "crc32.d"])
			if (buildPath(repoDir, "phobos", f).exists)
				install(
					buildPath(repoDir, "phobos", f),
					buildPath(buildDir, "import", f),
				);
	}

	void buildPhobos()
	{
		string[] targets;

		{
			auto owd = pushd(buildPath(repoDir, "phobos"));
			version (Windows)
			{
				auto lib = "phobos%s.lib".format(modelSuffix);
				run(["make", "-f", makeFileNameModel, "MODEL=" ~ model, lib], dEnv);
				enforce(lib.exists);
				targets = [lib];
			}
			else
			{
				run(["make", "-f", makeFileNameModel, "MODEL=" ~ model], dEnv);
				targets = "generated".dirEntries(SpanMode.depth).filter!(de => de.name.endsWith(".a")).map!(de => de.name).array();
			}
		}

		foreach (lib; targets)
			install(
				buildPath(repoDir, "phobos", lib),
				buildPath(buildDir, "lib", lib.baseName()),
			);

		log("Phobos OK!");
	}

	void buildTools()
	{
		// Just build rdmd
		{
			auto owd = pushd(buildPath(repoDir, "tools"));
			run(["dmd", "-m" ~ model, "rdmd"], dEnv);
		}
		install(
			buildPath(repoDir, "tools", "rdmd" ~ binExt),
			buildPath(buildDir, "bin", "rdmd" ~ binExt),
		);

		log("Tools OK!");
	}
}
