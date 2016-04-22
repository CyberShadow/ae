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
import std.process : spawnProcess, wait, escapeShellCommand;
import std.range;
import std.regex;
import std.string;
import std.typecons;

import ae.sys.d.cache;
import ae.sys.d.repo;
import ae.sys.file;
import ae.sys.git;
import ae.utils.aa;
import ae.utils.array;
import ae.utils.digest;
import ae.utils.json;
import ae.utils.regex;

version (Windows)
{
	import ae.sys.install.dmc;
	import ae.sys.install.msys;
	import ae.sys.install.vs;

	extern(Windows) void SetErrorMode(int);
}

import ae.sys.install.dmd;
import ae.sys.install.git;
import ae.sys.install.kindlegen;

static import std.process;

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
					foreach (componentName; enable.byKey)
						enforce(allComponents.canFind(componentName), "Unknown component: " ~ componentName);
					return allComponents
						.filter!(componentName =>
							enable.get(componentName, defaultComponents.canFind(componentName)))
						.array
						.dup;
				}

				Component.CommonConfig common;
				DMD.Config dmd;
				Website.Config website;
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

		/// If present, passed to make via -j parameter.
		/// Can also be "auto" or "unlimited".
		string makeJobs;

		/// Don't get latest updates from GitHub.
		bool offline;

		/// Automatically re-clone the repository in case
		/// "git reset --hard" fails.
		bool autoClean;

		/// How to cache built files.
		string cache;

		/// Whether we should cache failed builds.
		bool cacheFailures = true;

		/// Additional environment variables.
		/// Supports %VAR% expansion - see applyEnv.
		string[string] environment;
	}
	Config config; /// ditto

	/// Current build environment.
	struct Environment
	{
		struct Deps /// Configuration for software dependencies
		{
			string dmcDir;   /// Where dmc.zip is unpacked.
			string vsDir;    /// Where Visual Studio is installed
			string sdkDir;   /// Where the Windows SDK is installed
			string hostDC;   /// Host D compiler (for DDMD bootstrapping)
		}
		Deps deps; /// ditto

		/// Calculated local environment, incl. dependencies
		string[string] vars;
	}

	/// Get a specific subdirectory of the work directory.
	@property string subDir(string name)() { return buildPath(config.local.workDir, name); }

	alias repoDir    = subDir!"repo";        /// The git repository location.
	alias buildDir   = subDir!"build";       /// The build directory.
	alias dlDir      = subDir!"dl";          /// The directory for downloaded software.

	/// This number increases with each incompatible change to cached data.
	enum cacheVersion = 3;

	string cacheEngineDir(string engineName)
	{
		// Keep compatibility with old cache paths
		string engineDirName =
			engineName.isOneOf("directory", "true") ? "cache"      :
			engineName.isOneOf("", "none", "false") ? "temp-cache" :
			"cache-" ~ engineName;
		return buildPath(
			config.local.workDir,
			engineDirName,
			"v%d".format(cacheVersion),
		);
	}

	version (Windows)
	{
		enum string binExt = ".exe";
		enum configFileName = "sc.ini";
	}
	else
	{
		enum string binExt = "";
		enum configFileName = "dmd.conf";
	}

	static bool needConfSwitch() { return exists(std.process.environment.get("HOME", null).buildPath(configFileName)); }

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
				return (*pcacheEntry).dup;

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
			return result.dup;
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

		override void needHead(string hash)
		{
			if (!config.autoClean)
				super.needHead(hash);
			else
			try
				super.needHead(hash);
			catch (RepositoryCleanException e)
			{
				log("Error during repository cleanup.");

				log("Nuking %s...".format(dir));
				rmdirRecurse(dir);

				auto name = baseName(dir);
				auto gitDir = buildPath(dirName(dir), ".git", "modules", name);
				log("Nuking %s...".format(gitDir));
				rmdirRecurse(gitDir);

				log("Updating submodule...");
				getMetaRepo().git.run(["submodule", "update", name]);

				reset();

				log("Trying again...");
				super.needHead(hash);
			}
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
		assert(name, "This component is not associated with a submodule");
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
			                   /// e.g. "HOST_CC=g++48"
		}
		CommonConfig commonConfig; // TODO: This is always a copy of config.build.components.common. DRY or allow per-component customization

		/// Commit in the component's repo from which to build this component.
		@property string commit() { return incrementalBuild ? "incremental" : getComponentCommit(name); }

		/// The components the source code of which this component depends on.
		/// Used for calculating the cache key.
		@property abstract string[] sourceDependencies();

		/// The components the state and configuration of which this component depends on.
		/// Used for calculating the cache key.
		@property abstract string[] dependencies();

		/// This metadata is saved to a .json file,
		/// and is also used to calculate the cache key.
		struct Metadata
		{
			int cacheVersion;
			string name;
			string commit;
			CommonConfig commonConfig;
			string[] sourceDepCommits;
			Metadata[] dependencyMetadata;
		}

		Metadata getMetadata() /// ditto
		{
			return Metadata(
				cacheVersion,
				name,
				commit,
				commonConfig,
				sourceDependencies.map!(
					dependency => getComponent(dependency).commit
				).array(),
				dependencies.map!(
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
			auto configBlob = getMetadata().toJson() ~ configString;
			return "%s-%s-%s".format(
				name,
				commit,
				configBlob.getDigestString!MD5().toLower(),
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
			if (!submoduleName)
				return;
			foreach (component; getSubmoduleComponents(submoduleName))
				component.haveBuild = false;

			submodule.needHead(commit);
		}

		private bool haveBuild;

		/// Build the component in-place, as needed,
		/// without moving the built files anywhere.
		void needBuild()
		{
			if (haveBuild) return;
			scope(success) haveBuild = true;

			log("needBuild: " ~ getBuildID());

			needSource();

			log("Building " ~ getBuildID());
			if (submoduleName)
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
				void saveToCache()
				{
					// Use a separate function to work around
					// "cannot put scope(success) statement inside scope(exit)"

					tempError++; scope(success) tempError--;

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

				scope (exit)
					saveToCache();

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
		}

		/// Build the component in-place, without moving the built files anywhere.
		void performBuild() {}

		/// Place resulting files to stageDir
		void performStage() {}

		/// Update the environment post-install, to allow
		/// building components that depend on this one.
		void updateEnv(ref Environment env) {}

		/// Copy build results from cacheDir to buildDir
		void install()
		{
			log("Installing " ~ getBuildID());
			needCacheEngine().extract(getBuildID(), buildDir, de => !de.baseName.startsWith("digger-"));
		}

		/// Prepare the dependencies then run the component's tests.
		void test()
		{
			log("Testing " ~ getBuildID());

			needSource();

			submodule.clean = false;
			performTest();
			log(getBuildID() ~ " tests OK!");
		}

		/// Run the component's tests.
		void performTest() {}

	protected final:
		// Utility declarations for component implementations

		@property string modelSuffix() { return commonConfig.model == "32" ? "" : commonConfig.model; }
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

		/// Returns the command for the make utility.
		string[] getMake(in ref Environment env)
		{
			return [env.vars.get("MAKE", "make")];
		}

		/// Returns the path to the built dmd executable.
		@property string dmd() { return buildPath(buildDir, "bin", "dmd" ~ binExt).absolutePath(); }

		string[] getPlatformMakeVars(in ref Environment env)
		{
			string[] args;

			args ~= "MODEL=" ~ commonConfig.model;

			version (Windows)
				if (commonConfig.model == "64")
				{
					args ~= "VCDIR="  ~ env.deps.vsDir .absolutePath() ~ `\VC`;
					args ~= "SDKDIR=" ~ env.deps.sdkDir.absolutePath();
				}

			return args;
		}

		@property string[] gnuMakeArgs()
		{
			string[] args;
			if (config.makeJobs)
			{
				if (config.makeJobs == "auto")
				{
					import std.parallelism, std.conv;
					args ~= "-j" ~ text(totalCPUs);
				}
				else
				if (config.makeJobs == "unlimited")
					args ~= "-j";
				else
					args ~= "-j" ~ config.makeJobs;
			}
			return args;
		}

		@property string[] dMakeArgs()
		{
			version (Windows)
				return null; // On Windows, DigitalMars make is used for all makefiles except the dmd test suite
			else
				return gnuMakeArgs;
		}

		/// Older versions did not use the posix.mak/win32.mak convention.
		static string findMakeFile(string dir, string fn)
		{
			version (OSX)
				if (!dir.buildPath(fn).exists && dir.buildPath("osx.mak").exists)
					return "osx.mak";
			version (Posix)
				if (!dir.buildPath(fn).exists && dir.buildPath("linux.mak").exists)
					return "linux.mak";
			return fn;
		}

		void needCC(ref Environment env, string dmcVer = null)
		{
			version (Windows)
			{
				needDMC(env, dmcVer); // We need DMC even for 64-bit builds (for DM make)
				if (commonConfig.model == "64")
					needVC(env);
			}
		}

		void run(in string[] args, in string[string] newEnv, string dir)
		{
			log("Running: " ~ escapeShellCommand(args));

			// Apply user environment
			auto env = applyEnv(newEnv, config.environment);

			// Temporarily apply PATH from newEnv to our process,
			// so process creation lookup can use it.
			string oldPath = std.process.environment["PATH"];
			scope (exit) std.process.environment["PATH"] = oldPath;
			std.process.environment["PATH"] = env["PATH"];
			log("PATH=" ~ env["PATH"]);

			auto status = spawnProcess(args, env, std.process.Config.newEnv, dir).wait();
			enforce(status == 0, "Command %s failed with status %d".format(args, status));
		}
	}

	final class DMD : Component
	{
		@property override string submoduleName  () { return "dmd"; }
		@property override string[] sourceDependencies() { return []; }
		@property override string[] dependencies() { return []; }

		struct Config
		{
			/// Whether to build a debug DMD.
			/// Debug builds are faster to build,
			/// but run slower.
			@JSONOptional bool debugDMD = false;

			/// Instead of downloading a pre-built binary DMD package,
			/// build it from source starting with the last C++-only version.
			@JSONOptional bool bootstrap;

			/// Use Visual C++ to build DMD instead of DMC.
			/// Currently, this is a hack, as msbuild will consult the system
			/// registry and use the system-wide installation of Visual Studio.
			@JSONOptional bool useVC;
		}

		@property override string configString()
		{
			if (config.build.components.dmd == Config.init)
			{
				// Avoid changing all cache keys
				return null;
			}
			else
				return config.build.components.dmd.toJson();
		}

		@property string vsConfiguration() { return config.build.components.dmd.debugDMD ? "Debug" : "Release"; }
		@property string vsPlatform     () { return commonConfig.model == "64" ? "x64" : "Win32"; }

		override void performBuild()
		{
			// We need an older DMC for older DMD versions
			string dmcVer = null;
			auto idgen = buildPath(sourceDir, "src", "idgen.c");
			if (idgen.exists && idgen.readText().indexOf(`{ "alignof" },`) >= 0)
				dmcVer = "850";

			auto env = baseEnvironment;
			needCC(env, dmcVer); // Need VC too for VSINSTALLDIR

			if (buildPath(sourceDir, "src", "idgen.d").exists)
			{
				// Required for bootstrapping.
				needDMD(env);
			}

			auto srcDir = buildPath(sourceDir, "src");

			if (config.build.components.dmd.useVC)
			{
				version (Windows)
				{
					needVC(env);

					env.vars["PATH"] = env.vars["PATH"] ~ pathSeparator ~ env.deps.hostDC.dirName;

					return run(["msbuild", "/p:Configuration=" ~ vsConfiguration, "/p:Platform=" ~ vsPlatform, "dmd_msc_vs10.sln"], env.vars, srcDir);
				}
				else
					throw new Exception("Can only use Visual Studio on Windows");
			}

			version (Windows)
				auto scRoot = env.deps.dmcDir.absolutePath();

			string dmdMakeFileName = findMakeFile(srcDir, makeFileName);
			string dmdMakeFullName = srcDir.buildPath(dmdMakeFileName);

			string modelFlag = commonConfig.model;
			if (dmdMakeFullName.readText().canFind("MODEL=-m32"))
				modelFlag = "-m" ~ modelFlag;

			version (Windows)
			{
				// A make argument is insufficient,
				// because of recursive make invocations
				auto m = dmdMakeFullName.readText();
				m = m
					.replace(`CC=\dm\bin\dmc`, `CC=dmc`)
					.replace(`SCROOT=$D\dm`, `SCROOT=` ~ scRoot)
				;
				dmdMakeFullName.write(m);
			}
			else
			{
				auto m = dmdMakeFullName.readText();
				m = m
					// Fix hard-coded reference to gcc as linker
					.replace(`gcc -m32 -lstdc++`, `g++ -m32 -lstdc++`)
					.replace(`gcc $(MODEL) -lstdc++`, `g++ $(MODEL) -lstdc++`)
				;
				// Fix pthread linker error
				version (linux)
					m = m.replace(`-lpthread`, `-pthread`);
				dmdMakeFullName.write(m);
			}
			submodule.saveFileState("src/" ~ dmdMakeFileName);

			string[] extraArgs;
			version (posix)
				if (config.build.components.dmd.debugDMD)
					extraArgs ~= "DEBUG=1";

			string[] targets = config.build.components.dmd.debugDMD ? [] : ["dmd"];

			// Avoid HOST_DC reading ~/dmd.conf
			string hostDC = env.deps.hostDC;
			version (Posix)
			if (hostDC && needConfSwitch())
			{
				auto dcProxy = buildPath(config.local.workDir, "host-dc-proxy.sh");
				std.file.write(dcProxy, escapeShellCommand(["exec", hostDC, "-conf=" ~ buildPath(dirName(hostDC), configFileName)]) ~ ` "$@"`);
				setAttributes(dcProxy, octal!755);
				hostDC = dcProxy;
			}

			run(getMake(env) ~ [
					"-f", dmdMakeFileName,
					"MODEL=" ~ modelFlag,
					"HOST_DC=" ~ hostDC,
				] ~ commonConfig.makeArgs ~ dMakeArgs ~ extraArgs ~ targets,
				env.vars, srcDir
			);
		}

		override void performStage()
		{
			if (config.build.components.dmd.useVC)
			{
				foreach (ext; [".exe", ".pdb"])
					cp(
						buildPath(sourceDir, "src", "vcbuild", vsPlatform, vsConfiguration, "dmd_msc" ~ ext),
						buildPath(stageDir , "bin", "dmd" ~ ext),
					);
			}
			else
			{
				cp(
					buildPath(sourceDir, "src", "dmd" ~ binExt),
					buildPath(stageDir , "bin", "dmd" ~ binExt),
				);
			}

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

				auto env = baseEnvironment;
				needCC(env);

				ini = ini.replace("__DMC__", env.deps.dmcDir.buildPath(`bin`).absolutePath());
				ini = ini.replace("__VS__" , env.deps.vsDir .absolutePath());
				ini = ini.replace("__SDK__", env.deps.sdkDir.absolutePath());

				buildPath(stageDir, "bin", configFileName).write(ini);
			}
			else version (OSX)
			{
				auto ini = q"EOS
[Environment]
DFLAGS="-I%@P%/../import" "-L-L%@P%/../lib"
EOS";
				buildPath(stageDir, "bin", configFileName).write(ini);
			}
			else
			{
				auto ini = q"EOS
[Environment]
DFLAGS="-I%@P%/../import" "-L-L%@P%/../lib" -L--export-dynamic
EOS";
				buildPath(stageDir, "bin", configFileName).write(ini);
			}
		}

		override void updateEnv(ref Environment env)
		{
			// Add the DMD we built for Phobos/Druntime/Tools
			env.vars["PATH"] = buildPath(buildDir, "bin").absolutePath() ~ pathSeparator ~ env.vars["PATH"];
		}

		/// Escape a path for d_do_test's very "special" criteria.
		/// Spaces must be escaped, but there must be no double-quote at the end.
		private static string dDoTestEscape(string str)
		{
			return str.replaceAll(re!`\\([^\\ ]*? [^\\]*)(?=\\)`, `\"$1"`);
		}

		unittest
		{
			assert(dDoTestEscape(`C:\Foo boo bar\baz quuz\derp.exe`) == `C:\"Foo boo bar"\"baz quuz"\derp.exe`);
		}

		override void performTest()
		{
			foreach (dep; ["dmd", "druntime", "phobos"])
				getComponent(dep).needBuild();

			auto env = baseEnvironment;
			version (Windows)
			{
				// In this order so it uses the MSYS make
				needCC(env);
				needMSYS(env);

				disableCrashDialog();

				if (commonConfig.model != "32")
				{
					// Used by d_do_test (default is the system VS2010 install)
					auto cl = env.deps.vsDir.buildPath("VC", "bin", "x86_amd64", "cl.exe");
					env.vars["CC"] = dDoTestEscape(cl);
				}
			}

			auto makeArgs = getMake(env) ~ commonConfig.makeArgs ~ getPlatformMakeVars(env) ~ gnuMakeArgs;
			version (Windows)
			{
				makeArgs ~= ["OS=win" ~ commonConfig.model, "SHELL=bash"];
				if (commonConfig.model == "32")
				{
					auto extrasDir = needExtras();
					// The autotester seems to pass this via environment. Why does that work there???
					makeArgs ~= "LIB=" ~ extrasDir.buildPath("localextras-windows", "dmd2", "windows", "lib") ~ `;..\..\phobos`;
				}
			}

			run(makeArgs, env.vars, sourceDir.buildPath("test"));
		}
	}

	// In older versions of D, Druntime depended on Phobos modules.
	final class PhobosIncludes : Component
	{
		@property override string submoduleName() { return "phobos"; }
		@property override string[] sourceDependencies() { return []; }
		@property override string[] dependencies() { return []; }
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
		@property override string submoduleName    () { return "druntime"; }
		@property override string[] sourceDependencies() { return ["phobos", "phobos-includes"]; }
		@property override string[] dependencies() { return ["dmd"]; }
		@property override string configString() { return null; }

		override void performBuild()
		{
			getComponent("phobos").needSource();
			getComponent("dmd").needInstalled();
			getComponent("phobos-includes").needInstalled();

			auto env = baseEnvironment;
			needCC(env);

			mkdirRecurse(sourceDir.buildPath("import"));
			mkdirRecurse(sourceDir.buildPath("lib"));

			setTimes(sourceDir.buildPath("src", "rt", "minit.obj"), Clock.currTime(), Clock.currTime()); // Don't rebuild
			submodule.saveFileState("src/rt/minit.obj");

			run(getMake(env) ~ ["-f", makeFileNameModel, "import", "DMD=" ~ dmd] ~ commonConfig.makeArgs ~ getPlatformMakeVars(env) ~ dMakeArgs, env.vars, sourceDir);
			run(getMake(env) ~ ["-f", makeFileNameModel          , "DMD=" ~ dmd] ~ commonConfig.makeArgs ~ getPlatformMakeVars(env) ~ dMakeArgs, env.vars, sourceDir);
		}

		override void performStage()
		{
			cp(
				buildPath(sourceDir, "import"),
				buildPath(stageDir , "import"),
			);
		}

		override void performTest()
		{
			getComponent("druntime").needBuild();
			getComponent("dmd").needInstalled();

			auto env = baseEnvironment;
			needCC(env);
			run(getMake(env) ~ ["-f", makeFileNameModel, "unittest", "DMD=" ~ dmd] ~ commonConfig.makeArgs ~ getPlatformMakeVars(env) ~ dMakeArgs, env.vars, sourceDir);
		}
	}

	final class Phobos : Component
	{
		@property override string submoduleName    () { return "phobos"; }
		@property override string[] sourceDependencies() { return []; }
		@property override string[] dependencies() { return ["druntime", "dmd"]; }
		@property override string configString() { return null; }

		string[] targets;

		override void performBuild()
		{
			getComponent("dmd").needInstalled();
			getComponent("druntime").needBuild();

			auto env = baseEnvironment;
			needCC(env);

			string phobosMakeFileName = findMakeFile(sourceDir, makeFileNameModel);

			version (Windows)
			{
				auto lib = "phobos%s.lib".format(modelSuffix);
				run(getMake(env) ~ ["-f", phobosMakeFileName, lib, "DMD=" ~ dmd] ~ commonConfig.makeArgs ~ getPlatformMakeVars(env) ~ dMakeArgs, env.vars, sourceDir);
				enforce(sourceDir.buildPath(lib).exists);
				targets = ["phobos%s.lib".format(modelSuffix)];
			}
			else
			{
				run(getMake(env) ~ ["-f", phobosMakeFileName,      "DMD=" ~ dmd] ~ commonConfig.makeArgs ~ getPlatformMakeVars(env) ~ dMakeArgs, env.vars, sourceDir);
				targets = sourceDir
					.buildPath("generated")
					.dirEntries(SpanMode.depth)
					.filter!(de => de.name.endsWith(".a"))
					.map!(de => de.name.relativePath(sourceDir))
					.array()
				;
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

		override void performTest()
		{
			getComponent("druntime").needBuild();
			getComponent("phobos").needBuild();
			getComponent("dmd").needInstalled();

			auto env = baseEnvironment;
			needCC(env);
			version (Windows)
			{
				getComponent("curl").needInstalled();
				getComponent("curl").updateEnv(env);

				// Patch out std.datetime unittest to work around Digger test
				// suite failure on AppVeyor due to Windows time zone changes
				auto stdDateTime = buildPath(sourceDir, "std", "datetime.d");
				if (stdDateTime.exists && !stdDateTime.readText().canFind("Altai Standard Time"))
				{
					string phobosMakeFileName = findMakeFile(sourceDir, makeFileNameModel);
					auto makeFullName = buildPath(sourceDir, phobosMakeFileName);
					auto m = makeFullName.readText();
					m = m
						.replace(`		unittest3b.obj \`, `	\`)
					;
					makeFullName.write(m);
					submodule.saveFileState(phobosMakeFileName);
				}

				if (commonConfig.model == "32")
					getComponent("extras").needInstalled();
			}
			run(getMake(env) ~ ["-f", makeFileNameModel, "unittest", "DMD=" ~ dmd] ~ commonConfig.makeArgs ~ getPlatformMakeVars(env) ~ dMakeArgs, env.vars, sourceDir);
		}
	}

	final class RDMD : Component
	{
		@property override string submoduleName() { return "tools"; }
		@property override string[] sourceDependencies() { return []; }
		@property override string[] dependencies() { return ["dmd", "druntime", "phobos"]; }
		@property override string configString() { return null; }

		override void performBuild()
		{
			foreach (dep; ["dmd", "druntime", "phobos"])
				getComponent(dep).needInstalled();

			auto env = baseEnvironment;
			needCC(env);

			// Just build rdmd
			bool needModel; // Need -mXX switch?

			if (sourceDir.buildPath("posix.mak").exists)
				needModel = true; // Known to be needed for recent versions

			string[] args = ["-conf=" ~ buildPath(buildDir , "bin", configFileName), "rdmd"];

			if (!needModel)
				try
					run([dmd] ~ args, env.vars, sourceDir);
				catch (Exception e)
					needModel = true;

			if (needModel)
				run([dmd, "-m" ~ commonConfig.model] ~ args, env.vars, sourceDir);
		}

		override void performStage()
		{
			cp(
				buildPath(sourceDir, "rdmd" ~ binExt),
				buildPath(stageDir , "bin", "rdmd" ~ binExt),
			);
		}

		override void performTest()
		{
			foreach (dep; ["dmd", "druntime", "phobos"])
				getComponent(dep).needInstalled();

			auto env = baseEnvironment;
			getComponent("dmd").updateEnv(env);
			run(["dmd", "-run", "rdmd_test.d"], env.vars, sourceDir);
		}
	}

	final class Website : Component
	{
		@property override string submoduleName() { return "dlang.org"; }
		@property override string[] sourceDependencies() { return []; }
		@property override string[] dependencies() { return ["dmd", "druntime", "phobos", "rdmd"]; }
		@property override string configString() { return null; }

		struct Config
		{
			/// Do not include a timestamp in generated .ddoc files.
			/// Improves cache efficiency and allows meaningful diffs.
			bool noDateTime = false;
		}

		/// Get the latest version of DMD at the time.
		/// Needed for the makefile's "LATEST" parameter.
		string getLatest()
		{
			auto dmd = getComponent("dmd").submodule;

			auto t = dmd.git.query(["log", "--pretty=format:%ct"]).splitLines.map!(to!int).filter!(n => n > 0).front;

			foreach (line; dmd.git.query(["log", "--decorate=full", "--tags", "--pretty=format:%ct%d"]).splitLines())
				if (line.length > 10 && line[0..10].to!int < t)
					if (line[10..$].startsWith(" (") && line.endsWith(")"))
					{
						foreach (r; line[12..$-1].split(", "))
							if (r.skipOver("tag: refs/tags/"))
								if (r.match(re!`^v\d\.\d\d\d(\.\d)?$`))
									return r[1..$];
					}
			throw new Exception("Can't find any DMD version tags at this point!");
		}

		override void performBuild()
		{
			auto env = baseEnvironment;

			version (Windows)
				throw new Exception("The dlang.org website is only buildable on POSIX platforms.");
			else
			{
				needKindleGen(env);

				foreach (dep; dependencies)
					getComponent(dep).submodule.clean = false;

				auto makeFullName = sourceDir.buildPath(makeFileName);
				makeFullName
					.readText()
					// https://github.com/D-Programming-Language/dlang.org/pull/1011
					.replace(": modlist.d", ": modlist.d $(DMD)")
					// https://github.com/D-Programming-Language/dlang.org/pull/1017
					.replace("dpl-docs: ${DUB} ${STABLE_DMD}\n\tDFLAGS=", "dpl-docs: ${DUB} ${STABLE_DMD}\n\t${DUB} upgrade --missing-only --root=${DPL_DOCS_PATH}\n\tDFLAGS=")
					.toFile(makeFullName)
				;

				auto latest = getLatest;
				log("LATEST=" ~ latest);

				run(getMake(env) ~ [
					"-f", makeFileName,
					"all", "kindle", "pdf", "verbatim",
					] ~ (config.build.components.website.noDateTime ? ["NODATETIME=nodatetime.ddoc"] : []) ~ [ // Can't be last due to https://issues.dlang.org/show_bug.cgi?id=14682
					"LATEST=" ~ latest,
				] ~ gnuMakeArgs, env.vars, sourceDir);
			}
		}

		override void performStage()
		{
			foreach (item; ["web", "dlangspec.tex", "dlangspec.html"])
				cp(
					buildPath(sourceDir, item),
					buildPath(stageDir , item),
				);
		}
	}

	final class Extras : Component
	{
		@property override string submoduleName() { return null; }
		@property override string[] sourceDependencies() { return []; }
		@property override string[] dependencies() { return []; }
		@property override string configString() { return null; }

		override void performBuild()
		{
			needExtras();
		}

		override void performStage()
		{
			version (Windows)
				enum platform = "windows";
			else
			version (linux)
				enum platform = "linux";
			else
			version (OSX)
				enum platform = "osx";
			else
			version (FreeBSD)
				enum platform = "freebsd";
			else
				static assert(false);

			auto extrasDir = needExtras();

			void copyDir(string source, string target)
			{
				source = buildPath(extrasDir, "localextras-" ~ platform, "dmd2", platform, source);
				target = buildPath(stageDir, target);
				if (source.exists)
					cp(source, target);
			}

			copyDir("bin", "bin");
			copyDir("bin" ~ commonConfig.model, "bin");
			copyDir("lib", "lib");

			version (Windows)
				if (commonConfig.model == "32")
				{
					// The version of snn.lib bundled with DMC will be newer.
					Environment env;
					needDMC(env);
					cp(buildPath(env.deps.dmcDir, "lib", "snn.lib"), buildPath(stageDir, "lib", "snn.lib"));
				}
		}
	}

	final class Curl : Component
	{
		@property override string submoduleName() { return null; }
		@property override string[] sourceDependencies() { return []; }
		@property override string[] dependencies() { return []; }
		@property override string configString() { return null; }

		override void performBuild()
		{
			version (Windows)
				needCurl();
			else
				log("Not on Windows, skipping libcurl download");
		}

		override void performStage()
		{
			version (Windows)
			{
				auto curlDir = needCurl();

				void copyDir(string source, string target)
				{
					source = buildPath(curlDir, "dmd2", "windows", source);
					target = buildPath(stageDir, target);
					if (source.exists)
						cp(source, target);
				}

				copyDir("bin" ~ modelSuffix, "bin");
				copyDir("lib" ~ modelSuffix, "lib");
			}
			else
				log("Not on Windows, skipping libcurl install");
		}

		override void updateEnv(ref Environment env)
		{
			env.vars["PATH"] = buildPath(buildDir, "bin").absolutePath() ~ pathSeparator ~ env.vars["PATH"];
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
					c = new DMD();
					break;
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
				case "website":
					c = new Website();
					break;
				case "extras":
					c = new Extras();
					break;
				case "curl":
					c = new Curl();
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

	/// Reverts a commit from the given SubmoduleState.
	/// parent is the 1-based mainline index (as per `man git-revert`),
	/// or 0 if commit is not a merge commit.
	void revert(ref SubmoduleState submoduleState, string submoduleName, string commit, int parent)
	{
		log("Reverting %s commit %s".format(submoduleName, commit));
		enforce(submoduleName in submoduleState.submoduleCommits, "Unknown submodule: " ~ submoduleName);
		auto submodule = getSubmodule(submoduleName);
		auto head = submoduleState.submoduleCommits[submoduleName];
		auto result = submodule.getRevert(head, commit, parent);
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

	/// Find the child of a commit (starting with the current submodule state),
	/// and, if the commit was a merge, the mainline index of said commit for the child.
	void getChild(ref SubmoduleState submoduleState, string submoduleName, string commit, out string child, out int mainline)
	{
		enforce(submoduleName in submoduleState.submoduleCommits, "Unknown submodule: " ~ submoduleName);
		auto head = submoduleState.submoduleCommits[submoduleName];
		return getSubmodule(submoduleName).getChild(head, commit, child, mainline);
	}

	// ****************************** Building *******************************

	private SubmoduleState submoduleState;
	private bool incrementalBuild;

	@property string cacheEngineName()
	{
		if (incrementalBuild)
			return "none";
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
	static const string[] additionalComponents = ["website", "extras", "curl"];
	static const string[] allComponents = defaultComponents ~ additionalComponents;

	/// Build the specified components according to the specified configuration.
	void build(SubmoduleState submoduleState, bool incremental = false)
	{
		auto componentNames = config.build.components.getEnabledComponentNames();
		log("Building components %-(%s, %)".format(componentNames));

		this.components = null;
		this.submoduleState = submoduleState;
		this.incrementalBuild = incremental;

		if (buildDir.exists)
			buildDir.removeRecurse();
		enforce(!buildDir.exists);

		scope(exit) if (cacheEngine) cacheEngine.finalize();

		foreach (componentName; componentNames)
			getComponent(componentName).needInstalled();
	}

	/// Shortcut for begin + build
	void buildRev(string rev)
	{
		auto submoduleState = begin(rev);
		build(submoduleState);
	}

	/// Simply check out the source code for the given submodules.
	void checkout(SubmoduleState submoduleState)
	{
		auto componentNames = config.build.components.getEnabledComponentNames();
		log("Checking out components %-(%s, %)".format(componentNames));

		this.components = null;
		this.submoduleState = submoduleState;
		this.incrementalBuild = false;

		foreach (componentName; componentNames)
			getComponent(componentName).needSource();
	}

	/// Rerun build without cleaning up any files.
	void rebuild()
	{
		build(SubmoduleState(null), true);
	}

	/// Run all tests for the current checkout (like rebuild).
	void test()
	{
		auto componentNames = config.build.components.getEnabledComponentNames();
		log("Testing components %-(%s, %)".format(componentNames));

		this.components = null;
		this.submoduleState = SubmoduleState(null);
		this.incrementalBuild = true;

		foreach (componentName; componentNames)
			getComponent(componentName).test();
	}

	bool isCached(SubmoduleState submoduleState)
	{
		this.components = null;
		this.submoduleState = submoduleState;

		needCacheEngine();
		foreach (componentName; config.build.components.getEnabledComponentNames())
			if (!cacheEngine.haveEntry(getComponent(componentName).getBuildID()))
				return false;
		return true;
	}

	/// Returns the isCached state for all commits in the history of the given ref.
	bool[string] getCacheState(string[string][string] history)
	{
		log("Enumerating cache entries...");
		auto cacheEntries = needCacheEngine().getEntries().toSet();

		this.components = null;
		auto componentNames = config.build.components.getEnabledComponentNames();
		auto components = componentNames.map!(componentName => getComponent(componentName)).array;
		auto requiredSubmodules = components
			.map!(component => chain(component.name.only, component.sourceDependencies, component.dependencies))
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
	bool[string] getCacheState(string[] refs)
	{
		auto history = getMetaRepo().getSubmoduleHistory(refs);
		return getCacheState(history);
	}

	// **************************** Dependencies *****************************

	private void needInstaller()
	{
		Installer.logger = &log;
		Installer.installationDirectory = dlDir;
	}

	void needDMD(ref Environment env)
	{
		needDMD(env, "2.067.1", config.build.components.dmd.bootstrap);
	}

	void needDMD(ref Environment env, string dmdVer, bool bootstrap)
	{
		tempError++; scope(success) tempError--;

		if (!env.deps.hostDC)
		{
			if (bootstrap)
			{
				log("Bootstrapping DMD " ~ dmdVer);
				auto dir = buildPath(config.local.workDir, "bootstrap", "dmd-" ~ dmdVer);
				void bootstrapDMDProxy(string target) { return bootstrapDMD(dmdVer, target); } // https://issues.dlang.org/show_bug.cgi?id=14580
				cached!bootstrapDMDProxy(dir);
				env.deps.hostDC = buildPath(dir, "bin", "dmd" ~ binExt);
			}
			else
			{
				log("Preparing DMD " ~ dmdVer);
				needInstaller();
				auto dmdInstaller = new DMDInstaller(dmdVer);
				dmdInstaller.requireLocal(false);
				env.deps.hostDC = dmdInstaller.exePath("dmd").absolutePath();
			}
			log("hostDC=" ~ env.deps.hostDC);
		}
	}

	void needKindleGen(ref Environment env)
	{
		needInstaller();
		kindleGenInstaller.requireLocal(false);
		env.vars["PATH"] = kindleGenInstaller.directory ~ pathSeparator ~ env.vars["PATH"];
	}

	version (Windows)
	void needMSYS(ref Environment env)
	{
		needInstaller();
		MSYS.msysCORE.requireLocal(false);
		MSYS.libintl.requireLocal(false);
		MSYS.libiconv.requireLocal(false);
		MSYS.libtermcap.requireLocal(false);
		MSYS.libregex.requireLocal(false);
		MSYS.coreutils.requireLocal(false);
		MSYS.bash.requireLocal(false);
		MSYS.make.requireLocal(false);
		MSYS.grep.requireLocal(false);
		MSYS.sed.requireLocal(false);
		MSYS.diffutils.requireLocal(false);
		env.vars["PATH"] = MSYS.bash.directory.buildPath("bin") ~ pathSeparator ~ env.vars["PATH"];
	}

	/// Get DMD unbuildable extras
	/// (proprietary DigitalMars utilities, 32-bit import libraries)
	string needExtras()
	{
		import ae.utils.meta : I, singleton;

		static class DExtrasInstaller : Installer
		{
			@property override string name() { return "dmd-localextras"; }
			string url = "http://semitwist.com/download/app/dmd-localextras.7z";

			override void installImpl(string target)
			{
				url
					.I!save()
					.I!unpackTo(target);
			}
		}

		alias extrasInstaller = singleton!DExtrasInstaller;

		needInstaller();
		extrasInstaller.requireLocal(false);
		return extrasInstaller.directory;
	}

	/// Get libcurl for Windows (DLL and import libraries)
	version (Windows)
	string needCurl()
	{
		import ae.utils.meta : I, singleton;

		static class DCurlInstaller : Installer
		{
			@property override string name() { return "libcurl-" ~ curlVersion; }
			string curlVersion = "7.47.1";
			@property string url() { return "http://downloads.dlang.org/other/libcurl-" ~ curlVersion ~ "-WinSSL-zlib-x86-x64.zip"; }

			override void installImpl(string target)
			{
				url
					.I!save()
					.I!unpackTo(target);
			}
		}

		alias curlInstaller = singleton!DCurlInstaller;

		needInstaller();
		curlInstaller.requireLocal(false);
		return curlInstaller.directory;
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
		buildRev(rev);
		ensurePathExists(target);
		rename(buildDir, target);
	}

	version (Windows)
	void needDMC(ref Environment env, string ver = null)
	{
		tempError++; scope(success) tempError--;

		needInstaller();

		auto dmc = ver ? new LegacyDMCInstaller(ver) : dmcInstaller;
		if (!dmc.installedLocally)
			log("Preparing DigitalMars C++ " ~ ver);
		dmc.requireLocal(false);
		env.deps.dmcDir = dmc.directory;

		auto binPath = buildPath(env.deps.dmcDir, `bin`).absolutePath();
		log("DMC=" ~ binPath);
		env.vars["DMC"] = binPath;
		env.vars["PATH"] = binPath ~ pathSeparator ~ env.vars.get("PATH", null);
	}

	version (Windows)
	auto getVSInstaller()
	{
		needInstaller();
		return vs2013community;
	}

	version (Windows)
	void needVC(ref Environment env)
	{
		tempError++; scope(success) tempError--;

		auto packages =
		[
			"vcRuntimeMinimum_x86",
			"vcRuntimeMinimum_x64",
			"vc_compilercore86",
			"vc_compilercore86res",
			"vc_compilerx64nat",
			"vc_compilerx64natres",
			"vc_librarycore86",
			"vc_libraryDesktop_x64",
			"win_xpsupport",
		];
		if (config.build.components.dmd.useVC)
			packages ~= "Msi_BuildTools_MSBuild_x86";

		auto vs = getVSInstaller();
		vs.requirePackages(packages);
		if (!vs.installedLocally)
			log("Preparing Visual C++");
		vs.requireLocal(false);

		env.deps.vsDir  = vs.directory.buildPath("Program Files (x86)", "Microsoft Visual Studio 12.0").absolutePath();
		env.deps.sdkDir = vs.directory.buildPath("Program Files", "Microsoft SDKs", "Windows", "v7.1A").absolutePath();

		env.vars["PATH"] ~= pathSeparator ~ vs.binPaths.map!(path => vs.directory.buildPath(path).absolutePath()).join(pathSeparator);
		env.vars["VCINSTALLDIR"] = env.deps.vsDir.buildPath("VC") ~ dirSeparator;
		env.vars["INCLUDE"] = env.deps.vsDir.buildPath("VC", "include");
		env.vars["WindowsSdkDir"] = env.deps.sdkDir ~ dirSeparator;
		env.vars["LINKCMD64"] = env.deps.vsDir.buildPath("VC", "bin", "x86_amd64", "link.exe"); // Used by dmd
	}

	private void needGit()
	{
		tempError++; scope(success) tempError--;

		needInstaller();
		gitInstaller.require();
	}

	/// Disable the "<program> has stopped working"
	/// standard Windows dialog.
	version (Windows)
	static void disableCrashDialog()
	{
		enum : uint { SEM_FAILCRITICALERRORS = 1, SEM_NOGPFAULTERRORBOX = 2 }
		SetErrorMode(SEM_FAILCRITICALERRORS | SEM_NOGPFAULTERRORBOX);
	}

	/// Create a build environment base.
	protected @property Environment baseEnvironment()
	{
		Environment env;

		// Build a new environment from scratch, to avoid tainting the build with the current environment.
		string[] newPaths;

		version (Windows)
		{
			import std.utf;
			import ae.sys.windows.imports;
			mixin(importWin32!q{winbase});
			mixin(importWin32!q{winnt});

			TCHAR[1024] buf;
			// Needed for DLLs
			auto winDir = buf[0..GetWindowsDirectory(buf.ptr, buf.length)].toUTF8();
			auto sysDir = buf[0..GetSystemDirectory (buf.ptr, buf.length)].toUTF8();
			//auto tmpDir = buf[0..GetTempPath(buf.length, buf.ptr)].toUTF8()[0..$-1];
			newPaths ~= [sysDir, winDir];
		}
		else
		{
			// Needed for coreutils, make, gcc, git etc.
			newPaths = ["/bin", "/usr/bin"];
		}

		env.vars["PATH"] = newPaths.join(pathSeparator);

		version (Windows)
		{
			auto tmpDir = buildPath(config.local.workDir, "tmp");
			tmpDir.recreateEmptyDirectory();
			env.vars["TEMP"] = env.vars["TMP"] = tmpDir;
			env.vars["SystemDrive"] = winDir.driveName;
			env.vars["SystemRoot"] = winDir;
		}
		else
		{
			auto home = buildPath(config.local.workDir, "home");
			ensureDirExists(home);
			env.vars["HOME"] = home;
		}

		return env;
	}

	/// Apply user modifications onto an environment.
	/// Supports Windows-style %VAR% expansions.
	static string[string] applyEnv(in string[string] target, in string[string] source)
	{
		// The source of variable expansions is variables in the target environment,
		// if they exist, and the host environment otherwise, so e.g.
		// `PATH=C:\...;%PATH%` and `MAKE=%MAKE%` work as expected.
		auto oldEnv = std.process.environment.toAA();
		foreach (name, value; target)
			oldEnv[name] = value;

		string[string] result;
		foreach (name, value; target)
			result[name] = value;
		foreach (name, value; source)
		{
			string newValue = value;
			foreach (oldName, oldValue; oldEnv)
				newValue = newValue.replace("%" ~ oldName ~ "%", oldValue);
			result[name] = oldEnv[name] = newValue;
		}
		return result;
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
