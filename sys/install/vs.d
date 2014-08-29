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
import ae.utils.meta.misc;
import ae.utils.xmllite;

public import ae.sys.install.common;

class VisualStudio : Installer
{
	this(int year, int webInstaller, string versionName)
	{
		this.year = year;
		this.webInstaller = webInstaller;
		this.versionName = versionName;
	}

	void requirePackages(string[] packages)
	{
		this.packages ~= packages;
	}

	@property override string name() { return "Visual Studio %d (%-(%s, %))".format(year, packages); }
	@property override string subdirectory() { return "vs%s".format(year); }

	@property override string[] binPaths()
	{
		return [
			`windows\system32`,
			`Program Files (x86)\Microsoft Visual Studio ` ~ versionName ~ `\VC\bin`,
		];
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
			directory.forceDelete(true);
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

	static void installWXS(string wxs, string root)
	{
		log("Installing %s to %s...".format(wxs, root));

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
							dir = root;
							break;
						case "ProgramFilesFolder":
							dir = dir.buildPath("Program Files (x86)");
							break;
						case "SystemFolder":
							dir = dir.buildPath("windows", "system32");
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
					log(src ~ " -> " ~ dst);
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
	string versionName;
	string[] packages;

	override void installImpl(string target)
	{
		windowsOnly();
		assert(packages.length, "No packages specified");

		auto manifest = webInstaller
			.I!msdl()
			.I!unpack()
			.buildPath("0")
			.readText()
			.xmlParse()
			["BurnManifest"];

		auto seenPackage = new bool[packages.length];

		string[] payloadIDs;
		foreach (node; manifest["Chain"].findChildren("MsiPackage"))
			if (packages.canFind(node.attributes["Id"]))
			{
				foreach (payload; node.findChildren("PayloadRef"))
					payloadIDs ~= payload.attributes["Id"];
				seenPackage[packages.countUntil(node.attributes["Id"])] = true;
			}

		enforce(seenPackage.all, "Unknown package(s): %s".format(packages.length.iota.filter!(i => seenPackage[i]).map!(i => packages[i])));

		string[][string] files;
		foreach (node; manifest.findChildren("Payload"))
			if (payloadIDs.canFind(node.attributes["Id"]))
			{
				auto path =
					node
					.attributes["FilePath"]
					.prependPath("vs%d-payloads".format(year));

				files[path.extension.toLower()] ~=
					node
					.attributes["DownloadUrl"]
					.I!saveAs(path);
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

	public void getAllMSIs()
	{
		auto manifest = webInstaller
			.I!msdl()
			.I!unpack()
			.buildPath("0")
			.readText()
			.xmlParse()
			["BurnManifest"];

		string[] payloadIDs;
		foreach (node; manifest["Chain"].findChildren("MsiPackage"))
				foreach (payload; node.findChildren("PayloadRef"))
					payloadIDs ~= payload.attributes["Id"];

		string[][string] files;
		foreach (node; manifest.findChildren("Payload"))
		{
			auto path =
				node
				.attributes["FilePath"]
				.prependPath("vs%d-payloads".format(year));

			if (path.extension.toLower() == ".msi")
				files[path.extension.toLower()] ~=
					node
					.attributes["DownloadUrl"]
					.I!saveAs(path)
					.I!decompileMSI();
		}
	}
}

alias vs2013 = singleton!(VisualStudio, 2013, 320697, "12.0");
