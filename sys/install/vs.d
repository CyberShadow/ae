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
 *   Vladimir Panteleev <vladimir@thecybershadow.net>
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

class VisualStudioInstaller : Installer
{
	this(int year, string edition, int webInstaller, string versionName)
	{
		this.year = year;
		this.edition = edition;
		this.webInstaller = webInstaller;
		this.versionName = versionName;
	}

	void requirePackages(string[] packages)
	{
		foreach (p; packages)
			if (!this.packages.canFind(p))
				this.packages ~= p;
	}

	@property override string name() { return "Visual Studio %d %s (%-(%s, %))".format(year, edition, packages); }
	@property override string subdirectory() { return "vs%s-%s".format(year, edition.toLower()); }

	@property override string[] binPaths() { return modelBinPaths(null); }

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

	@property override bool installedLocally()
	{
		if (!directory.exists)
			return false;

		auto installedPackages =
			packageFile
			.prependPath(directory)
			.readText()
			.jsonParse!(string[])
			.sort().uniq().array();
		auto wantedPackages = packages.sort().uniq().array();
		if (installedPackages != wantedPackages)
		{
			log("Requested package set differs from previous install - deleting " ~ directory);
			directory.forceDelete(Yes.recursive);
			return false;
		}

		return true;
	}

private:
	enum packageFile = "packages.json";

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

protected:
	int year, webInstaller;
	string edition, versionName;
	string[] packages;

	XmlNode getManifest()
	{
		return webInstaller
			.I!msdl()
			.I!unpack()
			.buildPath("0")
			.readText()
			.xmlParse()
			["BurnManifest"];
	}

	override void installImpl(string target)
	{
		windowsOnly();

		assert(packages.length, "No packages specified");
		auto seenPackage = new bool[packages.length];

		auto manifest = getManifest();

		string[] payloadIDs;
		foreach (node; manifest["Chain"].findChildren("MsiPackage"))
			if (packages.canFind(node.attributes["Id"]))
			{
				foreach (payload; node.findChildren("PayloadRef"))
					payloadIDs ~= payload.attributes["Id"];
				seenPackage[packages.countUntil(node.attributes["Id"])] = true;
			}

		enforce(seenPackage.all, "Unknown package(s): %s".format(packages.length.iota.filter!(i => !seenPackage[i]).map!(i => packages[i])));

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

		std.file.write(buildPath(target, packageFile), packages.toJson());
	}

	/// Decompile all MSI files.
	/// Useful for finding the name of the package which contains the file you want.
	public void getAllMSIs()
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

	static this()
	{
		urlDigests["http://download.microsoft.com/download/7/2/E/72E0F986-D247-4289-B9DC-C4FB07374894/wdexpress_full.exe"] = "8a4c07fa11b20b85126988e7eaf792924b319ae0";
		urlDigests["http://download.microsoft.com/download/7/1/B/71BA74D8-B9A0-4E6C-9159-A8335D54437E/vs_community.exe"  ] = "51e5f04fc4648bde3c8276703bf7251216e4ceaf";
	}
}

deprecated alias vs2013 = vs2013express;

alias vs2013express   = singleton!(VisualStudioInstaller, 2013, "Express"  , 320697, "12.0");
alias vs2013community = singleton!(VisualStudioInstaller, 2013, "Community", 517284, "12.0");
