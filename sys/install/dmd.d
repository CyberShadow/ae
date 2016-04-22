/**
 * DMD installer
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

module ae.sys.install.dmd;

import std.array;
import std.conv;
import std.exception;
import std.file;
import std.string;
import std.path;

import ae.sys.archive;
import ae.sys.file;
import ae.utils.meta : singleton, I;

public import ae.sys.install.common;

class DMDInstaller : Installer
{
	string dmdVersion;

	this(string v = currentVersion)
	{
		dmdVersion = v;
	}

	// Note: we can't get the dot-release version. Assume ".0".
	enum currentVersion = text(__VERSION__)[0] ~ "." ~ text(__VERSION__)[1..$] ~ ".0";

	version (Windows)
		enum modelString = "";
	else
	version (OSX)
		enum modelString = "";
	else
	version (D_LP64)
		enum modelString = "64";
	else
		enum modelString = "32";

	version (Windows)
	{
		enum platformDir = "windows";
		enum platformSuffix = "windows";
	}
	else version (linux)
	{
		enum platformDir = "linux";
		enum platformSuffix = "linux";
	}
	else	version (FreeBSD)
	{
		enum platformDir = "freebsd";
		enum platformSuffix = "freebsd-"~modelString;
	}
	else	version (OSX)
	{
		enum platformDir = "osx";
		enum platformSuffix = "osx";
	}
	else
		static assert(false, "Unknown platform");

	@property override string name() { return "DigitalMars D compiler v" ~ dmdVersion; }
	@property override string subdirectory() { return "dmd-" ~ dmdVersion; }

	@property override string[] requiredExecutables() { return ["dmd"]; }
	@property override string[] binPaths() { return ["dmd2/" ~ platformDir ~ "/bin" ~ modelString]; }

	@property string url() { return "http://downloads.dlang.org/releases/%s.x/%s/dmd.%s.%s.zip".format(
		dmdVersion[0], dmdVersion, dmdVersion, platformSuffix); }

	override void installImpl(string target)
	{
		url
			.I!save()
			.I!verify(getDigest(url))
			.I!unpackTo(target);
	}

	static string getDigest(string url)
	{
		switch (url)
		{
			case "downloads.dlang.org/releases/2.x/2.065.0/dmd.2.065.0.windows.zip"   : return "d79b92cf4c7ccb01ebbb5f7ded8e583081391781";
			case "downloads.dlang.org/releases/2.x/2.065.0/dmd.2.065.0.linux.zip"     : return "53c28075672aca183d6247a80a163e10084c9add";
			case "downloads.dlang.org/releases/2.x/2.065.0/dmd.2.065.0.freebsd-32.zip": return "1df3915ea9ced62da504ec50de98148a1b22e4dc";
			case "downloads.dlang.org/releases/2.x/2.065.0/dmd.2.065.0.freebsd-64.zip": return "bc7a41eb0cec3e766954010a873e8c414b210f40";
			case "downloads.dlang.org/releases/2.x/2.065.0/dmd.2.065.0.osx.zip"       : return "bf0f03a14b52ee964e8732200dd4d21064260a39";
			case "downloads.dlang.org/releases/2.x/2.066.0/dmd.2.066.0.windows.zip"   : return "987b9a505c4598b204bee09f646eab571c6aaf00";
			case "downloads.dlang.org/releases/2.x/2.066.0/dmd.2.066.0.linux.zip"     : return "c63d4cb4c8ce704689249d5a81fd4d97d9c0084e";
			case "downloads.dlang.org/releases/2.x/2.066.0/dmd.2.066.0.freebsd-32.zip": return "7d0d4e4e499a76ce1717f48ab7d781dd48a60260";
			case "downloads.dlang.org/releases/2.x/2.066.0/dmd.2.066.0.freebsd-64.zip": return "e835228d7ad486623d2f491576ab2f0d0e9973a9";
			case "downloads.dlang.org/releases/2.x/2.066.0/dmd.2.066.0.osx.zip"       : return "063f984f7d23f24bc9096227431c38ed5f52dbe5";
			case "downloads.dlang.org/releases/2.x/2.066.1/dmd.2.066.1.windows.zip"   : return "1e1c73f67e0a2c6de92d4644036692e07cab1346";
			case "downloads.dlang.org/releases/2.x/2.066.1/dmd.2.066.1.linux.zip"     : return "65debddc874c1be5ce99ec24fa6ed422eb52288e";
			case "downloads.dlang.org/releases/2.x/2.066.1/dmd.2.066.1.freebsd-32.zip": return "de00c316b6500e47fe36de1b9790b448b773278a";
			case "downloads.dlang.org/releases/2.x/2.066.1/dmd.2.066.1.freebsd-64.zip": return "4ab95f1e7af851808855fe0c89b5a3ac368f0640";
			case "downloads.dlang.org/releases/2.x/2.066.1/dmd.2.066.1.osx.zip"       : return "7e97fcf5f0d7b337e4c2bbfb5b9ad1438566c95d";
			case "downloads.dlang.org/releases/2.x/2.067.0/dmd.2.067.0.windows.zip"   : return "2b7e9cf49dd80d59f68062f8d7e38d18c23a61e4";
			case "downloads.dlang.org/releases/2.x/2.067.0/dmd.2.067.0.linux.zip"     : return "11f6936121e49dabebd2ddcb84b06b8ffb999a98";
			case "downloads.dlang.org/releases/2.x/2.067.0/dmd.2.067.0.freebsd-32.zip": return "189ed0d94b4440464ed9be2adc6ec901b84df204";
			case "downloads.dlang.org/releases/2.x/2.067.0/dmd.2.067.0.freebsd-64.zip": return "ba572366e2720217a12862d91c171be6a6cabc9b";
			case "downloads.dlang.org/releases/2.x/2.067.0/dmd.2.067.0.osx.zip"       : return "41b6118cc1f9b7d2c671e4e3498d0b0f7e38ca8c";
			case "downloads.dlang.org/releases/2.x/2.067.1/dmd.2.067.1.windows.zip"   : return "8ea799291320f61fbfc0618351af6adf10107334";
			case "downloads.dlang.org/releases/2.x/2.067.1/dmd.2.067.1.linux.zip"     : return "2c158da0ac406877b8934487518aded785ef3439";
			case "downloads.dlang.org/releases/2.x/2.067.1/dmd.2.067.1.freebsd-32.zip": return "ea850992ad533b6709fe8bca8cf5d19fd6ddf698";
			case "downloads.dlang.org/releases/2.x/2.067.1/dmd.2.067.1.freebsd-64.zip": return "68bde60035813c07958abb248accce48026ec081";
			case "downloads.dlang.org/releases/2.x/2.067.1/dmd.2.067.1.osx.zip"       : return "bb2beb054e6feb67288a912ab62acbc685132091";
			case "downloads.dlang.org/releases/2.x/2.068.0/dmd.2.068.0.windows.zip"   : return "7f3ddcdc19df81780a255652d0559bbe1780572e";
			case "downloads.dlang.org/releases/2.x/2.068.0/dmd.2.068.0.linux.zip"     : return "dede88e477919a825713c95dede44690aa5fa46d";
			case "downloads.dlang.org/releases/2.x/2.068.0/dmd.2.068.0.freebsd-32.zip": return "6daba7d8683df92c5a120ba8d61d7300c251d98a";
			case "downloads.dlang.org/releases/2.x/2.068.0/dmd.2.068.0.freebsd-64.zip": return "ccb985ef933f99fd8620c197ecbbfc92541c4572";
			case "downloads.dlang.org/releases/2.x/2.068.0/dmd.2.068.0.osx.zip"       : return "2831b535909bd82ca2fe711fda4c35c34198ebcd";
			case "downloads.dlang.org/releases/2.x/2.068.1/dmd.2.068.1.windows.zip"   : return "6ad214fab50a6d679bb0e847a6efbb6c95635ac5";
			case "downloads.dlang.org/releases/2.x/2.068.1/dmd.2.068.1.linux.zip"     : return "8b5237fd80c635859da36a673a6c52b357fdf26f";
			case "downloads.dlang.org/releases/2.x/2.068.1/dmd.2.068.1.freebsd-32.zip": return "6387f3b70713a953b68c02b1b442098bd5eec354";
			case "downloads.dlang.org/releases/2.x/2.068.1/dmd.2.068.1.freebsd-64.zip": return "ba65233459f97a2a2c2b4c02b1308e61350e7426";
			case "downloads.dlang.org/releases/2.x/2.068.1/dmd.2.068.1.osx.zip"       : return "2917fd6663f928e4523d952df29af1d86dddd9d0";
			case "downloads.dlang.org/releases/2.x/2.068.2/dmd.2.068.2.windows.zip"   : return "747b5e805276a706d15f0d36c62be88830eab77a";
			case "downloads.dlang.org/releases/2.x/2.068.2/dmd.2.068.2.linux.zip"     : return "814640bb81665695e807d8b6e61acec2a0630bb8";
			case "downloads.dlang.org/releases/2.x/2.068.2/dmd.2.068.2.freebsd-32.zip": return "e4a2eaf083bfb38f2c3d5450afd5af643c8bd39b";
			case "downloads.dlang.org/releases/2.x/2.068.2/dmd.2.068.2.freebsd-64.zip": return "f561f6970924b4ace870e45b2300eceba21a2ffc";
			case "downloads.dlang.org/releases/2.x/2.068.2/dmd.2.068.2.osx.zip"       : return "db7b9be84ee2413b82c26db415df099422c8c867";
			case "downloads.dlang.org/releases/2.x/2.069.0/dmd.2.069.0.windows.zip"   : return "4fa12a1ee224b0400bd6a3c969f461019848dd8c";
			case "downloads.dlang.org/releases/2.x/2.069.0/dmd.2.069.0.linux.zip"     : return "2368cd7c98bdd7aa147cfee790223190eea9a2fb";
			case "downloads.dlang.org/releases/2.x/2.069.0/dmd.2.069.0.freebsd-32.zip": return "b05f367b2169fdc07fbdfe0a7a305e2c3b702832";
			case "downloads.dlang.org/releases/2.x/2.069.0/dmd.2.069.0.freebsd-64.zip": return "72c249e35cd2fb55d5f3f79f6211e1c798336250";
			case "downloads.dlang.org/releases/2.x/2.069.0/dmd.2.069.0.osx.zip"       : return "f4306fe519d6752e1879477cae6b0637a0bafca2";
			case "downloads.dlang.org/releases/2.x/2.069.1/dmd.2.069.1.windows.zip"   : return "0e4630114b17971608cdf961eae6680d4b1b0b9a";
			case "downloads.dlang.org/releases/2.x/2.069.1/dmd.2.069.1.linux.zip"     : return "982f5d2063d6f9cf242c4c8e38b001a4c0b5d4db";
			case "downloads.dlang.org/releases/2.x/2.069.1/dmd.2.069.1.freebsd-32.zip": return "c3268a4aefe7406c5b31ed56065d56e7401fb32d";
			case "downloads.dlang.org/releases/2.x/2.069.1/dmd.2.069.1.freebsd-64.zip": return "7fd2c1dbadcf123665251aee3a24d3741989da12";
			case "downloads.dlang.org/releases/2.x/2.069.1/dmd.2.069.1.osx.zip"       : return "244e0b374c17e13d81e596174467a8166c30ee06";
			case "downloads.dlang.org/releases/2.x/2.069.2/dmd.2.069.2.windows.zip"   : return "dd95c861bad2ce3bbd0d6882b92d75442550e28c";
			case "downloads.dlang.org/releases/2.x/2.069.2/dmd.2.069.2.linux.zip"     : return "84e7f58ead856c3ca06b885ac04a4f466154a0d0";
			case "downloads.dlang.org/releases/2.x/2.069.2/dmd.2.069.2.freebsd-32.zip": return "affbca67d6a57d4a5f18d6c119a5cf47f72f9f81";
			case "downloads.dlang.org/releases/2.x/2.069.2/dmd.2.069.2.freebsd-64.zip": return "caaefacc577e4d5c845a6566d6aeace4905b04a7";
			case "downloads.dlang.org/releases/2.x/2.069.2/dmd.2.069.2.osx.zip"       : return "222ffcfe59480c9883d7419d9a8a50754d4edcb6";
			case "downloads.dlang.org/releases/2.x/2.070.0/dmd.2.070.0.windows.zip"   : return "6365e2138840035b4c1df9bcffd6126124675dcb";
			case "downloads.dlang.org/releases/2.x/2.070.0/dmd.2.070.0.linux.zip"     : return "780101d03d089befad5d6975312deda2428b8ebf";
			case "downloads.dlang.org/releases/2.x/2.070.0/dmd.2.070.0.freebsd-32.zip": return "7622975da880a5006c1201d546af6173b7868727";
			case "downloads.dlang.org/releases/2.x/2.070.0/dmd.2.070.0.freebsd-64.zip": return "c38bd62116a3bd5daa2ffb515ccad7c1b816bfb1";
			case "downloads.dlang.org/releases/2.x/2.070.0/dmd.2.070.0.osx.zip"       : return "f1b712cbcf9753e6320c318093c96be37141ae0b";
			case "downloads.dlang.org/releases/2.x/2.070.1/dmd.2.070.1.windows.zip"   : return "26044ebcfade1051b53dd1c0e14744f661e1acd6";
			case "downloads.dlang.org/releases/2.x/2.070.1/dmd.2.070.1.linux.zip"     : return "7ce6142279fa8f0240d7f9b6f11fbc83bb7f10b4";
			case "downloads.dlang.org/releases/2.x/2.070.1/dmd.2.070.1.freebsd-32.zip": return "494c8c70d2565661f2414639af42325ef164602b";
			case "downloads.dlang.org/releases/2.x/2.070.1/dmd.2.070.1.freebsd-64.zip": return "b046449663d25179b0eb8eb703a9c0942529b9e8";
			case "downloads.dlang.org/releases/2.x/2.070.1/dmd.2.070.1.osx.zip"       : return "0b128a5f50167bc1943a7272eca0eda086cb87fd";
			case "downloads.dlang.org/releases/2.x/2.070.2/dmd.2.070.2.windows.zip"   : return "bfa0348c85174657ff2f7b0e8370b36d8e7f0a76";
			case "downloads.dlang.org/releases/2.x/2.070.2/dmd.2.070.2.linux.zip"     : return "4eeca47bc5a1bc1a38f91615218e05aa6dad7711";
			case "downloads.dlang.org/releases/2.x/2.070.2/dmd.2.070.2.freebsd-32.zip": return "bc60574bd392bb7b42ec10282e2fa33491ba9d56";
			case "downloads.dlang.org/releases/2.x/2.070.2/dmd.2.070.2.freebsd-64.zip": return "e0bd7c727d8bc5a3df3b5a70402dba24ce16c5ab";
			case "downloads.dlang.org/releases/2.x/2.070.2/dmd.2.070.2.osx.zip"       : return "578114de8ae5f89cfd9275f340be26494fa05a38";
			case "downloads.dlang.org/releases/2.x/2.071.0/dmd.2.071.0.windows.zip"   : return "ac8b4167b077f6d09701d5135a5f061788587310";
			case "downloads.dlang.org/releases/2.x/2.071.0/dmd.2.071.0.linux.zip"     : return "8ee9713be14ef2fe6024b3f93e24667d8a2a3d47";
			case "downloads.dlang.org/releases/2.x/2.071.0/dmd.2.071.0.freebsd-32.zip": return "6a9e57384c4afbe9888dcb44c9878320ab9be15e";
			case "downloads.dlang.org/releases/2.x/2.071.0/dmd.2.071.0.freebsd-64.zip": return "76cfe16e1c617aba360a5d855a85d42b7c9f7072";
			case "downloads.dlang.org/releases/2.x/2.071.0/dmd.2.071.0.osx.zip"       : return "ac8cf92505414858d5a9b91d03bae9eebc8c58c8";
			default: return null;
		}
	}
}

alias dmdInstaller = singleton!DMDInstaller;
