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
import std.datetime;
import std.exception;
import std.file;
import std.path;
import std.process;
import std.range;
import std.string;

import ae.sys.d.repo;
import ae.sys.file;
import ae.sys.git;
import ae.utils.digest;

version (Windows)
{
	import ae.sys.install.dmc;
	import ae.sys.install.vs;
}

import ae.sys.install.dmd;
import ae.sys.install.git;


/// Class which manages a D checkout and its dependencies.
class DManager
{
	// **************************** Configuration ****************************

	struct Config /// DManager configuration.
	{
		struct Build /// Build configuration
		{
			struct Components
			{
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

		/// Whether we persistently cache things.
		bool persistentCache;

	protected:

		struct Deps /// Configuration for software dependencies
		{
			string dmcDir;   /// Where dmc.zip is unpacked.
			string vsDir;    /// Where Visual Studio is installed
			string sdkDir;   /// Where the Windows SDK is installed
			string hostDC;   /// Host D compiler (for DDMD bootstrapping)
			string[] paths;  /// Additional PATH entries
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

	@property string cacheDir()
	{
		return buildPath(
			config.local.workDir,
			config.persistentCache ? "cache" : "temp-cache",
			"v%d".format(cacheVersion),
		);
	}

	// **************************** Repositories *****************************

	class DManagerRepository : ManagedRepository
	{
		override void log(string s) { return this.outer.log(s); }
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
			run(["git", "clone", "--recursive", url, target]);
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

			needHead(head);
			string[string] result;
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
			auto path = buildPath(metaRepo.git.path, name);
			enforce(path.exists, "Unknown submodule: " ~ name);
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
			string model = defaultModel; /// Target model ("32" or "64").

			string[] makeArgs; /// Additional make parameters,
			                   /// e.g. "-j8" or "HOST_CC=g++48"

			/// Returns a string representation of this build configuration
			/// usable for a cache directory name. Must reflect all fields.
			string toString() const
			{
				return model;
			}
		}
		CommonConfig commonConfig;

		/// Commit in the component's repo from which to build this component.
		@property string commit() { return getComponentCommit(name); }

		/// The components the source code of which this component depends on.
		@property abstract string[] sourceDeps();

		/// The components the built version of which this component depends on.
		@property abstract string[] buildDeps();

		string getBuildID()
		{
			return "%s-%s-%s".format(
				name,
				commit,
				getDigestString!MD5(chain(
					commonConfig.toString().only,
					configString.only,
					sourceDeps.map!(
						dependency => getComponent(dependency).commit
					),
					buildDeps.map!(
						dependency => getComponent(dependency).getBuildID()
					),
				).join("\0"))
			);
		}

		/// Prepare the source checkout for this component.
		/// Usually needed by other components.
		void needSource()
		{
			submodule.needHead(commit);
		}

		@property string sourceDir() { submodule.needRepo(); return submodule.git.path; }
		@property string cacheDir() { return buildPath(this.outer.cacheDir, getBuildID()); }

		void needBuild()
		{
			auto unbuildableMarker = buildPath(cacheDir, UNBUILDABLE_MARKER);

			if (unbuildableMarker.exists)
				throw new Exception(getBuildID() ~ " was cached as unbuildable");

			void buildTo(string target)
			{
				foreach (dependency; sourceDeps)
					getComponent(dependency).needSource();
				foreach (dependency; buildDeps)
					getComponent(dependency).needBuild();

				needSource();
				stageDir = target;

				scope (failure)
				{
					// Create "unbuildable" marker directly
					unbuildableMarker.ensurePathExists();
					unbuildableMarker.touch();
				}

				performBuild();
			}

			cached!buildTo(cacheDir);

			install();
		}

		/// Directory to which built files are copied to.
		/// This will then be atomically added to the cache.
		protected string stageDir;

		/// Perform build, and place resulting files to stageDir
		abstract void performBuild();

		/// Update the environment post-install, to allow
		/// building components that depend on this one.
		void updateEnv() {}

		/// Copy build results from cacheDir to buildDir
		void install()
		{
			foreach (de; dirEntries(cacheDir, SpanMode.shallow))
				cp(de.name, buildPath(buildDir, de.name.baseName));
		}

	protected final:
		// Utility declarations for component implementations

		version (Windows)
			enum defaultModel = "32";
		else
		version (D_LP64)
			enum defaultModel = "64";
		else
			enum defaultModel = "32";

		@property string modelSuffix() { return commonConfig.model == defaultModel ? "" : commonConfig.model; }
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
			return config.env.get("MAKE", environment.get("MAKE", "make"));
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

		void needCC()
		{
			version(Windows)
			{
				needDMC(); // We need DMC even for 64-bit builds (for DM make)
				if (commonConfig.model == "64")
					needVC();
			}
		}

		void run(string[] args, ref string[string] newEnv)
		{
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

		void cp(string src, string dst, bool silent = false)
		{
			if (!silent)
				log("Copy: " ~ src ~ " -> " ~ dst);

			ensurePathExists(dst);
			if (src.isDir)
			{
				if (!dst.exists)
					dst.mkdir();
				foreach (de; src.dirEntries(SpanMode.shallow))
					cp(de.name, dst.buildPath(de.name.baseName), true);
			}
			else
				copy(src, dst, PreserveAttributes.yes);
		}
	}

	final class DMD : Component
	{
		@property override string submoduleName() { return "dmd"; }
		@property override string[] sourceDeps() { return []; }
		@property override string[] buildDeps () { return []; }

		struct Config
		{
			/// Whether to build a debug DMD.
			/// Debug builds are faster to build,
			/// but run slower. Windows only.
			bool debugDMD = false;

			/// Returns a string representation of this build configuration
			/// usable for a cache directory name. Must reflect all fields.
			string toString() const
			{
				return debugDMD ? "debug" : null;
			}
		}

		Config buildConfig;

		@property override string configString() { return buildConfig.toString(); }

		override void performBuild()
		{
			needDMD(); // Required for bootstrapping.
			version (Windows)
				needDMC();

			{
				auto owd = pushd(buildPath(sourceDir, "src"));
				string[] targets = buildConfig.debugDMD ? [] : ["dmd"];
				run([make,
						"-f", makeFileName,
						"MODEL=" ~ commonConfig.model,
						"HOST_DC=" ~ config.deps.hostDC,
					] ~ commonConfig.makeArgs ~ targets,
				);
			}

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

			log("DMD OK!");
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
		@property override string[] sourceDeps() { return []; }
		@property override string[] buildDeps () { return []; }
		@property override string configString() { return null; }

		override void performBuild()
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
		@property override string[] sourceDeps() { return ["phobos"]; }
		@property override string[] buildDeps () { return ["dmd", "phobos-includes"]; }
		@property override string configString() { return null; }

		override void performBuild()
		{
			needCC();

			{
				auto owd = pushd(sourceDir);

				mkdirRecurse("import");
				mkdirRecurse("lib");

				setTimes(buildPath("src", "rt", "minit.obj"), Clock.currTime(), Clock.currTime());

				run([make, "-f", makeFileNameModel] ~ commonConfig.makeArgs ~ platformMakeVars);
			}

			cp(
				buildPath(sourceDir, "import"),
				buildPath(stageDir , "import"),
			);


			log("Druntime OK!");
		}
	}

	final class Phobos : Component
	{
		@property override string submoduleName() { return "phobos"; }
		@property override string[] sourceDeps() { return ["druntime"]; }
		@property override string[] buildDeps () { return ["dmd", "druntime"]; }
		@property override string configString() { return null; }

		override void performBuild()
		{
			needCC();

			string[] targets;

			{
				auto owd = pushd(sourceDir);
				version (Windows)
				{
					auto lib = "phobos%s.lib".format(modelSuffix);
					run([make, "-f", makeFileNameModel, lib] ~ commonConfig.makeArgs ~ platformMakeVars);
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
				cp(
					buildPath(sourceDir, lib),
					buildPath(stageDir , "lib", lib.baseName()),
				);

			log("Phobos OK!");
		}
	}

	final class RDMD : Component
	{
		@property override string submoduleName() { return "tools"; }
		@property override string[] sourceDeps() { return []; }
		@property override string[] buildDeps () { return ["dmd", "druntime", "phobos"]; }
		@property override string configString() { return null; }

		override void performBuild()
		{
			needCC();

			// Just build rdmd
			{
				auto owd = pushd(sourceDir);
				run(["dmd", "-m" ~ commonConfig.model, "rdmd"]);
			}
			cp(
				buildPath(sourceDir, "tools", "rdmd" ~ binExt),
				buildPath(stageDir , "bin", "rdmd" ~ binExt),
			);

			log("RDMD OK!");
		}
	}

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

	// **************************** Customization ****************************

	// TODO: Push all of this out into a separate class

	/// Fetch latest D history.
	void update()
	{
		getMetaRepo().update();
	}

	struct CustomizationState
	{
		string[string] submoduleCommits;
	}

	/// Begin customization, starting at the specified commit.
	CustomizationState begin(string commit)
	{
		return CustomizationState(getMetaRepo().getSubmoduleCommits(commit));
	}

	/// Applies a merge onto the given CustomizationState.
	void addMerge(ref CustomizationState customizationState, string submoduleName, string branch)
	{
		enforce(submoduleName in customizationState.submoduleCommits, "Unknown submodule: " ~ submoduleName);
		auto submodule = getSubmodule(submoduleName);
		auto head = customizationState.submoduleCommits[submoduleName];
		auto result = submodule.getMerge(head, branch);
		customizationState.submoduleCommits[submoduleName] = result;
	}

	/// Removes a merge from the given CustomizationState.
	void removeMerge(ref CustomizationState customizationState, string submoduleName, string branch)
	{
		enforce(submoduleName in customizationState.submoduleCommits, "Unknown submodule: " ~ submoduleName);
		auto submodule = getSubmodule(submoduleName);
		auto head = customizationState.submoduleCommits[submoduleName];
		auto result = submodule.getUnMerge(head, branch);
		customizationState.submoduleCommits[submoduleName] = result;
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

	CustomizationState customization;

	void build(CustomizationState customizationState, Config.Build buildConfig, string[] components)
	{
		this.customization = customizationState;
		this.config.build = buildConfig;
		prepareEnv();

		if (buildDir.exists)
			buildDir.removeRecurse();
		enforce(!buildDir.exists);

		if (!config.persistentCache) removeRecurse(cacheDir);
		scope(success) if (!config.persistentCache) removeRecurse(cacheDir);

		foreach (componentName; components)
			getComponent(componentName).needBuild();
	}

	string getComponentCommit(string componentName)
	{
		//  - (not implemented for now) get component-specific hash
		//  - get the hash for the submodule used by that component, corresponding to the commit in the meta-repo

		auto submoduleName = getComponent(componentName).submoduleName;
		auto commit = customization.submoduleCommits.get(submoduleName, null);
		enforce(commit, "Unknown commit to build for component %s (submodule %s)"
			.format(componentName, submoduleName));
		return commit;
	}

	// **************************** Dependencies *****************************

	private void needInstaller()
	{
		Installer.logger = &log;
		Installer.installationDirectory = dlDir;
	}

	void needDMD()
	{
		if (!config.deps.hostDC)
		{
			log("Preparing DMD");
			needInstaller();
			auto dmdInstaller = new DMDInstaller("2.066.1");
			dmdInstaller.requireLocal(false);
			config.deps.hostDC = dmdInstaller.exePath("dmd");
			log("hostDC=" ~ config.deps.hostDC);
		}
	}

	version (Windows)
	void needDMC()
	{
		if (!config.deps.dmcDir)
		{
			log("Preparing DigitalMars C++");
			needInstaller();

			dmcInstaller.requireLocal(false);
			config.deps.dmcDir = dmcInstaller.directory;

			auto binPath = buildPath(config.deps.dmcDir, `bin`).absolutePath();
			log("DMC=" ~ binPath);
			config.env["DMC"] = binPath;
			config.env["PATH"] ~= pathSeparator ~ binPath;
		}
	}

	version (Windows)
	void needVC()
	{
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

	/// Override to add logging.
	void log(string line)
	{
	}
}
