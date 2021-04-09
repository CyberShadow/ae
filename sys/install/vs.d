/**
 * Visual Studio components
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

module ae.sys.install.vs;

import std.algorithm;
import std.array;
import std.exception;
import std.file;
import std.path;
import std.process;
import std.range;
import std.string;

import ae.sys.archive;
import ae.sys.file;
import ae.sys.install.wix;
import ae.sys.net;
import ae.utils.json;
import ae.utils.meta : singleton, I;
import ae.utils.xmllite;

public import ae.sys.install.common;

/// Installs Visual Studio components.
class VisualStudioInstaller
{
	this(int year, string edition, int webInstaller, string versionName)
	{
		this.year = year;
		this.edition = edition;
		this.webInstaller = webInstaller;
		this.versionName = versionName;
	} ///

	/// Installs a Visual Studio component.
	class VisualStudioComponentInstaller : Installer
	{
		string packageName; ///

		@property override string name() { return "Visual Studio %d %s (%s)".format(year, edition, packageName); }
		@property override string subdirectory() { return "vs%s-%s".format(year, edition.toLower()); }

		@property override string[] binPaths() { return modelBinPaths(null); }

		@property private string packageMarkerFile() { return ".ae-sys-install-vs/" ~ packageName ~ ".installed"; }

		@property override bool installedLocally()
		{
			if (directory.buildPath("packages.json").exists)
			{
				log("Old-style installation detected, deleting...");
				rmdirRecurse(directory);
			}
			return directory.buildPath(packageMarkerFile).exists();
		}

	private:
		this() {}
		this(string packageName) { this.packageName = packageName; }

		static string msdl(int n)
		{
			return "http://go.microsoft.com/fwlink/?LinkId=%d&clcid=0x409"
				.format(n)
				.I!resolveRedirect()
				.I!save();
		}

		public static void decompileMSITo(string msi, string target)
		{
			wixInstaller.require();
			auto status = spawnProcess(["dark", msi, "-o", target]).wait();
			enforce(status == 0, "dark failed");
		}
		public static string setExtensionWXS(string fn) { return fn.setExtension(".wxs"); }
		alias decompileMSI = withTarget!(setExtensionWXS, cachedAction!(decompileMSITo, "Decompiling %s to %s..."));

		static void installWXS(string wxs, string target)
		{
			log("Installing %s to %s...".format(wxs, target));

			auto wxsDoc = wxs
				.readText()
				.xmlParse();

			string[string] disks;
			foreach (media; wxsDoc["Wix"]["Product"].findChildren("Media"))
				disks[media.attributes["Id"]] = media
					.attributes["Cabinet"]
					.absolutePath(wxs.dirName.absolutePath())
					.relativePath()
					.I!unpack();

			void processTag(XmlNode node, string dir)
			{
				switch (node.tag)
				{
					case "Directory":
					{
						auto id = node.attributes["Id"];
						switch (id)
						{
							case "TARGETDIR":
								dir = target;
								break;
							case "ProgramFilesFolder":
								dir = dir.buildPath("Program Files (x86)");
								break;
							case "SystemFolder":
								dir = dir.buildPath("windows", "system32");
								break;
							case "System64Folder":
								dir = dir.buildPath("windows", "system64");
								break;
							default:
								if ("Name" in node.attributes)
									dir = dir.buildPath(node.attributes["Name"]);
								break;
						}
						break;
					}
					case "File":
					{
						auto src = node.attributes["Source"];
						enforce(src.startsWith(`SourceDir\File\`));
						src = src[`SourceDir\File\`.length .. $];
						auto disk = disks[node.attributes["DiskId"]];
						src = disk.buildPath(src);
						auto dst = dir.buildPath(node.attributes["Name"]);
						if (dst.exists)
							break;
						//log(src ~ " -> " ~ dst);
						ensurePathExists(dst);
						src.hardLink(dst);
						break;
					}
					default:
						break;
				}

				foreach (child; node.children)
					processTag(child, dir);
			}

			processTag(wxsDoc, null);
		}

		XmlNode getManifest()
		{
			if (!manifestCache)
				manifestCache =
					webInstaller
					.I!msdl()
					.I!unpack()
					.buildPath("0")
					.readText()
					.xmlParse()
					["BurnManifest"];
			return manifestCache;
		}

		void installPackageImpl(string target)
		{
			windowsOnly();

			bool seenPackage;

			auto manifest = getManifest();

			string[] payloadIDs;
			foreach (node; manifest["Chain"].findChildren("MsiPackage"))
				if (node.attributes["Id"] == packageName)
				{
					foreach (payload; node.findChildren("PayloadRef"))
						payloadIDs ~= payload.attributes["Id"];
					seenPackage = true;
				}

			enforce(seenPackage, "Unknown package: " ~ packageName);

			string[][string] files;
			foreach (node; manifest.findChildren("Payload"))
				if (payloadIDs.canFind(node.attributes["Id"]))
				{
					auto path =
						node
						.attributes["FilePath"]
						.prependPath("%s-payloads".format(subdirectory));

					auto url = node.attributes["DownloadUrl"];
					urlDigests[url] = node.attributes["Hash"].toLower();
					files[path.extension.toLower()] ~= url.I!saveAs(path);
				}

			foreach (cab; files[".cab"])
				cab
				.I!unpack();

			foreach (msi; files[".msi"])
				msi
				.I!decompileMSI()
				.I!installWXS(target);

			auto marker = target.buildPath(packageMarkerFile);
			marker.ensurePathExists();
			marker.touch();
		}

		void getAllMSIs()
		{
			auto manifest = getManifest();

			string[] payloadIDs;
			foreach (node; manifest["Chain"].findChildren("MsiPackage"))
				foreach (payload; node.findChildren("PayloadRef"))
					payloadIDs ~= payload.attributes["Id"];

			foreach (node; manifest.findChildren("Payload"))
			{
				auto path =
					node
					.attributes["FilePath"]
					.prependPath("%s-payloads".format(subdirectory));

				if (path.extension.toLower() == ".msi")
				{
					auto url = node.attributes["DownloadUrl"];
					urlDigests[url] = node.attributes["Hash"].toLower();

					url
					.I!saveAs(path)
					.I!decompileMSI();
				}
			}
		}

	protected:
		override void atomicInstallImpl()
		{
			windowsOnly();
			auto target = directory ~ "." ~ packageName;
			void installPackageImplProxy(string target) { installPackageImpl(target); } // https://issues.dlang.org/show_bug.cgi?id=14580
			atomic!installPackageImplProxy(target);
			if (!directory.exists)
				directory.mkdir();
			target.atomicMoveInto(directory);
			assert(installedLocally);
		}

		static this()
		{
			urlDigests["http://download.microsoft.com/download/7/2/E/72E0F986-D247-4289-B9DC-C4FB07374894/wdexpress_full.exe"] = "8a4c07fa11b20b85126988e7eaf792924b319ae0";
			urlDigests["http://download.microsoft.com/download/7/1/B/71BA74D8-B9A0-4E6C-9159-A8335D54437E/vs_community.exe"  ] = "51e5f04fc4648bde3c8276703bf7251216e4ceaf";
		}
	}

	int year; /// Version/year.
	int webInstaller; /// Microsoft download number for the web installer.
	string edition; /// Edition variant (e.g. "Express").
	string versionName; /// Numeric version (e.g. "12.0").

	/// Returns the paths to the "bin" directory for the given model.
	/// Model is x86 (null), amd64, or x86_amd64
	string[] modelBinPaths(string model)
	{
		string[] result = [
			`windows\system32`,
			`Program Files (x86)\MSBuild\` ~ versionName ~ `\Bin`,
		];

		if (!model || model == "x86")
		{
			result ~= [
				`Program Files (x86)\Microsoft Visual Studio ` ~ versionName ~ `\VC\bin`,
			];
		}
		else
		if (model == "amd64")
		{
			result ~= [
				`Program Files (x86)\Microsoft Visual Studio ` ~ versionName ~ `\VC\bin\amd64`,
			];
		}
		else
		if (model == "x86_amd64")
		{
			// Binaries which target amd64 are under x86_amd64, but there is only one copy of DLLs
			// under bin. Therefore, add the bin directory too, after the x86_amd64 directory.
			result ~= [
				`Program Files (x86)\Microsoft Visual Studio ` ~ versionName ~ `\VC\bin\x86_amd64`,
				`Program Files (x86)\Microsoft Visual Studio ` ~ versionName ~ `\VC\bin`,
			];
		}

		return result;
	}

	/// Constructs a component installer for the given package.
	VisualStudioComponentInstaller opIndex(string name)
	{
		return new VisualStudioComponentInstaller(name);
	}

	/// Decompile all MSI files.
	/// Useful for finding the name of the package which contains the file you want.
	void getAllMSIs()
	{
		(new VisualStudioComponentInstaller()).getAllMSIs();
	}

	/// The full installation directory.
	@property string directory() { return (new VisualStudioComponentInstaller()).directory; }

private:
	XmlNode manifestCache;
}

deprecated alias vs2013 = vs2013express;

alias vs2013express   = singleton!(VisualStudioInstaller, 2013, "Express"  , 320697, "12.0"); /// Visual Studio 2013 Express Edition
alias vs2013community = singleton!(VisualStudioInstaller, 2013, "Community", 517284, "12.0"); /// Visual Studio 2013 Community Edition
