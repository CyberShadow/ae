/**
 * Code to manage a D checkout and its dependencies.
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

module ae.sys.d.manager;

import std.algorithm;
import std.array;
import std.conv;
import std.datetime;
import std.exception;
import std.file;
import std.path;
import std.process;
import std.range;
import std.regex;
import std.string;
import std.typecons;

import ae.sys.d.cache;
import ae.sys.d.repo;
import ae.sys.file;
import ae.sys.git;
import ae.utils.aa;
import ae.utils.digest;
import ae.utils.json;
import ae.utils.regex;

version (Windows)
{
	import ae.sys.install.dmc;
	import ae.sys.install.vs;
}

import ae.sys.install.dmd;
import ae.sys.install.git;


/// Class which manages a D checkout and its dependencies.
class DManager : ICacheHost
{
	// **************************** Configuration ****************************

	struct Config /// DManager configuration.
	{
		struct Build /// Build configuration
		{
			struct Components
			{
				bool[string] enable;

				string[] getEnabledComponentNames()
				{
					return allComponents
						.filter!(componentName =>
							enable.get(componentName, defaultComponents.canFind(componentName)))
						.array
						.dup;
				}

				Component.CommonConfig common;
				DMD.Config dmd;
			}
			Components components;
		}
		Build build; /// ditto

		struct Local /// Machine-local configuration
		{
			/// URL of D git repository hosting D components.
			/// Defaults to (and must have the layout of) D.git:
			/// https://github.com/CyberShadow/D-dot-git
			string repoUrl = "https://bitbucket.org/cybershadow/d.git";

			/// Location for the checkout, temporary files, etc.
			string workDir;
		}
		Local local; /// ditto

		/// Don't get latest updates from GitHub.
		bool offline;

		/// How to cache built files.
		string cache;

		/// Whether we should cache failed builds.
		bool cacheFailures = true;

	//protected:

		struct Deps /// Configuration for software dependencies
		{
			string dmcDir;   /// Where dmc.zip is unpacked.
			string vsDir;    /// Where Visual Studio is installed
			string sdkDir;   /// Where the Windows SDK is installed
			string hostDC;   /// Host D compiler (for DDMD bootstrapping)
		}
		Deps deps; /// ditto

		/// Calculated local environment, incl. dependencies
		string[string] env;
	}
	Config config; /// ditto

	/// Get a specific subdirectory of the work directory.
	@property string subDir(string name)() { return buildPath(config.local.workDir, name); }

	alias repoDir    = subDir!"repo";        /// The git repository location.
	alias buildDir   = subDir!"build";       /// The build directory.
	alias dlDir      = subDir!"dl";          /// The directory for downloaded software.

	/// This number increases with each incompatible change to cached data.
	enum cacheVersion = 2;

	string cacheEngineDir(string engineName)
	{
		// Keep compatibility with old cache paths
		string engineDirName =
			engineName == "directory" || engineName == "true"  ? "cache"      :
			engineName == "none"      || engineName == "false" ? "temp-cache" :
			"cache-" ~ engineName;
		return buildPath(
			config.local.workDir,
			engineDirName,
			"v%d".format(cacheVersion),
		);
	}

	version (Windows)
		enum string binExt = ".exe";
	else
		enum string binExt = "";

	// **************************** Repositories *****************************

	class DManagerRepository : ManagedRepository
	{
		this()
		{
			this.offline = config.offline;
		}

		override void log(string s) { return this.outer.log(s); }
	}

	class MetaRepository : DManagerRepository
	{
		override void needRepo()
		{
			needGit();

			if (!repoDir.exists)
			{
				log("Cloning initial repository...");
				atomic!performClone(config.local.repoUrl, repoDir);
				return;
			}

			if (!git.path)
				git = Repository(repoDir);
		}

		static void performClone(string url, string target)
		{
			import ae.sys.cmd;
			run(["git", "clone", url, target]);
		}

		override void performCheckout(string hash)
		{
			super.performCheckout(hash);
			submodules = null;
		}

		string[string][string] submoduleCache;

		string[string] getSubmoduleCommits(string head)
		{
			auto pcacheEntry = head in submoduleCache;
			if (pcacheEntry)
				return *pcacheEntry;

			string[string] result;
			needRepo();
			foreach (line; git.query("ls-tree", head).splitLines())
			{
				auto parts = line.split();
				if (parts.length == 4 && parts[1] == "commit")
					result[parts[3]] = parts[2];
			}
			assert(result.length, "No submodules found");
			submoduleCache[head] = result;
			return result;
		}

		/// Get the submodule state for all commits in the history.
		/// Returns: result[commitHash][submoduleName] == submoduleCommitHash
		string[string][string] getSubmoduleHistory(string[] refs)
		{
			auto marksFile = buildPath(config.local.workDir, "temp", "marks.txt");
			ensurePathExists(marksFile);
			scope(exit) if (marksFile.exists) marksFile.remove();
			log("Running fast-export...");
			auto fastExportData = git.query([
				"fast-export",
				"--full-tree",
				"--no-data",
				"--export-marks=" ~ marksFile.absolutePath,
				] ~ refs
			);

			log("Parsing fast-export marks...");

			auto markLines = marksFile.readText.strip.splitLines;
			auto marks = new string[markLines.length];
			foreach (line; markLines)
			{
				auto parts = line.split(' ');
				auto markIndex = parts[0][1..$].to!int-1;
				marks[markIndex] = parts[1];
			}

			log("Parsing fast-export data...");

			string[string][string] result;
			foreach (i, commitData; fastExportData.split("deleteall\n")[1..$])
				result[marks[i]] = commitData
					.matchAll(re!(`^M 160000 ([0-9a-f]{40}) (\S+)$`, "m"))
					.map!(m => tuple(m.captures[2], m.captures[1]))
					.assocArray
				;
			return result;
		}
	}

	class SubmoduleRepository : DManagerRepository
	{
		string dir;

		override void needRepo()
		{
			getMetaRepo().needRepo();

			if (!git.path)
				git = Repository(dir);
		}
	}

	/// The meta-repository, which contains the sub-project submodules.
	private MetaRepository metaRepo;

	MetaRepository getMetaRepo() /// ditto
	{
		if (!metaRepo)
			metaRepo = new MetaRepository;
		return metaRepo;
	}

	/// Sub-project repositories.
	private SubmoduleRepository[string] submodules;

	ManagedRepository getSubmodule(string name) /// ditto
	{
		if (name !in submodules)
		{
			getMetaRepo().needRepo();
			enforce(name in getMetaRepo().getSubmoduleCommits(getMetaRepo().getRef("origin/master")),
				"Unknown submodule: " ~ name);

			auto path = buildPath(metaRepo.git.path, name);
			auto gitPath = buildPath(path, ".git");

			if (!gitPath.exists)
			{
				log("Initializing and updating submodule %s...".format(name));
				getMetaRepo().git.run(["submodule", "update", "--init", name]);
			}

			submodules[name] = new SubmoduleRepository();
			submodules[name].dir = path;
		}

		return submodules[name];
	}

	// ***************************** Components ******************************

	/// Base class for a D component.
	class Component
	{
		/// Name of this component, as registered in DManager.components AA.
		string name;

		/// Corresponding subproject repository name.
		@property abstract string submoduleName();
		@property ManagedRepository submodule() { return getSubmodule(submoduleName); }

		/// A string description of this component's configuration.
		abstract @property string configString();

		struct CommonConfig
		{
			version (Windows)
				enum defaultModel = "32";
			else
			version (D_LP64)
				enum defaultModel = "64";
			else
				enum defaultModel = "32";

			string model = defaultModel; /// Target model ("32" or "64").

			string[] makeArgs; /// Additional make parameters,
			                   /// e.g. "-j8" or "HOST_CC=g++48"
		}
		CommonConfig commonConfig;

		/// Commit in the component's repo from which to build this component.
		@property string commit() { return incrementalBuild ? "incremental" : getComponentCommit(name); }

		/// The components the source code of which this component depends on.
		@property abstract string[] sourceDeps();

		/// The components the just-built (in source directory) version of which this component depends on.
		@property abstract string[] buildDeps();

		/// The components the built, installed version of which this component depends on.
		@property abstract string[] installDeps();

		/// This metadata is saved to a .json file,
		/// and is also used to calculate the cache key.
		struct Metadata
		{
			int cacheVersion;
			string name;
			string commit;
			CommonConfig commonConfig;
			string[] sourceDepCommits;
			Metadata[] buildDepMetadata, cacheDepMetadata;
		}

		Metadata getMetadata() /// ditto
		{
			return Metadata(
				cacheVersion,
				name,
				commit,
				commonConfig,
				sourceDeps.map!(
					dependency => getComponent(dependency).commit
				).array(),
				buildDeps.map!(
					dependency => getComponent(dependency).getMetadata()
				).array(),
				installDeps.map!(
					dependency => getComponent(dependency).getMetadata()
				).array(),
			);
		}

		void saveMetaData(string target)
		{
			std.file.write(buildPath(target, "digger-metadata.json"), getMetadata().toJson());
			// Use a separate file to avoid double-encoding JSON
			std.file.write(buildPath(target, "digger-config.json"), configString);
		}

		/// Calculates the cache key, which should be unique and immutable
		/// for the same source, build parameters, and build algorithm.
		string getBuildID()
		{
			return "%s-%s-%s".format(
				name,
				commit,
				getMetadata().toJson().getDigestString!MD5().toLower(),
			);
		}

		@property string sourceDir() { submodule.needRepo(); return submodule.git.path; }

		/// Directory to which built files are copied to.
		/// This will then be atomically added to the cache.
		protected string stageDir;

		/// Prepare the source checkout for this component.
		/// Usually needed by other components.
		void needSource()
		{
			tempError++; scope(success) tempError--;

			if (incrementalBuild)
				return;
			foreach (component; getSubmoduleComponents(submoduleName))
				component.haveBuild = false;
			submodule.needHead(commit);
		}

		private bool haveBuild;

		/// Build the component in-place, as needed,
		/// without moving the built files anywhere.
		/// Prepare dependencies as needed.
		void needBuild()
		{
			if (haveBuild) return;
			scope(success) haveBuild = true;

			log("needBuild: " ~ getBuildID());

			if (sourceDeps.length || buildDeps.length || installDeps.length)
			{
				log("Checking dependencies...");

				foreach (dependency; sourceDeps)
					getComponent(dependency).needSource();
				foreach (dependency; buildDeps)
					getComponent(dependency).needBuild();
				foreach (dependency; installDeps)
					getComponent(dependency).needInstalled();
			}

			needSource();

			log("Building " ~ getBuildID());
			submodule.clean = false;
			performBuild();
			log(getBuildID() ~ " built OK!");
		}

		private bool haveInstalled;

		/// Build and "install" the component to buildDir as necessary.
		void needInstalled()
		{
			if (haveInstalled) return;
			scope(success) haveInstalled = true;

			auto buildID = getBuildID();
			log("needInstalled: " ~ buildID);

			needCacheEngine();
			if (cacheEngine.haveEntry(buildID))
			{
				log("Cache hit!");
				if (cacheEngine.listFiles(buildID).canFind(unbuildableMarker))
					throw new Exception(buildID ~ " was cached as unbuildable");
			}
			else
			{
				log("Cache miss.");

				auto tempDir = buildPath(config.local.workDir, "temp");
				if (tempDir.exists)
					tempDir.removeRecurse();
				stageDir = buildPath(tempDir, buildID);
				stageDir.mkdirRecurse();

				bool failed = false;
				tempError = 0;

				// Save the results to cache, failed or not
				scope (exit)
				{
					// tempDir might be removed by a dependency's build failure.
					if (!tempDir.exists)
						log("Not caching dependency build failure.");
					else
					// Don't cache failed build results due to temporary/environment problems
					if (failed && tempError > 0)
					{
						log("Not caching build failure due to temporary/environment error.");
						rmdirRecurse(tempDir);
					}
					else
					// Don't cache failed build results during delve
					if (failed && !config.cacheFailures)
					{
						log("Not caching failed build.");
						rmdirRecurse(tempDir);
					}
					else
					if (cacheEngine.haveEntry(buildID))
					{
						// Can happen due to force==true
						log("Already in cache.");
						rmdirRecurse(tempDir);
					}
					else
					{
						log("Saving to cache.");
						saveMetaData(stageDir);
						cacheEngine.add(buildID, stageDir);
						rmdirRecurse(tempDir);
					}
				}

				// An incomplete build is useless, nuke the directory
				// and create a new one just for the "unbuildable" marker.
				scope (failure)
				{
					failed = true;
					if (stageDir.exists)
					{
						rmdirRecurse(stageDir);
						mkdir(stageDir);
						buildPath(stageDir, unbuildableMarker).touch();
					}
				}

				needBuild();

				performStage();
			}

			install();
			updateEnv();
		}

		/// Build the component in-place, without moving the built files anywhere.
		void performBuild() {}

		/// Place resulting files to stageDir
		void performStage() {}

		/// Update the environment post-install, to allow
		/// building components that depend on this one.
		void updateEnv() {}

		/// Copy build results from cacheDir to buildDir
		void install()
		{
			log("Installing " ~ getBuildID());
			needCacheEngine().extract(getBuildID(), buildDir, de => !de.baseName.startsWith("digger-"));
		}

	protected final:
		// Utility declarations for component implementations

		@property string modelSuffix() { return commonConfig.model == CommonConfig.defaultModel ? "" : commonConfig.model; }
		version (Windows)
		{
			enum string makeFileName = "win32.mak";
			@property string makeFileNameModel() { return "win"~commonConfig.model~".mak"; }
			enum string binExt = ".exe";
		}
		else
		{
			enum string makeFileName = "posix.mak";
			enum string makeFileNameModel = "posix.mak";
			enum string binExt = "";
		}

		@property string make()
		{
			return config.env.get("MAKE", "make");
		}

		@property string[] platformMakeVars()
		{
			string[] args;

			args ~= "MODEL=" ~ commonConfig.model;

			version (Windows)
				if (commonConfig.model == "64")
				{
					args ~= "VCDIR="  ~ config.deps.vsDir .absolutePath() ~ `\VC`;
					args ~= "SDKDIR=" ~ config.deps.sdkDir.absolutePath();
				}

			return args;
		}

		/// Older versions did not use the posix.mak/win32.mak convention.
		static string findMakeFile(string fn)
		{
			version (OSX)
				if (!fn.exists && "osx.mak".exists)
					return "osx.mak";
			version (Posix)
				if (!fn.exists && "linux.mak".exists)
					return "linux.mak";
			return fn;
		}

		void needCC(string dmcVer = null)
		{
			version(Windows)
			{
				needDMC(dmcVer); // We need DMC even for 64-bit builds (for DM make)
				if (commonConfig.model == "64")
					needVC();
			}
		}

		void run(string[] args, ref string[string] newEnv)
		{
			log("Running: " ~ escapeShellCommand(args));

			if (newEnv is null) newEnv = environment.toAA();
			string oldPath = environment["PATH"];
			scope (exit) environment["PATH"] = oldPath;
			environment["PATH"] = newEnv["PATH"];
			log("PATH=" ~ newEnv["PATH"]);

			auto status = spawnProcess(args, newEnv, std.process.Config.newEnv).wait();
			enforce(status == 0, "Command %s failed with status %d".format(args, status));
		}

		void run(string[] args...)
		{
			run(args, config.env);
		}
	}

	final class DMD : Component
	{
		@property override string submoduleName() { return "dmd"; }
		@property override string[] sourceDeps () { return []; }
		@property override string[] buildDeps  () { return []; }
		@property override string[] installDeps() { return []; }

		struct Config
		{
			/// Whether to build a debug DMD.
			/// Debug builds are faster to build,
			/// but run slower. Windows only.
			bool debugDMD = false;

			/// Instead of downloading a pre-built binary DMD package,
			/// build it from source starting with the last C++-only version.
			bool bootstrap;
		}

		Config buildConfig;

		@property override string configString()
		{
			if (buildConfig == Config.init)
			{
				// Avoid changing all cache keys by adding new fields
				return `{"debugDMD":false}`;
			}
			else
				return buildConfig.toJson();
		}

		override void performBuild()
		{
			// We need an older DMC for older DMD versions
			string dmcVer = null;
			auto idgen = buildPath(sourceDir, "src", "idgen.c");
			if (idgen.exists && idgen.readText().indexOf(`{ "alignof" },`) >= 0)
				dmcVer = "850";

			needCC(dmcVer); // Need VC too for VSINSTALLDIR

			if (buildPath(sourceDir, "src", "idgen.d").exists)
			{
				// Required for bootstrapping.
				needDMD("2.067.1", config.build.components.dmd.bootstrap);
			}

			version (Windows)
				auto scRoot = config.deps.dmcDir.absolutePath();

			{
				auto owd = pushd(buildPath(sourceDir, "src"));

				string dmdMakeFileName = findMakeFile(makeFileName);

				string modelFlag = commonConfig.model;
				if (dmdMakeFileName.readText().canFind("MODEL=-m32"))
					modelFlag = "-m" ~ modelFlag;

				version (Windows)
				{
					// A make argument is insufficient,
					// because of recursive make invocations
					auto m = dmdMakeFileName.readText();
					m = m
						.replace(`CC=\dm\bin\dmc`, `CC=dmc`)
						.replace(`SCROOT=$D\dm`, `SCROOT=` ~ scRoot)
					;
					dmdMakeFileName.write(m);
				}
				else
				{
					auto m = dmdMakeFileName.readText();
					m = m
						// Fix hard-coded reference to gcc as linker
						.replace(`gcc -m32 -lstdc++`, `g++ -m32 -lstdc++`)
						.replace(`gcc $(MODEL) -lstdc++`, `g++ $(MODEL) -lstdc++`)
					;
					// Fix pthread linker error
					version (linux)
						m = m.replace(`-lpthread`, `-pthread`);
					dmdMakeFileName.write(m);
				}

				string[] targets = buildConfig.debugDMD ? [] : ["dmd"];
				run([make,
						"-f", dmdMakeFileName,
						"MODEL=" ~ modelFlag,
						"HOST_DC=" ~ config.deps.hostDC,
					] ~ commonConfig.makeArgs ~ targets,
				);
			}
		}

		override void performStage()
		{
			cp(
				buildPath(sourceDir, "src", "dmd" ~ binExt),
				buildPath(stageDir , "bin", "dmd" ~ binExt),
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
				ini = ini.replace("__DMC__", config.deps.dmcDir.buildPath(`bin`).absolutePath());
				ini = ini.replace("__VS__" , config.deps.vsDir .absolutePath());
				ini = ini.replace("__SDK__", config.deps.sdkDir.absolutePath());

				buildPath(stageDir, "bin", "sc.ini").write(ini);
			}
			else version (OSX)
			{
				auto ini = q"EOS
[Environment]
DFLAGS="-I%@P%/../import" "-L-L%@P%/../lib"
EOS";
				buildPath(stageDir, "bin", "dmd.conf").write(ini);
			}
			else
			{
				auto ini = q"EOS
[Environment]
DFLAGS="-I%@P%/../import" "-L-L%@P%/../lib" -L--export-dynamic
EOS";
				buildPath(stageDir, "bin", "dmd.conf").write(ini);
			}
		}

		override void updateEnv()
		{
			// Add the DMD we built for Phobos/Druntime/Tools
			config.env["PATH"] ~= pathSeparator ~ buildPath(buildDir, "bin").absolutePath();
		}
	}

	// In older versions of D, Druntime depended on Phobos modules.
	final class PhobosIncludes : Component
	{
		@property override string submoduleName() { return "phobos"; }
		@property override string[] sourceDeps () { return []; }
		@property override string[] buildDeps  () { return []; }
		@property override string[] installDeps() { return []; }
		@property override string configString() { return null; }

		override void performStage()
		{
			foreach (f; ["std", "etc", "crc32.d"])
				if (buildPath(sourceDir, f).exists)
					cp(
						buildPath(sourceDir, f),
						buildPath(stageDir , "import", f),
					);
		}
	}

	final class Druntime : Component
	{
		@property override string submoduleName() { return "druntime"; }
		@property override string[] sourceDeps () { return ["phobos"]; }
		@property override string[] buildDeps  () { return ["dmd"]; }
		@property override string[] installDeps() { return ["phobos-includes"]; }
		@property override string configString() { return null; }

		override void performBuild()
		{
			needCC();

			{
				auto owd = pushd(sourceDir);

				mkdirRecurse("import");
				mkdirRecurse("lib");

				setTimes(buildPath("src", "rt", "minit.obj"), Clock.currTime(), Clock.currTime());

				run([make, "-f", makeFileNameModel, "import"] ~ commonConfig.makeArgs ~ platformMakeVars);
				run([make, "-f", makeFileNameModel          ] ~ commonConfig.makeArgs ~ platformMakeVars);
			}
		}

		override void performStage()
		{
			cp(
				buildPath(sourceDir, "import"),
				buildPath(stageDir , "import"),
			);
		}
	}

	final class Phobos : Component
	{
		@property override string submoduleName() { return "phobos"; }
		@property override string[] sourceDeps () { return []; }
		@property override string[] buildDeps  () { return ["dmd", "druntime"]; }
		@property override string[] installDeps() { return []; }
		@property override string configString() { return null; }

		string[] targets;

		override void performBuild()
		{
			needCC();

			{
				auto owd = pushd(sourceDir);
				string phobosMakeFileName = findMakeFile(makeFileNameModel);

				version (Windows)
				{
					auto lib = "phobos%s.lib".format(modelSuffix);
					run([make, "-f", phobosMakeFileName, lib] ~ commonConfig.makeArgs ~ platformMakeVars);
					enforce(lib.exists);
					targets = ["phobos%s.lib".format(modelSuffix)];
				}
				else
				{
					run([make, "-f", phobosMakeFileName] ~ commonConfig.makeArgs ~ platformMakeVars);
					targets = "generated".dirEntries(SpanMode.depth).filter!(de => de.name.endsWith(".a")).map!(de => de.name).array();
				}
			}
		}

		override void performStage()
		{
			assert(targets.length, "Druntime stage without build");
			foreach (lib; targets)
				cp(
					buildPath(sourceDir, lib),
					buildPath(stageDir , "lib", lib.baseName()),
				);
		}
	}

	final class RDMD : Component
	{
		@property override string submoduleName() { return "tools"; }
		@property override string[] sourceDeps () { return []; }
		@property override string[] buildDeps  () { return []; }
		@property override string[] installDeps() { return ["dmd", "druntime", "phobos"]; }
		@property override string configString() { return null; }

		override void performBuild()
		{
			needCC();

			// Just build rdmd
			{
				auto owd = pushd(sourceDir);

				bool needModel; // Need -mXX switch?

				if (sourceDir.buildPath("posix.mak").exists)
					needModel = true; // Known to be needed for recent versions

				if (!needModel)
					try
						run(["dmd", "rdmd"]);
					catch (Exception e)
						needModel = true;

				if (needModel)
					run(["dmd", "-m" ~ commonConfig.model, "rdmd"]);
			}
		}

		override void performStage()
		{
			cp(
				buildPath(sourceDir, "rdmd" ~ binExt),
				buildPath(stageDir , "bin", "rdmd" ~ binExt),
			);
		}
	}

	private int tempError;

	private Component[string] components;

	Component getComponent(string name)
	{
		if (name !in components)
		{
			Component c;

			switch (name)
			{
				case "dmd":
				{
					auto cc = new DMD();
					cc.buildConfig = config.build.components.dmd;
					c = cc;
					break;
				}
				case "phobos-includes":
					c = new PhobosIncludes();
					break;
				case "druntime":
					c = new Druntime();
					break;
				case "phobos":
					c = new Phobos();
					break;
				case "rdmd":
					c = new RDMD();
					break;
				default:
					throw new Exception("Unknown component: " ~ name);
			}

			c.name = name;
			c.commonConfig = config.build.components.common;
			return components[name] = c;
		}

		return components[name];
	}

	Component[] getSubmoduleComponents(string submoduleName)
	{
		return components
			.byValue
			.filter!(component => component.submoduleName == submoduleName)
			.array();
	}

	// **************************** Customization ****************************

	/// Fetch latest D history.
	void update()
	{
		getMetaRepo().update();
	}

	struct SubmoduleState
	{
		string[string] submoduleCommits;
	}

	/// Begin customization, starting at the specified commit.
	SubmoduleState begin(string commit)
	{
		log("Starting at meta repository commit " ~ commit);
		return SubmoduleState(getMetaRepo().getSubmoduleCommits(commit));
	}

	/// Applies a merge onto the given SubmoduleState.
	void merge(ref SubmoduleState submoduleState, string submoduleName, string branch)
	{
		log("Merging %s commit %s".format(submoduleName, branch));
		enforce(submoduleName in submoduleState.submoduleCommits, "Unknown submodule: " ~ submoduleName);
		auto submodule = getSubmodule(submoduleName);
		auto head = submoduleState.submoduleCommits[submoduleName];
		auto result = submodule.getMerge(head, branch);
		submoduleState.submoduleCommits[submoduleName] = result;
	}

	/// Removes a merge from the given SubmoduleState.
	void unmerge(ref SubmoduleState submoduleState, string submoduleName, string branch)
	{
		log("Unmerging %s commit %s".format(submoduleName, branch));
		enforce(submoduleName in submoduleState.submoduleCommits, "Unknown submodule: " ~ submoduleName);
		auto submodule = getSubmodule(submoduleName);
		auto head = submoduleState.submoduleCommits[submoduleName];
		auto result = submodule.getUnMerge(head, branch);
		submoduleState.submoduleCommits[submoduleName] = result;
	}

	/// Returns the commit hash for the given pull request #.
	/// The result can then be used with addMerge/removeMerge.
	string getPull(string submoduleName, int pullNumber)
	{
		return getSubmodule(submoduleName).getPull(pullNumber);
	}

	/// Returns the commit hash for the given GitHub fork.
	/// The result can then be used with addMerge/removeMerge.
	string getFork(string submoduleName, string user, string branch)
	{
		return getSubmodule(submoduleName).getFork(user, branch);
	}

	// ****************************** Building *******************************

	private SubmoduleState submoduleState;
	private bool incrementalBuild;

	@property string cacheEngineName()
	{
		if (incrementalBuild)
			return "temp";
		else
			return config.cache;
	}

	private string getComponentCommit(string componentName)
	{
		auto submoduleName = getComponent(componentName).submoduleName;
		auto commit = submoduleState.submoduleCommits.get(submoduleName, null);
		enforce(commit, "Unknown commit to build for component %s (submodule %s)"
			.format(componentName, submoduleName));
		return commit;
	}

	static const string[] defaultComponents = ["dmd", "druntime", "phobos-includes", "phobos", "rdmd"];
	static const string[] allComponents = defaultComponents;

	/// Build the specified components according to the specified configuration.
	void build(SubmoduleState submoduleState, Config.Build buildConfig, bool incremental = false)
	{
		auto componentNames = buildConfig.components.getEnabledComponentNames();
		log("Building components %-(%s, %)".format(componentNames));

		this.components = null;
		this.submoduleState = submoduleState;
		this.config.build = buildConfig;
		this.incrementalBuild = incremental;
		prepareEnv();

		if (buildDir.exists)
			buildDir.removeRecurse();
		enforce(!buildDir.exists);

		scope(success) if (cacheEngine) cacheEngine.finalize();

		foreach (componentName; componentNames)
			getComponent(componentName).needInstalled();
	}

	/// Shortcut for begin + build
	void buildRev(string rev, Config.Build buildConfig)
	{
		auto submoduleState = begin(rev);
		build(submoduleState, buildConfig);
	}

	/// Rerun build without cleaning up any files.
	void rebuild(Config.Build buildConfig)
	{
		build(SubmoduleState(null), buildConfig, true);
	}

	bool isCached(SubmoduleState submoduleState, Config.Build buildConfig)
	{
		this.components = null;
		this.submoduleState = submoduleState;
		this.config.build = buildConfig;

		needCacheEngine();
		foreach (componentName; buildConfig.components.getEnabledComponentNames())
			if (!cacheEngine.haveEntry(getComponent(componentName).getBuildID()))
				return false;
		return true;
	}

	/// Returns the isCached state for all commits in the history of the given ref.
	bool[string] getCacheState(string[string][string] history, Config.Build buildConfig)
	{
		log("Enumerating cache entries...");
		auto cacheEntries = needCacheEngine().getEntries().toSet();

		this.config.build = buildConfig;

		this.components = null;
		auto componentNames = buildConfig.components.getEnabledComponentNames();
		auto components = componentNames.map!(componentName => getComponent(componentName)).array;
		auto requiredSubmodules = components
			.map!(component => chain(component.sourceDeps, component.buildDeps, component.installDeps))
			.joiner
			.map!(componentName => getComponent(componentName).submoduleName)
			.array.sort().uniq().array
		;

		log("Collating cache state...");
		bool[string] result;
		foreach (commit, submoduleCommits; history)
		{
			this.submoduleState.submoduleCommits = submoduleCommits;

			result[commit] =
				requiredSubmodules.all!(submoduleName => submoduleName in submoduleCommits) &&
				componentNames.all!(componentName =>
					getComponent(componentName).I!(component =>
						component.getBuildID() in cacheEntries
					)
				);
		}
		return result;
	}

	/// ditto
	bool[string] getCacheState(string[] refs, Config.Build buildConfig)
	{
		auto history = getMetaRepo().getSubmoduleHistory(refs);
		return getCacheState(history, buildConfig);
	}

	// **************************** Dependencies *****************************

	private void needInstaller()
	{
		Installer.logger = &log;
		Installer.installationDirectory = dlDir;
	}

	void needDMD(string dmdVer, bool bootstrap)
	{
		tempError++; scope(success) tempError--;

		if (!config.deps.hostDC)
		{
			log("Preparing DMD");
			if (bootstrap)
			{
				auto dir = buildPath(config.local.workDir, "bootstrap", "dmd-" ~ dmdVer);
				void bootstrapDMDProxy(string target) { return bootstrapDMD(dmdVer, target); } // https://issues.dlang.org/show_bug.cgi?id=14580
				cached!bootstrapDMDProxy(dir);
				config.deps.hostDC = buildPath(dir, "bin", "dmd" ~ binExt);
			}
			else
			{
				needInstaller();
				auto dmdInstaller = new DMDInstaller(dmdVer);
				dmdInstaller.requireLocal(false);
				config.deps.hostDC = dmdInstaller.exePath("dmd").absolutePath();
			}
			log("hostDC=" ~ config.deps.hostDC);
		}
	}

	final void bootstrapDMD(string ver, string target)
	{
		log("Bootstrapping DMD v" ~ ver);

		// Back up and move out of the way the current build directory
		auto tmpDir = buildDir ~ ".tmp-bootstrap-" ~ ver;
		if (tmpDir.exists) tmpDir.rmdirRecurse();
		if (buildDir.exists) buildDir.rename(tmpDir);
		scope(exit) if (tmpDir.exists) tmpDir.rename(buildDir);

		// Back up and clear component state
		enum backupTemplate = q{
			auto VARBackup = this.VAR;
			scope(exit) this.VAR = VARBackup;
		};
		mixin(backupTemplate.replace(q{VAR}, q{components}));
		mixin(backupTemplate.replace(q{VAR}, q{config}));

		components = null;

		getMetaRepo().needRepo();
		auto rev = getMetaRepo().getRef("refs/tags/v" ~ ver);
		log("Resolved v" ~ ver ~ " to " ~ rev);
		buildRev(rev, config.build);
		ensurePathExists(target);
		rename(buildDir, target);
	}

	version (Windows)
	void needDMC(string ver = null)
	{
		tempError++; scope(success) tempError--;

		if (!config.deps.dmcDir)
		{
			log("Preparing DigitalMars C++");
			needInstaller();

			auto dmc = ver ? new LegacyDMCInstaller(ver) : dmcInstaller;
			dmc.requireLocal(false);
			config.deps.dmcDir = dmc.directory;

			auto binPath = buildPath(config.deps.dmcDir, `bin`).absolutePath();
			log("DMC=" ~ binPath);
			config.env["DMC"] = binPath;
			config.env["PATH"] = binPath ~ pathSeparator ~ config.env["PATH"];
		}
	}

	version (Windows)
	void needVC()
	{
		tempError++; scope(success) tempError--;

		if (!config.deps.vsDir)
		{
			log("Preparing Visual C++");
			needInstaller();

			auto vs = vs2013community;
			vs.requirePackages(
				[
					"vcRuntimeMinimum_x86",
					"vc_compilercore86",
					"vc_compilercore86res",
					"vc_compilerx64nat",
					"vc_compilerx64natres",
					"vc_librarycore86",
					"vc_libraryDesktop_x64",
					"win_xpsupport",
				],
			);
			vs.requireLocal(false);
			config.deps.vsDir  = vs.directory.buildPath("Program Files (x86)", "Microsoft Visual Studio 12.0").absolutePath();
			config.deps.sdkDir = vs.directory.buildPath("Program Files", "Microsoft SDKs", "Windows", "v7.1A").absolutePath();
			config.env["PATH"] ~= pathSeparator ~ vs.directory.buildPath("Windows", "system32").absolutePath();
		}
	}

	private void needGit()
	{
		tempError++; scope(success) tempError--;

		needInstaller();
		gitInstaller.require();
	}

	/// Prepare the build environment (dEnv).
	protected void prepareEnv()
	{
		config.env = null;
		config.deps = config.deps.init;

		// Build a new environment from scratch, to avoid tainting the build with the current environment.
		string[] newPaths;

		version (Windows)
		{
			import std.utf;
			import win32.winbase;
			import win32.winnt;

			TCHAR[1024] buf;
			auto winDir = buf[0..GetWindowsDirectory(buf.ptr, buf.length)].toUTF8();
			auto sysDir = buf[0..GetSystemDirectory (buf.ptr, buf.length)].toUTF8();
			auto tmpDir = buf[0..GetTempPath(buf.length, buf.ptr)].toUTF8()[0..$-1];
			newPaths ~= [sysDir, winDir];
		}
		else
			newPaths = ["/bin", "/usr/bin"];

		config.env["PATH"] = newPaths.join(pathSeparator);

		version (Windows)
		{
			config.env["TEMP"] = config.env["TMP"] = tmpDir;
			config.env["SystemRoot"] = winDir;
		}
	}

	final void applyEnv(in string[string] env)
	{
		auto oldEnv = environment.toAA();
		foreach (name, value; this.config.env)
			oldEnv[name] = value;
		foreach (name, value; env)
		{
			string newValue = value;
			foreach (oldName, oldValue; oldEnv)
				newValue = newValue.replace("%" ~ oldName ~ "%", oldValue);
			config.env[name] = oldEnv[name] = newValue;
		}
	}

	// ******************************** Cache ********************************

	enum unbuildableMarker = "unbuildable";

	DCache cacheEngine;

	DCache needCacheEngine()
	{
		if (!cacheEngine)
		{
			if (cacheEngineName == "git")
				needGit();
			cacheEngine = createCache(cacheEngineName, cacheEngineDir(cacheEngineName), this);
		}
		return cacheEngine;
	}

	void cp(string src, string dst)
	{
		needCacheEngine().cp(src, dst);
	}

	private string[] getComponentKeyOrder(string componentName)
	{
		auto submodule = getComponent(componentName).submodule;
		submodule.needRepo();
		return submodule
			.git.query("log", "--pretty=format:%H", "--all", "--topo-order")
			.splitLines()
			.map!(commit => componentName ~ "-" ~ commit ~ "-")
			.array
		;
	}

	string componentNameFromKey(string key)
	{
		auto parts = key.split("-");
		return parts[0..$-2].join("-");
	}

	string[][] getKeyOrder(string key)
	{
		if (key !is null)
			return [getComponentKeyOrder(componentNameFromKey(key))];
		else
			return allComponents.map!(componentName => getComponentKeyOrder(componentName)).array;
	}

	/// Optimize entire cache.
	void optimizeCache()
	{
		needCacheEngine().optimize();
	}

	bool shouldPurge(string key)
	{
		auto files = cacheEngine.listFiles(key);
		if (files.canFind(unbuildableMarker))
			return true;

		if (componentNameFromKey(key) == "druntime")
		{
			if (!files.canFind("import/core/memory.d")
			 && !files.canFind("import/core/memory.di"))
				return true;
		}

		return false;
	}

	/// Delete cached "unbuildable" build results.
	void purgeUnbuildable()
	{
		needCacheEngine()
			.getEntries
			.filter!(key => shouldPurge(key))
			.each!((key)
			{
				log("Deleting: " ~ key);
				cacheEngine.remove(key);
			})
		;
	}

	/// Move cached files from one cache engine to another.
	void migrateCache(string sourceEngineName, string targetEngineName)
	{
		auto sourceEngine = createCache(sourceEngineName, cacheEngineDir(sourceEngineName), this);
		auto targetEngine = createCache(targetEngineName, cacheEngineDir(targetEngineName), this);
		auto tempDir = buildPath(config.local.workDir, "temp");
		if (tempDir.exists)
			tempDir.removeRecurse();
		log("Enumerating source entries...");
		auto sourceEntries = sourceEngine.getEntries();
		log("Enumerating target entries...");
		auto targetEntries = targetEngine.getEntries().sort();
		foreach (key; sourceEntries)
			if (!targetEntries.canFind(key))
			{
				log(key);
				sourceEngine.extract(key, tempDir, fn => true);
				targetEngine.add(key, tempDir);
				if (tempDir.exists)
					tempDir.removeRecurse();
			}
		targetEngine.optimize();
	}

	// **************************** Miscellaneous ****************************

	struct LogEntry
	{
		string hash;
		string[] message;
		SysTime time;
	}

	/// Gets the D merge log (newest first).
	LogEntry[] getLog(string refName = "refs/remotes/origin/master")
	{
		getMetaRepo().needRepo();
		auto history = getMetaRepo().git.getHistory();
		LogEntry[] logs;
		auto master = history.commits[history.refs[refName]];
		for (auto c = master; c; c = c.parents.length ? c.parents[0] : null)
		{
			auto time = SysTime(c.time.unixTimeToStdTime);
			logs ~= LogEntry(c.hash.toString(), c.message, time);
		}
		return logs;
	}

	// ***************************** Integration *****************************

	/// Override to add logging.
	void log(string line)
	{
	}

	/// Override this method with one which returns a command,
	/// which will invoke the unmergeRebaseEdit function below,
	/// passing to it any additional parameters.
	/// Note: Currently unused. Was previously used
	/// for unmerging things using interactive rebase.
	abstract string getCallbackCommand();

	void callback(string[] args) { assert(false); }
}
