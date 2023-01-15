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
 *   Vladimir Panteleev <ae@cy.md>
 */

module ae.sys.d.manager;

import std.algorithm;
import std.array;
import std.conv;
import std.datetime;
import std.exception;
import std.file;
import std.json : parseJSON;
import std.path;
import std.process : spawnProcess, wait, escapeShellCommand;
import std.range;
import std.regex;
import std.string;
import std.typecons;

import ae.net.github.rest;
import ae.sys.d.cache;
import ae.sys.d.repo;
import ae.sys.file;
import ae.sys.git;
import ae.utils.aa;
import ae.utils.array;
import ae.utils.digest;
import ae.utils.json;
import ae.utils.meta;
import ae.utils.regex;

private alias ensureDirExists = ae.sys.file.ensureDirExists;

version (Windows) private
{
	import ae.sys.install.dmc;
	import ae.sys.install.msys;
	import ae.sys.install.vs;

	import ae.sys.windows.misc;

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

	/// DManager configuration.
	struct Config
	{
		/// Build configuration
		struct Build
		{
			/// Per-component build configuration.
			struct Components
			{
				/// Explicitly enable or disable a component.
				bool[string] enable;

				/// Returns a list of all enabled components, whether
				/// they're enabled explicitly or by default.
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

				Component.CommonConfig common; /// Configuration which applies to all components.
				DMD.Config dmd; /// Configuration for building the compiler.
				Website.Config website; /// Configuration for building the website.
			}
			Components components; /// ditto

			/// Additional environment variables.
			/// Supports %VAR% expansion - see applyEnv.
			string[string] environment;

			/// Optional cache key.
			/// Can be used to force a rebuild and bypass the cache for one build.
			string cacheKey;
		}
		Build build; /// ditto

		/// Machine-local configuration
		/// These settings should not affect the build output.
		struct Local
		{
			/// URL of D git repository hosting D components.
			/// Defaults to (and must have the layout of) D.git:
			/// https://github.com/CyberShadow/D-dot-git
			string repoUrl = "https://bitbucket.org/cybershadow/d.git";

			/// Location for the checkout, temporary files, etc.
			string workDir;

			/// If present, passed to GNU make via -j parameter.
			/// Can also be "auto" or "unlimited".
			string makeJobs;

			/// Don't get latest updates from GitHub.
			bool offline;

			/// How to cache built files.
			string cache;

			/// Maximum execution time, in seconds, of any single
			/// command.
			int timeout;

			/// API token to access the GitHub REST API (optional).
			string githubToken;
		}
		Local local; /// ditto
	}
	Config config; /// ditto

	// Behavior options that generally depend on the host program.

	/// Automatically re-clone the repository in case
	/// "git reset --hard" fails.
	bool autoClean;

	/// Whether to verify working tree state
	/// to make sure we don't clobber user changes
	bool verifyWorkTree;

	/// Whether we should cache failed builds.
	bool cacheFailures = true;

	/// Current build environment.
	struct Environment
	{
		/// Configuration for software dependencies
		struct Deps
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
	alias tmpDir     = subDir!"tmp";         /// Directory for $TMPDIR etc.
	alias homeDir    = subDir!"home";        /// Directory for $HOME.
	alias binDir     = subDir!"bin" ;        /// For wrapper scripts.
	alias githubDir  = subDir!"github-cache";/// For the GitHub API cache.

	/// This number increases with each incompatible change to cached data.
	enum cacheVersion = 3;

	/// Returns the path to cached data for the given cache engine
	/// (as in `config.local.cache`).
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

	/// Executable file name suffix for the current platform.
	version (Windows)
		enum string binExt = ".exe";
	else
		enum string binExt = "";

	/// DMD configuration file name for the current platform.
	version (Windows)
		enum configFileName = "sc.ini";
	else
		enum configFileName = "dmd.conf";

	/// Do we need to explicitly specify a `-conf=` switch to DMD
	/// This is true when there exists a configuration file in the home directory.
	static bool needConfSwitch() { return exists(std.process.environment.get("HOME", null).buildPath(configFileName)); }

	// **************************** Repositories *****************************

	/// Base class for a `DManager` Git repository.
	class DManagerRepository : ManagedRepository
	{
		this()
		{
			this.offline = config.local.offline;
			this.verify = this.outer.verifyWorkTree;
		} ///

		protected override void log(string s) { return this.outer.log(s); }
	}

	/// The meta-repository, which contains the sub-project submodules.
	class MetaRepository : DManagerRepository
	{
		protected override Git getRepo()
		{
			needGit();

			if (!repoDir.exists)
			{
				log("Cloning initial repository...");
				atomic!_performClone(config.local.repoUrl, repoDir);
			}

			return Git(repoDir);
		}

		static void _performClone(string url, string target)
		{
			import ae.sys.cmd;
			run(["git", "clone", url, target]);
		}

		protected override void performCheckout(string hash)
		{
			super.performCheckout(hash);
			submodules = null;
		}

		protected string[string][string] submoduleCache;

		/// Get submodule commit hashes at the given commit-ish.
		string[string] getSubmoduleCommits(string head)
		{
			auto pcacheEntry = head in submoduleCache;
			if (pcacheEntry)
				return (*pcacheEntry).dup;

			string[string] result;
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

	private MetaRepository metaRepo; /// ditto

	MetaRepository getMetaRepo()
	{
		if (!metaRepo)
			metaRepo = new MetaRepository;
		return metaRepo;
	} /// ditto

	/// Sub-project repositories.
	class SubmoduleRepository : DManagerRepository
	{
		string dir; /// Full path to the repository.

		protected override Git getRepo()
		{
			getMetaRepo().git; // ensure meta-repository is cloned
			auto git = Git(dir);
			git.commandPrefix ~= ["-c", `url.https://.insteadOf=git://`];
			return git;
		}

		protected override void needHead(string hash)
		{
			if (!autoClean)
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

	private SubmoduleRepository[string] submodules; /// ditto

	ManagedRepository getSubmodule(string name)
	{
		assert(name, "This component is not associated with a submodule");
		if (name !in submodules)
		{
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
	} /// ditto

	// ***************************** Components ******************************

	/// Base class for a D component.
	class Component
	{
		/// Name of this component, as registered in DManager.components AA.
		string name;

		/// Corresponding subproject repository name.
		@property abstract string submoduleName();
		/// Corresponding subproject repository.
		@property ManagedRepository submodule() { return getSubmodule(submoduleName); }

		/// Configuration applicable to multiple (not all) components.
		// Note: don't serialize this structure whole!
		// Only serialize used fields.
		struct CommonConfig
		{
			/// The default target model on this platform.
			version (Windows)
				enum defaultModel = "32";
			else
			version (D_LP64)
				enum defaultModel = "64";
			else
				enum defaultModel = "32";

			/// Target comma-separated models ("32", "64", and on Windows, "32mscoff").
			/// Controls the models of the built Phobos and Druntime libraries.
			string model = defaultModel;

			@property string[] models() { return model.split(","); } /// Get/set `model` as list.
			@property void models(string[] value) { this.model = value.join(","); } /// ditto

			/// Additional make parameters, e.g. "HOST_CC=g++48"
			string[] makeArgs;

			/// Build debug versions of Druntime / Phobos.
			bool debugLib;
		}

		/// A string description of this component's configuration.
		abstract @property string configString();

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
			int cacheVersion; ///
			string name; ///
			string commit; ///
			string configString; ///
			string[] sourceDepCommits; ///
			Metadata[] dependencyMetadata; ///
			@JSONOptional string cacheKey; ///
		}

		Metadata getMetadata()
		{
			return Metadata(
				cacheVersion,
				name,
				commit,
				configString,
				sourceDependencies.map!(
					dependency => getComponent(dependency).commit
				).array(),
				dependencies.map!(
					dependency => getComponent(dependency).getMetadata()
				).array(),
				config.build.cacheKey,
			);
		} /// ditto

		void saveMetaData(string target)
		{
			std.file.write(buildPath(target, "digger-metadata.json"), getMetadata().toJson());
			// Use a separate file to avoid double-encoding JSON
			std.file.write(buildPath(target, "digger-config.json"), configString);
		} /// ditto

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

		@property string sourceDir() { return submodule.git.path; } ///

		/// Directory to which built files are copied to.
		/// This will then be atomically added to the cache.
		protected string stageDir;

		/// Prepare the source checkout for this component.
		/// Usually needed by other components.
		void needSource(bool needClean = false)
		{
			tempError++; scope(success) tempError--;

			if (incrementalBuild)
				return;
			if (!submoduleName)
				return;

			bool needHead;
			if (needClean)
				needHead = true;
			else
			{
				// It's OK to run tests with a dirty worktree (i.e. after a build).
				needHead = commit != submodule.getHead();
			}

			if (needHead)
			{
				foreach (component; getSubmoduleComponents(submoduleName))
					component.haveBuild = false;
				submodule.needHead(commit);
			}
			submodule.clean = false;
		}

		private bool haveBuild;

		/// Build the component in-place, as needed,
		/// without moving the built files anywhere.
		void needBuild(bool clean = true)
		{
			if (haveBuild) return;
			scope(success) haveBuild = true;

			log("needBuild: " ~ getBuildID());

			needSource(clean);

			prepareEnv();

			log("Building " ~ getBuildID());
			performBuild();
			log(getBuildID() ~ " built OK!");
		}

		/// Set up / clean the build environment.
		private void prepareEnv()
		{
			// Nuke any additional directories cloned by makefiles
			if (!incrementalBuild)
			{
				getMetaRepo().git.run(["clean", "-ffdx"]);

				foreach (dir; [tmpDir, homeDir])
				{
					if (dir.exists && !dir.dirEntries(SpanMode.shallow).empty)
						log("Clearing %s ...".format(dir));
					dir.recreateEmptyDirectory();
				}
			}

			// Set up compiler wrappers.
			recreateEmptyDirectory(binDir);
			version (linux)
			{
				foreach (cc; ["cc", "gcc", "c++", "g++"])
				{
					auto fileName = binDir.buildPath(cc);
					write(fileName, q"EOF
#!/bin/sh
set -eu

tool=$(basename "$0")
next=/usr/bin/$tool
tmpdir=${TMP:-/tmp}
flagfile=$tmpdir/nopie-flag-$tool

if [ ! -e "$flagfile" ]
then
	echo 'Testing for -no-pie...' 1>&2
	testfile=$tmpdir/test-$$.c
	echo 'int main(){return 0;}' > $testfile
	if $next -no-pie -c -o$testfile.o $testfile
	then
		printf "%s" "-no-pie" > "$flagfile".$$.tmp
		mv "$flagfile".$$.tmp "$flagfile"
	else
		touch "$flagfile"
	fi
	rm -f "$testfile" "$testfile.o"
fi

exec "$next" $(cat "$flagfile") "$@"
EOF");
					setAttributes(fileName, octal!755);
				}
			}
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

					int currentTempError = tempError;

					// Treat cache errors an environmental errors
					// (for when needInstalled is invoked to build a dependency)
					tempError++; scope(success) tempError--;

					// tempDir might be removed by a dependency's build failure.
					if (!tempDir.exists)
						log("Not caching %s dependency build failure.".format(name));
					else
					// Don't cache failed build results due to temporary/environment problems
					if (failed && currentTempError > 0)
					{
						log("Not caching %s build failure due to temporary/environment error.".format(name));
						rmdirRecurse(tempDir);
					}
					else
					// Don't cache failed build results during delve
					if (failed && !cacheFailures)
					{
						log("Not caching failed %s build.".format(name));
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

		string modelSuffix(string model) { return model == "32" ? "" : model; }
		version (Windows)
		{
			enum string makeFileName = "win32.mak";
			string makeFileNameModel(string model)
			{
				if (model == "32mscoff")
					model = "64";
				return "win"~model~".mak";
			}
			enum string binExt = ".exe";
		}
		else
		{
			enum string makeFileName = "posix.mak";
			string makeFileNameModel(string model) { return "posix.mak"; }
			enum string binExt = "";
		}

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

		/// Returns the command for the make utility.
		string[] getMake(ref const Environment env)
		{
			version (FreeBSD)
				enum makeProgram = "gmake"; // GNU make
			else
			version (Posix)
				enum makeProgram = "make"; // GNU make
			else
				enum makeProgram = "make"; // DigitalMars make
			return [env.vars.get("MAKE", makeProgram)];
		}

		/// Returns the path to the built dmd executable.
		@property string dmd() { return buildPath(buildDir, "bin", "dmd" ~ binExt).absolutePath(); }

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

		string[] getPlatformMakeVars(ref const Environment env, string model, bool quote = true)
		{
			string[] args;

			args ~= "MODEL=" ~ model;

			version (Windows)
				if (model != "32")
				{
					args ~= "VCDIR="  ~ env.deps.vsDir.buildPath("VC").absolutePath();
					args ~= "SDKDIR=" ~ env.deps.sdkDir.absolutePath();

					// Work around https://github.com/dlang/druntime/pull/2438
					auto quoteStr = quote ? `"` : ``;
					args ~= "CC=" ~ quoteStr ~ env.deps.vsDir.buildPath("VC", "bin", msvcModelDir(model), "cl.exe").absolutePath() ~ quoteStr;
					args ~= "LD=" ~ quoteStr ~ env.deps.vsDir.buildPath("VC", "bin", msvcModelDir(model), "link.exe").absolutePath() ~ quoteStr;
					args ~= "AR=" ~ quoteStr ~ env.deps.vsDir.buildPath("VC", "bin", msvcModelDir(model), "lib.exe").absolutePath() ~ quoteStr;
				}

			return args;
		}

		@property string[] gnuMakeArgs()
		{
			string[] args;
			if (config.local.makeJobs)
			{
				if (config.local.makeJobs == "auto")
				{
					import std.parallelism, std.conv;
					args ~= "-j" ~ text(totalCPUs);
				}
				else
				if (config.local.makeJobs == "unlimited")
					args ~= "-j";
				else
					args ~= "-j" ~ config.local.makeJobs;
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

		void needCC(ref Environment env, string model, string dmcVer = null)
		{
			version (Windows)
			{
				needDMC(env, dmcVer); // We need DMC even for 64-bit builds (for DM make)
				if (model != "32")
					needVC(env, model);
			}
		}

		void run(const(string)[] args, in string[string] newEnv, string dir)
		{
			// Apply user environment
			auto env = applyEnv(newEnv, config.build.environment);

			// Temporarily apply PATH from newEnv to our process,
			// so process creation lookup can use it.
			string oldPath = std.process.environment["PATH"];
			scope (exit) std.process.environment["PATH"] = oldPath;
			std.process.environment["PATH"] = env["PATH"];

			// Apply timeout setting
			if (config.local.timeout)
				args = ["timeout", config.local.timeout.text] ~ args;

			foreach (name, value; env)
				log("Environment: " ~ name ~ "=" ~ value);
			log("Working directory: " ~ dir);
			log("Running: " ~ escapeShellCommand(args));

			auto status = spawnProcess(args, env, std.process.Config.newEnv, dir).wait();
			enforce(status == 0, "Command %s failed with status %d".format(args, status));
		}
	}

	/// The dmd executable
	final class DMD : Component
	{
		protected @property override string submoduleName  () { return "dmd"; }
		protected @property override string[] sourceDependencies() { return []; }
		protected @property override string[] dependencies() { return []; }

		/// DMD build configuration.
		struct Config
		{
			/// Whether to build a debug DMD.
			/// Debug builds are faster to build,
			/// but run slower.
			@JSONOptional bool debugDMD = false;

			/// Whether to build a release DMD.
			/// Mutually exclusive with debugDMD.
			@JSONOptional bool releaseDMD = false;

			/// Model for building DMD itself (on Windows).
			/// Can be used to build a 64-bit DMD, to avoid 4GB limit.
			@JSONOptional string dmdModel = CommonConfig.defaultModel;

			/// How to build DMD versions written in D.
			/// We can either download a pre-built binary DMD
			/// package, or build an  earlier version from source
			/// (e.g. starting with the last C++-only version.)
			struct Bootstrap
			{
				/// Whether to download a pre-built D version,
				/// or build one from source. If set, then build
				/// from source according to the value of ver,
				@JSONOptional bool fromSource = false;

				/// Version specification.
				/// When building from source, syntax can be defined
				/// by outer application (see parseSpec method);
				/// When the bootstrapping compiler is not built from source,
				/// it is understood as a version number, such as "v2.070.2",
				/// which also doubles as a tag name.
				/// By default (when set to null), an appropriate version
				/// is selected automatically.
				@JSONOptional string ver = null;

				/// Build configuration for the compiler used for bootstrapping.
				/// If not set, then use the default build configuration.
				/// Used when fromSource is set.
				@JSONOptional DManager.Config.Build* build;
			}
			@JSONOptional Bootstrap bootstrap; /// ditto

			/// Use Visual C++ to build DMD instead of DMC.
			/// Currently, this is a hack, as msbuild will consult the system
			/// registry and use the system-wide installation of Visual Studio.
			/// Only relevant for older versions, as newer versions are written in D.
			@JSONOptional bool useVC;
		}

		protected @property override string configString()
		{
			static struct FullConfig
			{
				Config config;
				string[] makeArgs;

				// Include the common models as well as the DMD model (from config).
				// Necessary to ensure the correct sc.ini is generated on Windows
				// (we don't want to pull in MSVC unless either DMD or Phobos are
				// built as 64-bit, but also we can't reuse a DMD build with 32-bit
				// DMD and Phobos for a 64-bit Phobos build because it won't have
				// the VC vars set up in its sc.ini).
				// Possibly refactor the compiler configuration to a separate
				// component in the future to avoid the inefficiency of rebuilding
				// DMD just to generate a different sc.ini.
				@JSONOptional string commonModel = Component.CommonConfig.defaultModel;
			}

			return FullConfig(
				config.build.components.dmd,
				config.build.components.common.makeArgs,
				config.build.components.common.model,
			).toJson();
		} ///

		/// Name of the Visual Studio build configuration to use.
		@property string vsConfiguration() { return config.build.components.dmd.debugDMD ? "Debug" : "Release"; }
		/// Name of the Visual Studio build platform to use.
		@property string vsPlatform     () { return config.build.components.dmd.dmdModel == "64" ? "x64" : "Win32"; }

		protected override void performBuild()
		{
			// We need an older DMC for older DMD versions
			string dmcVer = null;
			auto idgen = buildPath(sourceDir, "src", "idgen.c");
			if (idgen.exists && idgen.readText().indexOf(`{ "alignof" },`) >= 0)
				dmcVer = "850";

			auto env = baseEnvironment;
			needCC(env, config.build.components.dmd.dmdModel, dmcVer); // Need VC too for VSINSTALLDIR

			auto srcDir = buildPath(sourceDir, "src");
			string dmdMakeFileName = findMakeFile(srcDir, makeFileName);
			string dmdMakeFullName = srcDir.buildPath(dmdMakeFileName);

			if (buildPath(sourceDir, "src", "idgen.d").exists ||
			    buildPath(sourceDir, "src", "ddmd", "idgen.d").exists ||
			    buildPath(sourceDir, "src", "ddmd", "mars.d").exists ||
			    buildPath(sourceDir, "src", "dmd", "mars.d").exists)
			{
				// Need an older DMD for bootstrapping.
				string dmdVer = "v2.067.1";
				if (sourceDir.buildPath("test/compilable/staticforeach.d").exists)
					dmdVer = "v2.068.0";
				version (Windows)
					if (config.build.components.dmd.dmdModel != Component.CommonConfig.defaultModel)
						dmdVer = "v2.070.2"; // dmd/src/builtin.d needs core.stdc.math.fabsl. 2.068.2 generates a dmd which crashes on building Phobos
				if (sourceDir.buildPath("src/dmd/backend/dvec.d").exists) // 2.079 is needed since 2.080
					dmdVer = "v2.079.0";
				needDMD(env, dmdVer);

				// Go back to our commit (in case we bootstrapped from source).
				needSource(true);
				submodule.clean = false;
			}

			if (config.build.components.dmd.useVC) // Mostly obsolete, see useVC ddoc
			{
				version (Windows)
				{
					needVC(env, config.build.components.dmd.dmdModel);

					env.vars["PATH"] = env.vars["PATH"] ~ pathSeparator ~ env.deps.hostDC.dirName;

					auto solutionFile = `dmd_msc_vs10.sln`;
					if (!exists(srcDir.buildPath(solutionFile)))
						solutionFile = `vcbuild\dmd.sln`;
					if (!exists(srcDir.buildPath(solutionFile)))
						throw new Exception("Can't find Visual Studio solution file");

					return run(["msbuild", "/p:Configuration=" ~ vsConfiguration, "/p:Platform=" ~ vsPlatform, solutionFile], env.vars, srcDir);
				}
				else
					throw new Exception("Can only use Visual Studio on Windows");
			}

			version (Windows)
				auto scRoot = env.deps.dmcDir.absolutePath();

			string modelFlag = config.build.components.dmd.dmdModel;
			if (dmdMakeFullName.readText().canFind("MODEL=-m32"))
				modelFlag = "-m" ~ modelFlag;

			version (Windows)
			{
				auto m = dmdMakeFullName.readText();
				m = m
					// A make argument is insufficient,
					// because of recursive make invocations
					.replace(`CC=\dm\bin\dmc`, `CC=dmc`)
					.replace(`SCROOT=$D\dm`, `SCROOT=` ~ scRoot)
					// Debug crashes in build.d
					.replaceAll(re!(`^(	\$\(HOST_DC\) .*) (build\.d)$`, "m"), "$1 -g $2")
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
					// Fix compilation of older versions of go.c with GCC 6
					.replace(`-Wno-deprecated`, `-Wno-deprecated -Wno-narrowing`)
				;
				// Fix pthread linker error
				version (linux)
					m = m.replace(`-lpthread`, `-pthread`);
				dmdMakeFullName.write(m);
			}

			submodule.saveFileState("src/" ~ dmdMakeFileName);

			version (Windows)
			{
				auto buildDFileName = "build.d";
				auto buildDPath = srcDir.buildPath(buildDFileName);
				if (buildDPath.exists)
				{
					auto buildD = buildDPath.readText();
					buildD = buildD
						// https://github.com/dlang/dmd/pull/10491
						// Needs WBEM PATH entry, and also fails under Wine as its wmic outputs UTF-16.
						.replace(`["wmic", "OS", "get", "OSArchitecture"].execute.output`, isWin64 ? `"64-bit"` : `"32-bit"`)
					;
					buildDPath.write(buildD);
					submodule.saveFileState("src/" ~ buildDFileName);
				}
			}

			// Fix compilation error of older DMDs with glibc >= 2.25
			version (linux)
			{{
				auto fn = srcDir.buildPath("root", "port.c");
				if (fn.exists)
				{
					fn.write(fn.readText
						.replace(`#include <bits/mathdef.h>`, `#include <complex.h>`)
						.replace(`#include <bits/nan.h>`, `#include <math.h>`)
					);
					submodule.saveFileState(fn.relativePath(sourceDir));
				}
			}}

			// Fix alignment issue in older DMDs with GCC >= 7
			// See https://issues.dlang.org/show_bug.cgi?id=17726
			version (Posix)
			{
				foreach (fn; [srcDir.buildPath("tk", "mem.c"), srcDir.buildPath("ddmd", "tk", "mem.c")])
					if (fn.exists)
					{
						fn.write(fn.readText.replace(
								// `#if defined(__llvm__) && (defined(__GNUC__) || defined(__clang__))`,
								// `#if defined(__GNUC__) || defined(__clang__)`,
								`numbytes = (numbytes + 3) & ~3;`,
								`numbytes = (numbytes + 0xF) & ~0xF;`
						));
						submodule.saveFileState(fn.relativePath(sourceDir));
					}
			}

			string[] extraArgs, targets;
			version (Posix)
			{
				if (config.build.components.dmd.debugDMD)
					extraArgs ~= "DEBUG=1";
				if (config.build.components.dmd.releaseDMD)
					extraArgs ~= "ENABLE_RELEASE=1";
			}
			else
			{
				if (config.build.components.dmd.debugDMD)
					targets ~= [];
				else
				if (config.build.components.dmd.releaseDMD && dmdMakeFullName.readText().canFind("reldmd"))
					targets ~= ["reldmd"];
				else
					targets ~= ["dmd"];
			}

			version (Windows)
			{
				if (config.build.components.dmd.dmdModel != CommonConfig.defaultModel)
				{
					dmdMakeFileName = "win64.mak";
					dmdMakeFullName = srcDir.buildPath(dmdMakeFileName);
					enforce(dmdMakeFullName.exists, "dmdModel not supported for this DMD version");
					extraArgs ~= "DMODEL=-m" ~ config.build.components.dmd.dmdModel;
					if (config.build.components.dmd.dmdModel == "32mscoff")
					{
						auto objFiles = dmdMakeFullName.readText().splitLines().filter!(line => line.startsWith("OBJ_MSVC="));
						enforce(!objFiles.empty, "Can't find OBJ_MSVC in win64.mak");
						extraArgs ~= "OBJ_MSVC=" ~ objFiles.front.findSplit("=")[2].split().filter!(obj => obj != "ldfpu.obj").join(" ");
					}
				}
			}

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
				] ~ config.build.components.common.makeArgs ~ dMakeArgs ~ extraArgs ~ targets,
				env.vars, srcDir
			);
		}

		protected override void performStage()
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
				string dmdPath = buildPath(sourceDir, "generated", platform, "release", config.build.components.dmd.dmdModel, "dmd" ~ binExt);
				if (!dmdPath.exists)
					dmdPath = buildPath(sourceDir, "src", "dmd" ~ binExt); // legacy
				enforce(dmdPath.exists && dmdPath.isFile, "Can't find built DMD executable");

				cp(
					dmdPath,
					buildPath(stageDir , "bin", "dmd" ~ binExt),
				);
			}

			version (Windows)
			{
				auto env = baseEnvironment;
				needCC(env, config.build.components.dmd.dmdModel);
				foreach (model; config.build.components.common.models)
					needCC(env, model);

				auto ini = q"EOS
[Environment]
LIB=%@P%\..\lib
DFLAGS="-I%@P%\..\import"
DMC=__DMC__
LINKCMD=%DMC%\link.exe
EOS"
				.replace("__DMC__", env.deps.dmcDir.buildPath(`bin`).absolutePath())
			;

				if (env.deps.vsDir && env.deps.sdkDir)
				{
					ini ~= q"EOS

[Environment64]
LIB=%@P%\..\lib
DFLAGS=%DFLAGS% -L/OPT:NOICF
VSINSTALLDIR=__VS__\
VCINSTALLDIR=%VSINSTALLDIR%VC\
PATH=%PATH%;%VCINSTALLDIR%\bin\__MODELDIR__;%VCINSTALLDIR%\bin
WindowsSdkDir=__SDK__
LINKCMD=%VCINSTALLDIR%\bin\__MODELDIR__\link.exe
LIB=%LIB%;%VCINSTALLDIR%\lib\amd64
LIB=%LIB%;%WindowsSdkDir%\Lib\x64

[Environment32mscoff]
LIB=%@P%\..\lib
DFLAGS=%DFLAGS% -L/OPT:NOICF
VSINSTALLDIR=__VS__\
VCINSTALLDIR=%VSINSTALLDIR%VC\
PATH=%PATH%;%VCINSTALLDIR%\bin
WindowsSdkDir=__SDK__
LINKCMD=%VCINSTALLDIR%\bin\link.exe
LIB=%LIB%;%VCINSTALLDIR%\lib
LIB=%LIB%;%WindowsSdkDir%\Lib
EOS"
						.replace("__VS__"      , env.deps.vsDir .absolutePath())
						.replace("__SDK__"     , env.deps.sdkDir.absolutePath())
						.replace("__MODELDIR__", msvcModelDir("64"))
					;
				}

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
			else version (linux)
			{
				auto ini = q"EOS
[Environment32]
DFLAGS="-I%@P%/../import" "-L-L%@P%/../lib" -L--export-dynamic

[Environment64]
DFLAGS="-I%@P%/../import" "-L-L%@P%/../lib" -L--export-dynamic -fPIC
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

		protected override void updateEnv(ref Environment env)
		{
			// Add the DMD we built for Phobos/Druntime/Tools
			env.vars["PATH"] = buildPath(buildDir, "bin").absolutePath() ~ pathSeparator ~ env.vars["PATH"];
		}

		protected override void performTest()
		{
			foreach (dep; ["dmd", "druntime", "phobos"])
				getComponent(dep).needBuild(true);

			foreach (model; config.build.components.common.models)
			{
				auto env = baseEnvironment;
				version (Windows)
				{
					// In this order so it uses the MSYS make
					needCC(env, model);
					needMSYS(env);

					disableCrashDialog();
				}

				auto makeArgs = getMake(env) ~ config.build.components.common.makeArgs ~ getPlatformMakeVars(env, model) ~ gnuMakeArgs;
				version (Windows)
				{
					makeArgs ~= ["OS=win" ~ model[0..2], "SHELL=bash"];
					if (model == "32")
					{
						auto extrasDir = needExtras();
						// The autotester seems to pass this via environment. Why does that work there???
						makeArgs ~= "LIB=" ~ extrasDir.buildPath("localextras-windows", "dmd2", "windows", "lib") ~ `;..\..\phobos`;
					}
					else
					{
						// Fix path for d_do_test and its special escaping (default is the system VS2010 install)
						// We can't use the same syntax in getPlatformMakeVars because win64.mak uses "CC=\$(CC32)"\""
						auto cl = env.deps.vsDir.buildPath("VC", "bin", msvcModelDir(model), "cl.exe");
						foreach (ref arg; makeArgs)
							if (arg.startsWith("CC="))
								arg = "CC=" ~ dDoTestEscape(cl);
					}
				}

				version (test)
				{
					// Only try a few tests during CI runs, to check for
					// platform integration and correct invocation.
					// For this purpose, the C++ ABI tests will do nicely.
					makeArgs ~= [
					//	"test_results/runnable/cppa.d.out", // https://github.com/dlang/dmd/pull/5686
						"test_results/runnable/cpp_abi_tests.d.out",
						"test_results/runnable/cabi1.d.out",
					];
				}

				run(makeArgs, env.vars, sourceDir.buildPath("test"));
			}
		}
	}

	/// Phobos import files.
	/// In older versions of D, Druntime depended on Phobos modules.
	final class PhobosIncludes : Component
	{
		protected @property override string submoduleName() { return "phobos"; }
		protected @property override string[] sourceDependencies() { return []; }
		protected @property override string[] dependencies() { return []; }
		protected @property override string configString() { return null; }

		protected override void performStage()
		{
			foreach (f; ["std", "etc", "crc32.d"])
				if (buildPath(sourceDir, f).exists)
					cp(
						buildPath(sourceDir, f),
						buildPath(stageDir , "import", f),
					);
		}
	}

	/// Druntime. Installs only import files, but builds the library too.
	final class Druntime : Component
	{
		protected @property override string submoduleName    () { return "druntime"; }
		protected @property override string[] sourceDependencies() { return ["phobos", "phobos-includes"]; }
		protected @property override string[] dependencies() { return ["dmd"]; }

		protected @property override string configString()
		{
			static struct FullConfig
			{
				string model;
				string[] makeArgs;
			}

			return FullConfig(
				config.build.components.common.model,
				config.build.components.common.makeArgs,
			).toJson();
		}

		protected override void performBuild()
		{
			version (Posix)
			{{
				auto fn = sourceDir.buildPath("posix.mak");
				if (fn.exists)
				{
					fn.write(fn.readText
						// Fix use of bash shell syntax on systems with non-bash /bin/sh
						.replace("$(DMD_DIR)/{druntime/import,generated}", "$(DMD_DIR)/druntime/import $(DMD_DIR)/generated")
					);
					submodule.saveFileState(fn.relativePath(sourceDir));
				}
			}}

			foreach (model; config.build.components.common.models)
			{
				auto env = baseEnvironment;
				needCC(env, model);

				if (needHostDMD)
				{
					enum dmdVer = "v2.079.0"; // Same as latest version in DMD.performBuild
					needDMD(env, dmdVer);
				}

				getComponent("phobos").needSource();
				getComponent("dmd").needSource();
				getComponent("dmd").needInstalled();
				getComponent("phobos-includes").needInstalled();

				mkdirRecurse(sourceDir.buildPath("import"));
				mkdirRecurse(sourceDir.buildPath("lib"));

				setTimes(sourceDir.buildPath("src", "rt", "minit.obj"), Clock.currTime(), Clock.currTime()); // Don't rebuild
				submodule.saveFileState("src/rt/minit.obj");

				runMake(env, model, "import");
				runMake(env, model);
			}
		}

		protected override void performStage()
		{
			cp(
				buildPath(sourceDir, "import"),
				buildPath(stageDir , "import"),
			);
		}

		protected override void performTest()
		{
			getComponent("druntime").needBuild(true);
			getComponent("dmd").needInstalled();

			foreach (model; config.build.components.common.models)
			{
				auto env = baseEnvironment;
				needCC(env, model);
				runMake(env, model, "unittest");
			}
		}

		private bool needHostDMD()
		{
			version (Windows)
				return sourceDir.buildPath("mak", "copyimports.d").exists;
			else
				return false;
		}

		private final void runMake(ref Environment env, string model, string target = null)
		{
			// Work around https://github.com/dlang/druntime/pull/2438
			bool quotePaths = !(isVersion!"Windows" && model != "32" && sourceDir.buildPath("win64.mak").readText().canFind(`"$(CC)"`));

			string[] args =
				getMake(env) ~
				["-f", makeFileNameModel(model)] ~
				(target ? [target] : []) ~
				["DMD=" ~ dmd] ~
				(needHostDMD ? ["HOST_DMD=" ~ env.deps.hostDC] : []) ~
				(config.build.components.common.debugLib ? ["BUILD=debug"] : []) ~
				config.build.components.common.makeArgs ~
				getPlatformMakeVars(env, model, quotePaths) ~
				dMakeArgs;
			run(args, env.vars, sourceDir);
		}
	}

	/// Phobos library and imports.
	final class Phobos : Component
	{
		protected @property override string submoduleName    () { return "phobos"; }
		protected @property override string[] sourceDependencies() { return []; }
		protected @property override string[] dependencies() { return ["druntime", "dmd"]; }

		protected @property override string configString()
		{
			static struct FullConfig
			{
				string model;
				string[] makeArgs;
			}

			return FullConfig(
				config.build.components.common.model,
				config.build.components.common.makeArgs,
			).toJson();
		}

		private string[] targets;

		protected override void performBuild()
		{
			getComponent("dmd").needSource();
			getComponent("dmd").needInstalled();
			getComponent("druntime").needBuild();

			targets = null;

			foreach (model; config.build.components.common.models)
			{
				// Clean up old object files with mismatching model.
				// Necessary for a consecutive 32/64 build.
				version (Windows)
				{
					foreach (de; dirEntries(sourceDir.buildPath("etc", "c", "zlib"), "*.obj", SpanMode.shallow))
					{
						auto data = cast(ubyte[])read(de.name);

						string fileModel;
						if (data.length < 4)
							fileModel = "invalid";
						else
						if (data[0] == 0x80)
							fileModel = "32"; // OMF
						else
						if (data[0] == 0x01 && data[0] == 0x4C)
							fileModel = "32mscoff"; // COFF - IMAGE_FILE_MACHINE_I386
						else
						if (data[0] == 0x86 && data[0] == 0x64)
							fileModel = "64"; // COFF - IMAGE_FILE_MACHINE_AMD64
						else
							fileModel = "unknown";

						if (fileModel != model)
						{
							log("Cleaning up object file '%s' with mismatching model (file is %s, building %s)".format(de.name, fileModel, model));
							remove(de.name);
						}
					}
				}

				auto env = baseEnvironment;
				needCC(env, model);

				string phobosMakeFileName = findMakeFile(sourceDir, makeFileNameModel(model));
				string phobosMakeFullName = sourceDir.buildPath(phobosMakeFileName);

				version (Windows)
				{
					auto lib = "phobos%s.lib".format(modelSuffix(model));
					runMake(env, model, lib);
					enforce(sourceDir.buildPath(lib).exists);
					targets ~= ["phobos%s.lib".format(modelSuffix(model))];
				}
				else
				{
					string[] makeArgs;
					if (phobosMakeFullName.readText().canFind("DRUNTIME = $(DRUNTIME_PATH)/lib/libdruntime-$(OS)$(MODEL).a") &&
						getComponent("druntime").sourceDir.buildPath("lib").dirEntries(SpanMode.shallow).walkLength == 0 &&
						exists(getComponent("druntime").sourceDir.buildPath("generated")))
					{
						auto dir = getComponent("druntime").sourceDir.buildPath("generated");
						auto aFile  = dir.dirEntries("libdruntime.a", SpanMode.depth);
						if (!aFile .empty) makeArgs ~= ["DRUNTIME="   ~ aFile .front];
						auto soFile = dir.dirEntries("libdruntime.so.a", SpanMode.depth);
						if (!soFile.empty) makeArgs ~= ["DRUNTIMESO=" ~ soFile.front];
					}
					runMake(env, model, makeArgs);
					targets ~= sourceDir
						.buildPath("generated")
						.dirEntries(SpanMode.depth)
						.filter!(de => de.name.endsWith(".a") || de.name.endsWith(".so"))
						.map!(de => de.name.relativePath(sourceDir))
						.array()
					;
				}
			}
		}

		protected override void performStage()
		{
			assert(targets.length, "Phobos stage without build");
			foreach (lib; targets)
				cp(
					buildPath(sourceDir, lib),
					buildPath(stageDir , "lib", lib.baseName()),
				);
		}

		protected override void performTest()
		{
			getComponent("druntime").needBuild(true);
			getComponent("phobos").needBuild(true);
			getComponent("dmd").needInstalled();

			foreach (model; config.build.components.common.models)
			{
				auto env = baseEnvironment;
				needCC(env, model);
				version (Windows)
				{
					getComponent("curl").needInstalled();
					getComponent("curl").updateEnv(env);

					// Patch out std.datetime unittest to work around Digger test
					// suite failure on AppVeyor due to Windows time zone changes
					auto stdDateTime = buildPath(sourceDir, "std", "datetime.d");
					if (stdDateTime.exists && !stdDateTime.readText().canFind("Altai Standard Time"))
					{
						auto m = stdDateTime.readText();
						m = m
							.replace(`assert(tzName !is null, format("TZName which is missing: %s", winName));`, ``)
							.replace(`assert(tzDatabaseNameToWindowsTZName(tzName) !is null, format("TZName which failed: %s", tzName));`, `{}`)
							.replace(`assert(windowsTZNameToTZDatabaseName(tzName) !is null, format("TZName which failed: %s", tzName));`, `{}`)
						;
						stdDateTime.write(m);
						submodule.saveFileState("std/datetime.d");
					}

					if (model == "32")
						getComponent("extras").needInstalled();
				}
				runMake(env, model, "unittest");
			}
		}

		private final void runMake(ref Environment env, string model, string[] makeArgs...)
		{
			// Work around https://github.com/dlang/druntime/pull/2438
			bool quotePaths = !(isVersion!"Windows" && model != "32" && sourceDir.buildPath("win64.mak").readText().canFind(`"$(CC)"`));

			string[] args =
				getMake(env) ~
				["-f", makeFileNameModel(model)] ~
				makeArgs ~
				["DMD=" ~ dmd] ~
				config.build.components.common.makeArgs ~
				(config.build.components.common.debugLib ? ["BUILD=debug"] : []) ~
				getPlatformMakeVars(env, model, quotePaths) ~
				dMakeArgs;
			run(args, env.vars, sourceDir);
		}
	}

	/// The rdmd build tool by itself.
	/// It predates the tools package.
	final class RDMD : Component
	{
		protected @property override string submoduleName() { return "tools"; }
		protected @property override string[] sourceDependencies() { return []; }
		protected @property override string[] dependencies() { return ["dmd", "druntime", "phobos"]; }

		private @property string model() { return config.build.components.common.models.get(0); }

		protected @property override string configString()
		{
			static struct FullConfig
			{
				string model;
			}

			return FullConfig(
				this.model,
			).toJson();
		}

		protected override void performBuild()
		{
			foreach (dep; ["dmd", "druntime", "phobos", "phobos-includes"])
				getComponent(dep).needInstalled();

			auto env = baseEnvironment;
			needCC(env, this.model);

			// Just build rdmd
			bool needModel; // Need -mXX switch?

			if (sourceDir.buildPath("posix.mak").exists)
				needModel = true; // Known to be needed for recent versions

			string[] args;
			if (needConfSwitch())
				args ~= ["-conf=" ~ buildPath(buildDir , "bin", configFileName)];
			args ~= ["rdmd"];

			if (!needModel)
				try
					run([dmd] ~ args, env.vars, sourceDir);
				catch (Exception e)
					needModel = true;

			if (needModel)
				run([dmd, "-m" ~ this.model] ~ args, env.vars, sourceDir);
		}

		protected override void performStage()
		{
			cp(
				buildPath(sourceDir, "rdmd" ~ binExt),
				buildPath(stageDir , "bin", "rdmd" ~ binExt),
			);
		}

		protected override void performTest()
		{
			auto env = baseEnvironment;
			version (Windows)
				needDMC(env); // Need DigitalMars Make

			string[] args;
			if (sourceDir.buildPath(makeFileName).readText.canFind("\ntest_rdmd"))
				args = getMake(env) ~ ["-f", makeFileName, "test_rdmd", "DFLAGS=-g -m" ~ model] ~ config.build.components.common.makeArgs ~ getPlatformMakeVars(env, model) ~ dMakeArgs;
			else
			{
				// Legacy (before makefile rules)

				args = ["dmd", "-m" ~ this.model, "-run", "rdmd_test.d"];
				if (sourceDir.buildPath("rdmd_test.d").readText.canFind("modelSwitch"))
					args ~= "--model=" ~ this.model;
				else
				{
					version (Windows)
						if (this.model != "32")
						{
							// Can't test rdmd on non-32-bit Windows until compiler model matches Phobos model.
							// rdmd_test does not use -m when building rdmd, thus linking will fail
							// (because of model mismatch with the phobos we built).
							log("Can't test rdmd with model " ~ this.model ~ ", skipping");
							return;
						}
				}
			}

			foreach (dep; ["dmd", "druntime", "phobos", "phobos-includes"])
				getComponent(dep).needInstalled();

			getComponent("dmd").updateEnv(env);
			run(args, env.vars, sourceDir);
		}
	}

	/// Tools package with all its components, including rdmd.
	final class Tools : Component
	{
		protected @property override string submoduleName() { return "tools"; }
		protected @property override string[] sourceDependencies() { return []; }
		protected @property override string[] dependencies() { return ["dmd", "druntime", "phobos"]; }

		private @property string model() { return config.build.components.common.models.get(0); }

		protected @property override string configString()
		{
			static struct FullConfig
			{
				string model;
				string[] makeArgs;
			}

			return FullConfig(
				this.model,
				config.build.components.common.makeArgs,
			).toJson();
		}

		protected override void performBuild()
		{
			getComponent("dmd").needSource();
			foreach (dep; ["dmd", "druntime", "phobos"])
				getComponent(dep).needInstalled();

			auto env = baseEnvironment;
			needCC(env, this.model);

			run(getMake(env) ~ ["-f", makeFileName, "DMD=" ~ dmd] ~ config.build.components.common.makeArgs ~ getPlatformMakeVars(env, this.model) ~ dMakeArgs, env.vars, sourceDir);
		}

		protected override void performStage()
		{
			foreach (os; buildPath(sourceDir, "generated").dirEntries(SpanMode.shallow))
				foreach (de; os.buildPath(this.model).dirEntries(SpanMode.shallow))
					if (de.extension == binExt)
						cp(de, buildPath(stageDir, "bin", de.baseName));
		}
	}

	/// Website (dlang.org). Only buildable on POSIX.
	final class Website : Component
	{
		protected @property override string submoduleName() { return "dlang.org"; }
		protected @property override string[] sourceDependencies() { return ["druntime", "phobos", "dub"]; }
		protected @property override string[] dependencies() { return ["dmd", "druntime", "phobos", "rdmd"]; }

		/// Website build configuration.
		struct Config
		{
			/// Do not include timestamps, line numbers, or other
			/// volatile dynamic content in generated .ddoc files.
			/// Improves cache efficiency and allows meaningful diffs.
			bool diffable = false;

			deprecated alias noDateTime = diffable;
		}

		protected @property override string configString()
		{
			static struct FullConfig
			{
				Config config;
			}

			return FullConfig(
				config.build.components.website,
			).toJson();
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
								if (r.match(re!`^v2\.\d\d\d(\.\d)?$`))
									return r[1..$];
					}
			throw new Exception("Can't find any DMD version tags at this point!");
		}

		private enum Target { build, test }

		private void make(Target target)
		{
			foreach (dep; ["dmd", "druntime", "phobos"])
			{
				auto c = getComponent(dep);
				c.needInstalled();

				// Need DMD source because https://github.com/dlang/phobos/pull/4613#issuecomment-266462596
				// Need Druntime/Phobos source because we are building its documentation from there.
				c.needSource();
			}
			foreach (dep; ["tools", "dub"]) // for changelog; also tools for changed.d
				getComponent(dep).needSource();

			auto env = baseEnvironment;

			version (Windows)
				throw new Exception("The dlang.org website is only buildable on POSIX platforms.");
			else
			{
				getComponent("dmd").updateEnv(env);

				// Need an in-tree build for SYSCONFDIR.imp, which is
				// needed to parse .d files for the DMD API
				// documentation.
				getComponent("dmd").needBuild(target == Target.test);

				// Need the installer repository to at least be a Git repository
				getComponent("installer").needSource(false);

				needKindleGen(env);

				foreach (dep; dependencies)
					getComponent(dep).submodule.clean = false;

				auto makeFullName = sourceDir.buildPath(makeFileName);
				auto makeSrc = makeFullName.readText();
				makeSrc
					// https://github.com/D-Programming-Language/dlang.org/pull/1011
					.replace(": modlist.d", ": modlist.d $(DMD)")
					// https://github.com/D-Programming-Language/dlang.org/pull/1017
					.replace("dpl-docs: ${DUB} ${STABLE_DMD}\n\tDFLAGS=", "dpl-docs: ${DUB} ${STABLE_DMD}\n\t${DUB} upgrade --missing-only --root=${DPL_DOCS_PATH}\n\tDFLAGS=")
					.toFile(makeFullName)
				;
				submodule.saveFileState(makeFileName);

				// Retroactive OpenSSL 1.1.0 fix
				// See https://github.com/dlang/dlang.org/pull/1654
				auto dubJson = sourceDir.buildPath("dpl-docs/dub.json");
				dubJson
					.readText()
					.replace(`"versions": ["VibeCustomMain"]`, `"versions": ["VibeCustomMain", "VibeNoSSL"]`)
					.toFile(dubJson);
				submodule.saveFileState("dpl-docs/dub.json");
				scope(exit) submodule.saveFileState("dpl-docs/dub.selections.json");

				string latest = null;
				if (!sourceDir.buildPath("VERSION").exists)
				{
					latest = getLatest();
					log("LATEST=" ~ latest);
				}
				else
					log("VERSION file found, not passing LATEST parameter");

				string[] diffable = null;

				auto pdf = makeSrc.indexOf("pdf") >= 0 ? ["pdf"] : [];

				string[] targets =
					[
						config.build.components.website.diffable
						? makeSrc.indexOf("dautotest") >= 0
							? ["dautotest"]
							: ["all", "verbatim"] ~ pdf ~ (
								makeSrc.indexOf("diffable-intermediaries") >= 0
								? ["diffable-intermediaries"]
								: ["dlangspec.html"])
						: ["all", "verbatim", "kindle"] ~ pdf,
						["test"]
					][target];

				if (config.build.components.website.diffable)
				{
					if (makeSrc.indexOf("DIFFABLE") >= 0)
						diffable = ["DIFFABLE=1"];
					else
						diffable = ["NODATETIME=nodatetime.ddoc"];

					env.vars["SOURCE_DATE_EPOCH"] = "0";
				}

				auto args =
					getMake(env) ~
					[ "-f", makeFileName ] ~
					diffable ~
					(latest ? ["LATEST=" ~ latest] : []) ~
					targets ~
					gnuMakeArgs;
				run(args, env.vars, sourceDir);
			}
		}

		protected override void performBuild()
		{
			make(Target.build);
		}

		protected override void performTest()
		{
			make(Target.test);
		}

		protected override void performStage()
		{
			foreach (item; ["web", "dlangspec.tex", "dlangspec.html"])
			{
				auto src = buildPath(sourceDir, item);
				auto dst = buildPath(stageDir , item);
				if (src.exists)
					cp(src, dst);
			}
		}
	}

	/// Extras not built from source (DigitalMars and third-party tools and libraries)
	final class Extras : Component
	{
		protected @property override string submoduleName() { return null; }
		protected @property override string[] sourceDependencies() { return []; }
		protected @property override string[] dependencies() { return []; }
		protected @property override string configString() { return null; }

		protected override void performBuild()
		{
			needExtras();
		}

		protected override void performStage()
		{
			auto extrasDir = needExtras();

			void copyDir(string source, string target)
			{
				source = buildPath(extrasDir, "localextras-" ~ platform, "dmd2", platform, source);
				target = buildPath(stageDir, target);
				if (source.exists)
					cp(source, target);
			}

			copyDir("bin", "bin");
			foreach (model; config.build.components.common.models)
				copyDir("bin" ~ model, "bin");
			copyDir("lib", "lib");

			version (Windows)
				foreach (model; config.build.components.common.models)
					if (model == "32")
					{
						// The version of snn.lib bundled with DMC will be newer.
						Environment env;
						needDMC(env);
						cp(buildPath(env.deps.dmcDir, "lib", "snn.lib"), buildPath(stageDir, "lib", "snn.lib"));
					}
		}
	}

	/// libcurl DLL and import library for Windows.
	final class Curl : Component
	{
		protected @property override string submoduleName() { return null; }
		protected @property override string[] sourceDependencies() { return []; }
		protected @property override string[] dependencies() { return []; }
		protected @property override string configString() { return null; }

		protected override void performBuild()
		{
			version (Windows)
				needCurl();
			else
				log("Not on Windows, skipping libcurl download");
		}

		protected override void performStage()
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

				foreach (model; config.build.components.common.models)
				{
					auto suffix = model == "64" ? "64" : "";
					copyDir("bin" ~ suffix, "bin");
					copyDir("lib" ~ suffix, "lib");
				}
			}
			else
				log("Not on Windows, skipping libcurl install");
		}

		protected override void updateEnv(ref Environment env)
		{
			env.vars["PATH"] = buildPath(buildDir, "bin").absolutePath() ~ pathSeparator ~ env.vars["PATH"];
		}
	}

	/// The Dub package manager and build tool
	final class Dub : Component
	{
		protected @property override string submoduleName() { return "dub"; }
		protected @property override string[] sourceDependencies() { return []; }
		protected @property override string[] dependencies() { return []; }
		protected @property override string configString() { return null; }

		protected override void performBuild()
		{
			auto env = baseEnvironment;
			run([dmd, "-i", "-run", "build.d"], env.vars, sourceDir);
		}

		protected override void performStage()
		{
			cp(
				buildPath(sourceDir, "bin", "dub" ~ binExt),
				buildPath(stageDir , "bin", "dub" ~ binExt),
			);
		}
	}

	/// Stub for the installer repository, which is needed by the dlang.org makefiles.
	final class DInstaller : Component
	{
		protected @property override string submoduleName() { return "installer"; }
		protected @property override string[] sourceDependencies() { return []; }
		protected @property override string[] dependencies() { return []; }
		protected @property override string configString() { return null; }

		protected override void performBuild()
		{
			assert(false, "Not implemented");
		}

		protected override void performStage()
		{
			assert(false, "Not implemented");
		}
	}

	private int tempError;

	private Component[string] components;

	/// Retrieve a component by name
	/// (as it would occur in `config.build.components.enable`).
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
				case "tools":
					c = new Tools();
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
				case "dub":
					c = new Dub();
					break;
				case "installer":
					c = new DInstaller();
					break;
				default:
					throw new Exception("Unknown component: " ~ name);
			}

			c.name = name;
			return components[name] = c;
		}

		return components[name];
	}

	/// Retrieve components built from the given submodule name.
	Component[] getSubmoduleComponents(string submoduleName)
	{
		return components
			.byValue
			.filter!(component => component.submoduleName == submoduleName)
			.array();
	}

	// ***************************** GitHub API ******************************

	private GitHub github;

	private ref GitHub needGitHub()
	{
		if (github is GitHub.init)
		{
			github.log = &this.log;
			github.token = config.local.githubToken;
			github.cache = new class GitHub.ICache
			{
				final string cacheFileName(string key)
				{
					return githubDir.buildPath(getDigestString!MD5(key).toLower());
				}

				string get(string key)
				{
					auto fn = cacheFileName(key);
					return fn.exists ? fn.readText : null;
				}

				void put(string key, string value)
				{
					githubDir.ensureDirExists;
					std.file.write(cacheFileName(key), value);
				}
			};
			github.offline = config.local.offline;
		}
		return github;
	}

	// **************************** Customization ****************************

	/// Fetch latest D history.
	/// Return true if any updates were fetched.
	bool update()
	{
		return getMetaRepo().update();
	}

	/// Indicates the state of a build customization.
	struct SubmoduleState
	{
		string[string] submoduleCommits; /// Commit hashes of submodules to build.
	}

	/// Begin customization, starting at the specified commit.
	SubmoduleState begin(string commit)
	{
		log("Starting at meta repository commit " ~ commit);
		return SubmoduleState(getMetaRepo().getSubmoduleCommits(commit));
	}

	alias MergeMode = ManagedRepository.MergeMode; ///

	/// Applies a merge onto the given SubmoduleState.
	void merge(ref SubmoduleState submoduleState, string submoduleName, string[2] branch, MergeMode mode)
	{
		log("Merging %s commits %s..%s".format(submoduleName, branch[0], branch[1]));
		enforce(submoduleName in submoduleState.submoduleCommits, "Unknown submodule: " ~ submoduleName);
		auto submodule = getSubmodule(submoduleName);
		auto head = submoduleState.submoduleCommits[submoduleName];
		auto result = submodule.getMerge(head, branch, mode);
		submoduleState.submoduleCommits[submoduleName] = result;
	}

	/// Removes a merge from the given SubmoduleState.
	void unmerge(ref SubmoduleState submoduleState, string submoduleName, string[2] branch, MergeMode mode)
	{
		log("Unmerging %s commits %s..%s".format(submoduleName, branch[0], branch[1]));
		enforce(submoduleName in submoduleState.submoduleCommits, "Unknown submodule: " ~ submoduleName);
		auto submodule = getSubmodule(submoduleName);
		auto head = submoduleState.submoduleCommits[submoduleName];
		auto result = submodule.getUnMerge(head, branch, mode);
		submoduleState.submoduleCommits[submoduleName] = result;
	}

	/// Reverts a commit from the given SubmoduleState.
	/// parent is the 1-based mainline index (as per `man git-revert`),
	/// or 0 if commit is not a merge commit.
	void revert(ref SubmoduleState submoduleState, string submoduleName, string[2] branch, MergeMode mode)
	{
		log("Reverting %s commits %s..%s".format(submoduleName, branch[0], branch[1]));
		enforce(submoduleName in submoduleState.submoduleCommits, "Unknown submodule: " ~ submoduleName);
		auto submodule = getSubmodule(submoduleName);
		auto head = submoduleState.submoduleCommits[submoduleName];
		auto result = submodule.getRevert(head, branch, mode);
		submoduleState.submoduleCommits[submoduleName] = result;
	}

	/// Returns the commit hash for the given pull request # (base and tip).
	/// The result can then be used with addMerge/removeMerge.
	string[2] getPull(string submoduleName, int pullNumber)
	{
		auto tip = getSubmodule(submoduleName).getPullTip(pullNumber);
		auto pull = needGitHub().query("https://api.github.com/repos/%s/%s/pulls/%d"
			.format("dlang", submoduleName, pullNumber)).data.parseJSON;
		auto base = pull["base"]["sha"].str;
		return [base, tip];
	}

	/// Returns the commit hash for the given branch (optionally GitHub fork).
	/// The result can then be used with addMerge/removeMerge.
	string[2] getBranch(string submoduleName, string user, string base, string tip)
	{
		return getSubmodule(submoduleName).getBranch(user, base, tip);
	}

	// ****************************** Building *******************************

	private SubmoduleState submoduleState;
	private bool incrementalBuild;

	/// Returns the name of the cache engine being used.
	@property string cacheEngineName()
	{
		if (incrementalBuild)
			return "none";
		else
			return config.local.cache;
	}

	private string getComponentCommit(string componentName)
	{
		auto submoduleName = getComponent(componentName).submoduleName;
		auto commit = submoduleState.submoduleCommits.get(submoduleName, null);
		enforce(commit, "Unknown commit to build for component %s (submodule %s)"
			.format(componentName, submoduleName));
		return commit;
	}

	static const string[] defaultComponents = ["dmd", "druntime", "phobos-includes", "phobos", "rdmd"]; /// Components enabled by default.
	static const string[] additionalComponents = ["tools", "website", "extras", "curl", "dub"]; /// Components disabled by default.
	static const string[] allComponents = defaultComponents ~ additionalComponents; /// All components that may be enabled and built.

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
			getComponent(componentName).needSource(true);
	}

	/// Rerun build without cleaning up any files.
	void rebuild()
	{
		build(SubmoduleState(null), true);
	}

	/// Run all tests for the current checkout (like rebuild).
	void test(bool incremental = true)
	{
		auto componentNames = config.build.components.getEnabledComponentNames();
		log("Testing components %-(%s, %)".format(componentNames));

		if (incremental)
		{
			this.components = null;
			this.submoduleState = SubmoduleState(null);
			this.incrementalBuild = true;
		}

		foreach (componentName; componentNames)
			getComponent(componentName).test();
	}

	/// Check if the given build is cached.
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

	/// Returns the `isCached` state for all commits in the history of the given ref.
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
			import ae.utils.meta : I;
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

	/// Pull in a built DMD as configured.
	/// Note that this function invalidates the current repository state.
	void needDMD(ref Environment env, string dmdVer)
	{
		tempError++; scope(success) tempError--;

		auto numericVersion(string dmdVer)
		{
			assert(dmdVer.startsWith("v"));
			return dmdVer[1 .. $].splitter('.').map!(to!int).array;
		}

		// Nudge indicated version if we know it won't be usable on the current system.
		version (OSX)
		{
			enum minimalWithoutEnumerateTLV = "v2.088.0";
			if (numericVersion(dmdVer) < numericVersion(minimalWithoutEnumerateTLV) && !haveEnumerateTLV())
			{
				log("DMD " ~ dmdVer ~ " not usable on this system - using " ~ minimalWithoutEnumerateTLV ~ " instead.");
				dmdVer = minimalWithoutEnumerateTLV;
			}
		}

		// User setting overrides autodetection
		if (config.build.components.dmd.bootstrap.ver)
		{
			log("Using user-specified bootstrap DMD version " ~
				config.build.components.dmd.bootstrap.ver ~
				" instead of auto-detected version " ~ dmdVer ~ ".");
			dmdVer = config.build.components.dmd.bootstrap.ver;
		}

		if (config.build.components.dmd.bootstrap.fromSource)
		{
			log("Bootstrapping DMD " ~ dmdVer);

			auto bootstrapBuildConfig = config.build.components.dmd.bootstrap.build;

			// Back up and clear component state
			enum backupTemplate = q{
				auto VARBackup = this.VAR;
				this.VAR = typeof(VAR).init;
				scope(exit) this.VAR = VARBackup;
			};
			mixin(backupTemplate.replace(q{VAR}, q{components}));
			mixin(backupTemplate.replace(q{VAR}, q{config}));
			mixin(backupTemplate.replace(q{VAR}, q{submoduleState}));

			config.local = configBackup.local;
			if (bootstrapBuildConfig)
				config.build = *bootstrapBuildConfig;

			// Disable building rdmd in the bootstrap compiler by default
			if ("rdmd" !in config.build.components.enable)
				config.build.components.enable["rdmd"] = false;

			build(parseSpec(dmdVer));

			log("Built bootstrap DMD " ~ dmdVer ~ " successfully.");

			auto bootstrapDir = buildPath(config.local.workDir, "bootstrap");
			if (bootstrapDir.exists)
				bootstrapDir.removeRecurse();
			ensurePathExists(bootstrapDir);
			rename(buildDir, bootstrapDir);

			env.deps.hostDC = buildPath(bootstrapDir, "bin", "dmd" ~ binExt);
		}
		else
		{
			import std.ascii;
			log("Preparing DMD " ~ dmdVer);
			enforce(dmdVer.startsWith("v"), "Invalid DMD version spec for binary bootstrap. Did you forget to " ~
				((dmdVer.length && dmdVer[0].isDigit && dmdVer.contains('.')) ? "add a leading 'v'" : "enable fromSource") ~ "?");
			needInstaller();
			auto dmdInstaller = new DMDInstaller(dmdVer[1..$]);
			dmdInstaller.requireLocal(false);
			env.deps.hostDC = dmdInstaller.exePath("dmd").absolutePath();
		}

		log("hostDC=" ~ env.deps.hostDC);
	}

	protected void needKindleGen(ref Environment env)
	{
		needInstaller();
		kindleGenInstaller.requireLocal(false);
		env.vars["PATH"] = kindleGenInstaller.directory ~ pathSeparator ~ env.vars["PATH"];
	}

	version (Windows)
	protected void needMSYS(ref Environment env)
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
	protected string needExtras()
	{
		import ae.utils.meta : I, singleton;

		static class DExtrasInstaller : Installer
		{
			protected @property override string name() { return "dmd-localextras"; }
			string url = "http://semitwist.com/download/app/dmd-localextras.7z";

			protected override void installImpl(string target)
			{
				url
					.I!save()
					.I!unpackTo(target);
			}

			static this()
			{
				urlDigests["http://semitwist.com/download/app/dmd-localextras.7z"] = "ef367c2d25d4f19f45ade56ab6991c726b07d3d9";
			}
		}

		alias extrasInstaller = singleton!DExtrasInstaller;

		needInstaller();
		extrasInstaller.requireLocal(false);
		return extrasInstaller.directory;
	}

	/// Get libcurl for Windows (DLL and import libraries)
	version (Windows)
	protected string needCurl()
	{
		import ae.utils.meta : I, singleton;

		static class DCurlInstaller : Installer
		{
			protected @property override string name() { return "libcurl-" ~ curlVersion; }
			string curlVersion = "7.47.1";
			@property string url() { return "http://downloads.dlang.org/other/libcurl-" ~ curlVersion ~ "-WinSSL-zlib-x86-x64.zip"; }

			protected override void installImpl(string target)
			{
				url
					.I!save()
					.I!unpackTo(target);
			}

			static this()
			{
				urlDigests["http://downloads.dlang.org/other/libcurl-7.47.1-WinSSL-zlib-x86-x64.zip"] = "4b8a7bb237efab25a96588093ae51994c821e097";
			}
		}

		alias curlInstaller = singleton!DCurlInstaller;

		needInstaller();
		curlInstaller.requireLocal(false);
		return curlInstaller.directory;
	}

	version (Windows)
	protected void needDMC(ref Environment env, string ver = null)
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
	protected static string msvcModelStr(string model, string str32, string str64)
	{
		switch (model)
		{
			case "32":
				throw new Exception("Shouldn't need VC for 32-bit builds");
			case "64":
				return str64;
			case "32mscoff":
				return str32;
			default:
				throw new Exception("Unknown model: " ~ model);
		}
	}

	version (Windows)
	protected static string msvcModelDir(string model, string dir64 = "x86_amd64")
	{
		return msvcModelStr(model, null, dir64);
	}

	version (Windows)
	protected void needVC(ref Environment env, string model)
	{
		tempError++; scope(success) tempError--;

		auto vs = getVSInstaller();

		// At minimum, we want the C compiler (cl.exe) and linker (link.exe).
		vs["vc_compilercore86"].requireLocal(false); // Contains both x86 and x86_amd64 cl.exe
		vs["vc_compilercore86res"].requireLocal(false); // Contains clui.dll needed by cl.exe

		// Include files. Needed when using VS to build either DMD or Druntime.
		vs["vc_librarycore86"].requireLocal(false); // Contains include files, e.g. errno.h needed by Druntime

		// C runtime. Needed for all programs built with VC.
		vs[msvcModelStr(model, "vc_libraryDesktop_x86", "vc_libraryDesktop_x64")].requireLocal(false); // libcmt.lib

		// XP-compatible import libraries.
		vs["win_xpsupport"].requireLocal(false); // shell32.lib

		// MSBuild, for the useVC option
		if (config.build.components.dmd.useVC)
			vs["Msi_BuildTools_MSBuild_x86"].requireLocal(false); // msbuild.exe

		env.deps.vsDir  = vs.directory.buildPath("Program Files (x86)", "Microsoft Visual Studio 12.0").absolutePath();
		env.deps.sdkDir = vs.directory.buildPath("Program Files", "Microsoft SDKs", "Windows", "v7.1A").absolutePath();

		env.vars["PATH"] ~= pathSeparator ~ vs.modelBinPaths(msvcModelDir(model)).map!(path => vs.directory.buildPath(path).absolutePath()).join(pathSeparator);
		env.vars["VisualStudioVersion"] = "12"; // Work-around for problem fixed in dmd 38da6c2258c0ff073b0e86e0a1f6ba190f061e5e
		env.vars["VSINSTALLDIR"] = env.deps.vsDir ~ dirSeparator; // ditto
		env.vars["VCINSTALLDIR"] = env.deps.vsDir.buildPath("VC") ~ dirSeparator;
		env.vars["INCLUDE"] = env.deps.vsDir.buildPath("VC", "include") ~ ";" ~ env.deps.sdkDir.buildPath("Include");
		env.vars["LIB"] = env.deps.vsDir.buildPath("VC", "lib", msvcModelDir(model, "amd64")) ~ ";" ~ env.deps.sdkDir.buildPath("Lib", msvcModelDir(model, "x64"));
		env.vars["WindowsSdkDir"] = env.deps.sdkDir ~ dirSeparator;
		env.vars["Platform"] = "x64";
		env.vars["LINKCMD64"] = env.deps.vsDir.buildPath("VC", "bin", msvcModelDir(model), "link.exe"); // Used by dmd
		env.vars["MSVC_CC"] = env.deps.vsDir.buildPath("VC", "bin", msvcModelDir(model), "cl.exe"); // For the msvc-dmc wrapper
		env.vars["MSVC_AR"] = env.deps.vsDir.buildPath("VC", "bin", msvcModelDir(model), "lib.exe"); // For the msvc-lib wrapper
		env.vars["CL"] = "-D_USING_V110_SDK71_"; // Work around __userHeader macro redifinition VS bug
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

	version (OSX) protected
	{
		bool needWorkingCCChecked;
		void needWorkingCC()
		{
			if (!needWorkingCCChecked)
			{
				log("Checking for a working C compiler...");
				auto dir = buildPath(config.local.workDir, "temp", "cc-test");
				if (dir.exists) dir.rmdirRecurse();
				dir.mkdirRecurse();
				scope(success) rmdirRecurse(dir);

				write(dir.buildPath("test.c"), "int main() { return 0; }");
				auto status = spawnProcess(["cc", "test.c"], baseEnvironment.vars, std.process.Config.newEnv, dir).wait();
				enforce(status == 0, "Failed to compile a simple C program - no C compiler.");

				log("> OK");
				needWorkingCCChecked = true;
			}
		};

		bool haveEnumerateTLVChecked, haveEnumerateTLVValue;
		bool haveEnumerateTLV()
		{
			if (!haveEnumerateTLVChecked)
			{
				needWorkingCC();

				log("Checking for dyld_enumerate_tlv_storage...");
				auto dir = buildPath(config.local.workDir, "temp", "cc-tlv-test");
				if (dir.exists) dir.rmdirRecurse();
				dir.mkdirRecurse();
				scope(success) rmdirRecurse(dir);

				write(dir.buildPath("test.c"), "extern void dyld_enumerate_tlv_storage(void* handler); int main() { dyld_enumerate_tlv_storage(0); return 0; }");
				if (spawnProcess(["cc", "test.c"], baseEnvironment.vars, std.process.Config.newEnv, dir).wait() == 0)
				{
					log("> Present (probably 10.14 or older)");
					haveEnumerateTLVValue = true;
				}
				else
				{
					log("> Absent (probably 10.15 or newer)");
					haveEnumerateTLVValue = false;
				}
				haveEnumerateTLVChecked = true;
			}
			return haveEnumerateTLVValue;
		}
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
			newPaths ~= [sysDir, winDir];

			newPaths ~= gitInstaller.exePath("git").absolutePath().dirName; // For git-describe and such
		}
		else
		{
			// Needed for coreutils, make, gcc, git etc.
			newPaths = ["/bin", "/usr/bin", "/usr/local/bin"];

			version (linux)
			{
				// GCC wrappers
				ensureDirExists(binDir);
				newPaths = binDir ~ newPaths;
			}
		}

		env.vars["PATH"] = newPaths.join(pathSeparator);

		ensureDirExists(tmpDir);
		env.vars["TMPDIR"] = env.vars["TEMP"] = env.vars["TMP"] = tmpDir;

		version (Windows)
		{
			env.vars["SystemDrive"] = winDir.driveName;
			env.vars["SystemRoot"] = winDir;
		}

		ensureDirExists(homeDir);
		env.vars["HOME"] = homeDir;

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

	/// Unbuildable versions are saved in the cache as a single empty file with this name.
	enum unbuildableMarker = "unbuildable";

	private DCache cacheEngine; /// Caches builds.

	DCache needCacheEngine()
	{
		if (!cacheEngine)
		{
			if (cacheEngineName == "git")
				needGit();
			cacheEngine = createCache(cacheEngineName, cacheEngineDir(cacheEngineName), this);
		}
		return cacheEngine;
	} /// ditto

	protected void cp(string src, string dst)
	{
		needCacheEngine().cp(src, dst);
	}

	private string[] getComponentKeyOrder(string componentName)
	{
		auto submodule = getComponent(componentName).submodule;
		return submodule
			.git.query("log", "--pretty=format:%H", "--all", "--topo-order")
			.splitLines()
			.map!(commit => componentName ~ "-" ~ commit ~ "-")
			.array
		;
	}

	protected string componentNameFromKey(string key)
	{
		auto parts = key.split("-");
		return parts[0..$-2].join("-");
	}

	protected string[][] getKeyOrder(string key)
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

	protected bool shouldPurge(string key)
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

	/// Gets the D merge log (newest first).
	struct LogEntry
	{
		string hash;      ///
		string[] message; ///
		SysTime time;     ///
	}

	/// ditto
	LogEntry[] getLog(string refName = "refs/remotes/origin/master")
	{
		auto history = getMetaRepo().git.getHistory();
		LogEntry[] logs;
		auto master = history.commits[history.refs[refName]];
		for (auto c = master; c; c = c.parents.length ? c.parents[0] : null)
		{
			auto time = SysTime(c.time.unixTimeToStdTime);
			logs ~= LogEntry(c.oid.toString(), c.message, time);
		}
		return logs;
	}

	// ***************************** Integration *****************************

	/// Override to add logging.
	void log(string line)
	{
	}

	/// Bootstrap description resolution.
	/// See DMD.Config.Bootstrap.spec.
	/// This is essentially a hack to allow the entire
	/// Config structure to be parsed from an .ini file.
	SubmoduleState parseSpec(string spec)
	{
		auto rev = getMetaRepo().getRef("refs/tags/" ~ spec);
		log("Resolved " ~ spec ~ " to " ~ rev);
		return begin(rev);
	}

	/// Override this method with one which returns a command,
	/// which will invoke the unmergeRebaseEdit function below,
	/// passing to it any additional parameters.
	/// Note: Currently unused. Was previously used
	/// for unmerging things using interactive rebase.
	deprecated abstract string getCallbackCommand();

	deprecated void callback(string[] args) { assert(false); }
}
