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
 *   Vladimir Panteleev <ae@cy.md>
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

/// Installs a binary release of DMD
class DMDInstaller : Installer
{
	string dmdVersion; /// Version to install

	this(string v = currentVersion)
	{
		dmdVersion = v;

		initDigests();
	} ///

	// Note: we can't get the dot-release version. Assume ".0".
	/// Version of DMD that this program was built with.
	/// Used as the default version to install.
	enum currentVersion = text(__VERSION__)[0] ~ "." ~ text(__VERSION__)[1..$] ~ ".0";

protected:
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
			.I!unpackTo(target);
	}

	static void initDigests()
	{
		static bool digestsInitialized;
		if (digestsInitialized) return;
		scope(success) digestsInitialized = true;

		urlDigests["http://downloads.dlang.org/releases/2.x/2.065.0/dmd.2.065.0.windows.zip"   ] = "d79b92cf4c7ccb01ebbb5f7ded8e583081391781";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.065.0/dmd.2.065.0.linux.zip"     ] = "53c28075672aca183d6247a80a163e10084c9add";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.065.0/dmd.2.065.0.freebsd-32.zip"] = "1df3915ea9ced62da504ec50de98148a1b22e4dc";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.065.0/dmd.2.065.0.freebsd-64.zip"] = "bc7a41eb0cec3e766954010a873e8c414b210f40";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.065.0/dmd.2.065.0.osx.zip"       ] = "bf0f03a14b52ee964e8732200dd4d21064260a39";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.066.0/dmd.2.066.0.windows.zip"   ] = "987b9a505c4598b204bee09f646eab571c6aaf00";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.066.0/dmd.2.066.0.linux.zip"     ] = "c63d4cb4c8ce704689249d5a81fd4d97d9c0084e";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.066.0/dmd.2.066.0.freebsd-32.zip"] = "7d0d4e4e499a76ce1717f48ab7d781dd48a60260";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.066.0/dmd.2.066.0.freebsd-64.zip"] = "e835228d7ad486623d2f491576ab2f0d0e9973a9";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.066.0/dmd.2.066.0.osx.zip"       ] = "063f984f7d23f24bc9096227431c38ed5f52dbe5";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.066.1/dmd.2.066.1.windows.zip"   ] = "1e1c73f67e0a2c6de92d4644036692e07cab1346";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.066.1/dmd.2.066.1.linux.zip"     ] = "65debddc874c1be5ce99ec24fa6ed422eb52288e";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.066.1/dmd.2.066.1.freebsd-32.zip"] = "de00c316b6500e47fe36de1b9790b448b773278a";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.066.1/dmd.2.066.1.freebsd-64.zip"] = "4ab95f1e7af851808855fe0c89b5a3ac368f0640";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.066.1/dmd.2.066.1.osx.zip"       ] = "7e97fcf5f0d7b337e4c2bbfb5b9ad1438566c95d";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.067.0/dmd.2.067.0.windows.zip"   ] = "2b7e9cf49dd80d59f68062f8d7e38d18c23a61e4";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.067.0/dmd.2.067.0.linux.zip"     ] = "11f6936121e49dabebd2ddcb84b06b8ffb999a98";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.067.0/dmd.2.067.0.freebsd-32.zip"] = "189ed0d94b4440464ed9be2adc6ec901b84df204";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.067.0/dmd.2.067.0.freebsd-64.zip"] = "ba572366e2720217a12862d91c171be6a6cabc9b";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.067.0/dmd.2.067.0.osx.zip"       ] = "41b6118cc1f9b7d2c671e4e3498d0b0f7e38ca8c";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.067.1/dmd.2.067.1.windows.zip"   ] = "8ea799291320f61fbfc0618351af6adf10107334";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.067.1/dmd.2.067.1.linux.zip"     ] = "2c158da0ac406877b8934487518aded785ef3439";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.067.1/dmd.2.067.1.freebsd-32.zip"] = "ea850992ad533b6709fe8bca8cf5d19fd6ddf698";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.067.1/dmd.2.067.1.freebsd-64.zip"] = "68bde60035813c07958abb248accce48026ec081";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.067.1/dmd.2.067.1.osx.zip"       ] = "bb2beb054e6feb67288a912ab62acbc685132091";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.068.0/dmd.2.068.0.windows.zip"   ] = "7f3ddcdc19df81780a255652d0559bbe1780572e";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.068.0/dmd.2.068.0.linux.zip"     ] = "dede88e477919a825713c95dede44690aa5fa46d";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.068.0/dmd.2.068.0.freebsd-32.zip"] = "6daba7d8683df92c5a120ba8d61d7300c251d98a";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.068.0/dmd.2.068.0.freebsd-64.zip"] = "ccb985ef933f99fd8620c197ecbbfc92541c4572";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.068.0/dmd.2.068.0.osx.zip"       ] = "2831b535909bd82ca2fe711fda4c35c34198ebcd";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.068.1/dmd.2.068.1.windows.zip"   ] = "6ad214fab50a6d679bb0e847a6efbb6c95635ac5";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.068.1/dmd.2.068.1.linux.zip"     ] = "8b5237fd80c635859da36a673a6c52b357fdf26f";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.068.1/dmd.2.068.1.freebsd-32.zip"] = "6387f3b70713a953b68c02b1b442098bd5eec354";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.068.1/dmd.2.068.1.freebsd-64.zip"] = "ba65233459f97a2a2c2b4c02b1308e61350e7426";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.068.1/dmd.2.068.1.osx.zip"       ] = "2917fd6663f928e4523d952df29af1d86dddd9d0";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.068.2/dmd.2.068.2.windows.zip"   ] = "747b5e805276a706d15f0d36c62be88830eab77a";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.068.2/dmd.2.068.2.linux.zip"     ] = "814640bb81665695e807d8b6e61acec2a0630bb8";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.068.2/dmd.2.068.2.freebsd-32.zip"] = "e4a2eaf083bfb38f2c3d5450afd5af643c8bd39b";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.068.2/dmd.2.068.2.freebsd-64.zip"] = "f561f6970924b4ace870e45b2300eceba21a2ffc";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.068.2/dmd.2.068.2.osx.zip"       ] = "db7b9be84ee2413b82c26db415df099422c8c867";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.069.0/dmd.2.069.0.windows.zip"   ] = "4fa12a1ee224b0400bd6a3c969f461019848dd8c";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.069.0/dmd.2.069.0.linux.zip"     ] = "2368cd7c98bdd7aa147cfee790223190eea9a2fb";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.069.0/dmd.2.069.0.freebsd-32.zip"] = "b05f367b2169fdc07fbdfe0a7a305e2c3b702832";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.069.0/dmd.2.069.0.freebsd-64.zip"] = "72c249e35cd2fb55d5f3f79f6211e1c798336250";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.069.0/dmd.2.069.0.osx.zip"       ] = "f4306fe519d6752e1879477cae6b0637a0bafca2";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.069.1/dmd.2.069.1.windows.zip"   ] = "0e4630114b17971608cdf961eae6680d4b1b0b9a";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.069.1/dmd.2.069.1.linux.zip"     ] = "982f5d2063d6f9cf242c4c8e38b001a4c0b5d4db";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.069.1/dmd.2.069.1.freebsd-32.zip"] = "c3268a4aefe7406c5b31ed56065d56e7401fb32d";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.069.1/dmd.2.069.1.freebsd-64.zip"] = "7fd2c1dbadcf123665251aee3a24d3741989da12";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.069.1/dmd.2.069.1.osx.zip"       ] = "244e0b374c17e13d81e596174467a8166c30ee06";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.069.2/dmd.2.069.2.windows.zip"   ] = "dd95c861bad2ce3bbd0d6882b92d75442550e28c";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.069.2/dmd.2.069.2.linux.zip"     ] = "84e7f58ead856c3ca06b885ac04a4f466154a0d0";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.069.2/dmd.2.069.2.freebsd-32.zip"] = "affbca67d6a57d4a5f18d6c119a5cf47f72f9f81";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.069.2/dmd.2.069.2.freebsd-64.zip"] = "caaefacc577e4d5c845a6566d6aeace4905b04a7";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.069.2/dmd.2.069.2.osx.zip"       ] = "222ffcfe59480c9883d7419d9a8a50754d4edcb6";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.070.0/dmd.2.070.0.windows.zip"   ] = "6365e2138840035b4c1df9bcffd6126124675dcb";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.070.0/dmd.2.070.0.linux.zip"     ] = "780101d03d089befad5d6975312deda2428b8ebf";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.070.0/dmd.2.070.0.freebsd-32.zip"] = "7622975da880a5006c1201d546af6173b7868727";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.070.0/dmd.2.070.0.freebsd-64.zip"] = "c38bd62116a3bd5daa2ffb515ccad7c1b816bfb1";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.070.0/dmd.2.070.0.osx.zip"       ] = "f1b712cbcf9753e6320c318093c96be37141ae0b";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.070.1/dmd.2.070.1.windows.zip"   ] = "26044ebcfade1051b53dd1c0e14744f661e1acd6";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.070.1/dmd.2.070.1.linux.zip"     ] = "7ce6142279fa8f0240d7f9b6f11fbc83bb7f10b4";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.070.1/dmd.2.070.1.freebsd-32.zip"] = "494c8c70d2565661f2414639af42325ef164602b";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.070.1/dmd.2.070.1.freebsd-64.zip"] = "b046449663d25179b0eb8eb703a9c0942529b9e8";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.070.1/dmd.2.070.1.osx.zip"       ] = "0b128a5f50167bc1943a7272eca0eda086cb87fd";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.070.2/dmd.2.070.2.windows.zip"   ] = "bfa0348c85174657ff2f7b0e8370b36d8e7f0a76";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.070.2/dmd.2.070.2.linux.zip"     ] = "4eeca47bc5a1bc1a38f91615218e05aa6dad7711";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.070.2/dmd.2.070.2.freebsd-32.zip"] = "bc60574bd392bb7b42ec10282e2fa33491ba9d56";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.070.2/dmd.2.070.2.freebsd-64.zip"] = "e0bd7c727d8bc5a3df3b5a70402dba24ce16c5ab";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.070.2/dmd.2.070.2.osx.zip"       ] = "578114de8ae5f89cfd9275f340be26494fa05a38";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.071.0/dmd.2.071.0.windows.zip"   ] = "ac8b4167b077f6d09701d5135a5f061788587310";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.071.0/dmd.2.071.0.linux.zip"     ] = "8ee9713be14ef2fe6024b3f93e24667d8a2a3d47";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.071.0/dmd.2.071.0.freebsd-32.zip"] = "6a9e57384c4afbe9888dcb44c9878320ab9be15e";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.071.0/dmd.2.071.0.freebsd-64.zip"] = "76cfe16e1c617aba360a5d855a85d42b7c9f7072";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.071.0/dmd.2.071.0.osx.zip"       ] = "ac8cf92505414858d5a9b91d03bae9eebc8c58c8";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.071.1/dmd.2.071.1.windows.zip"   ] = "337860e611e3b301ecc912de3f85f4deade59dbb";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.071.1/dmd.2.071.1.linux.zip"     ] = "44e3a64497bbfb18f689c61df876645d04b2873b";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.071.1/dmd.2.071.1.freebsd-32.zip"] = "60b822b4e807cc5d03af72dfdb9be3b7cf794e60";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.071.1/dmd.2.071.1.freebsd-64.zip"] = "7c023220eba8fd0ee88976695a56ce6401876bba";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.071.1/dmd.2.071.1.osx.zip"       ] = "a9a28d69186304ebeceec1586927625753dbbb64";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.071.2/dmd.2.071.2.windows.zip"   ] = "ebbbdb74095673736a8008c7f56a7b2c7e4dad2b";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.071.2/dmd.2.071.2.linux.zip"     ] = "78cd6a975e0f95411f2191c54c3ed1e048e3aceb";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.071.2/dmd.2.071.2.freebsd-32.zip"] = "d232ea1aa0b2ed6fc38d11334f9f323cd4a5f5b5";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.071.2/dmd.2.071.2.freebsd-64.zip"] = "4265a4a785d65d6b2e32a758b3456669daf35cb9";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.071.2/dmd.2.071.2.osx.zip"       ] = "54e2a56a032ac6dc20027cedcbd5b450e9696c97";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.072.0/dmd.2.072.0.windows.zip"   ] = "94582d51614262af07781741b4a59a112f51966a";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.072.0/dmd.2.072.0.linux.zip"     ] = "9e4e1ac4e685ca933b6ffb8342a91aca95a21d74";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.072.0/dmd.2.072.0.freebsd-32.zip"] = "46997ce5249958393268949f592455c4eb73ad1e";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.072.0/dmd.2.072.0.freebsd-64.zip"] = "b1e4e4139b036db6d1c4699d8ed86a98419466d9";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.072.0/dmd.2.072.0.osx.zip"       ] = "d163ae2696712897a99d6b47c8e9ec086281c02d";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.072.1/dmd.2.072.1.windows.zip"   ] = "41591cc7ba014c1f507a506f55314c61448acf4b";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.072.1/dmd.2.072.1.linux.zip"     ] = "8ee8912c994b3f8ee6b43fb8884c94f4d4b87648";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.072.1/dmd.2.072.1.freebsd-32.zip"] = "49ac8b219a20a738cb505f4553bf3d4b0f744b39";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.072.1/dmd.2.072.1.freebsd-64.zip"] = "227b6d9bb373912bd14ec339ba6dbd43a0bfa74f";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.072.1/dmd.2.072.1.osx.zip"       ] = "483902c982e16eb8119a9c37a4c13c4f4552709a";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.072.2/dmd.2.072.2.windows.zip"   ] = "351e602bbab1e5ef333b6717cacd32a6b3ce5845";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.072.2/dmd.2.072.2.linux.zip"     ] = "12ec51ad765e85e2bc48960406dc9ba31e935f66";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.072.2/dmd.2.072.2.freebsd-32.zip"] = "91c80aad8475935952bd9ea2a3806c7e64730250";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.072.2/dmd.2.072.2.freebsd-64.zip"] = "b8c2bc9dce209be8c323fb4138cfc786bc28bc6d";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.072.2/dmd.2.072.2.osx.zip"       ] = "50537278f6bb549a08cf1fa6e993a55e6c4b01d5";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.073.0/dmd.2.073.0.windows.zip"   ] = "24f4c925ecff356691ac6e878eec64d0ad207a82";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.073.0/dmd.2.073.0.linux.zip"     ] = "f7db8d0dd29f034bacab671bf59dd88cd7f9c8c1";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.073.0/dmd.2.073.0.freebsd-32.zip"] = "7ca5b1a15ee8c24aa54753dce20a1b226cf2d389";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.073.0/dmd.2.073.0.freebsd-64.zip"] = "073f34cf9a65f0408b48b4a8b24da2664ff9e3f6";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.073.0/dmd.2.073.0.osx.zip"       ] = "7f3e8a8a8f8b77b3f07a641874648d475669e98b";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.073.1/dmd.2.073.1.windows.zip"   ] = "cd713c221eecb7bbd3fa66f6bd261e094f761165";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.073.1/dmd.2.073.1.linux.zip"     ] = "034c9891f150a85bc10e1d495a164074bc805d4d";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.073.1/dmd.2.073.1.freebsd-32.zip"] = "372fa1a71a30220603b669425ef432cc8f5cff08";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.073.1/dmd.2.073.1.freebsd-64.zip"] = "6451f504732c051fc8d5596a83f0609956ea4809";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.073.1/dmd.2.073.1.osx.zip"       ] = "3a8cb8f107a06953f4f4ff376fcb1819cab978d5";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.073.2/dmd.2.073.2.windows.zip"   ] = "4fc89d4453e60e2246260d91f08db17713a7cfca";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.073.2/dmd.2.073.2.linux.zip"     ] = "836cffed20d90af9d5c8bda772e2d7cce2d0d2fe";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.073.2/dmd.2.073.2.freebsd-32.zip"] = "2f1dab4a3361bcb228d65b6b4ee62a7a0356ba3e";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.073.2/dmd.2.073.2.freebsd-64.zip"] = "5186690fc82f1df4359201bded5b994d6f527cdf";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.073.2/dmd.2.073.2.osx.zip"       ] = "92b055030e9e22a089e4662b595d8d624fcd6548";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.074.0/dmd.2.074.0.windows.zip"   ] = "bccbe4a1d71ac2f3bee170b8ed96ae5747396812";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.074.0/dmd.2.074.0.linux.zip"     ] = "6f87305cfffdce4859586b66b3f116e2c9346988";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.074.0/dmd.2.074.0.freebsd-32.zip"] = "382cfcf7991cdfc5a333862bc2e5ae02545303bd";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.074.0/dmd.2.074.0.freebsd-64.zip"] = "c74815d356928693a5178a7e06d970c37566f430";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.074.0/dmd.2.074.0.osx.zip"       ] = "f0be7e684f2aa666bd0677440730014aec5b254d";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.074.1/dmd.2.074.1.windows.zip"   ] = "2dd8f61d077f789ddcae2fc3636f2f103743e38e";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.074.1/dmd.2.074.1.linux.zip"     ] = "80cadb117d646de8d989e8931f3faa1f5d7bc705";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.074.1/dmd.2.074.1.freebsd-32.zip"] = "1e440eb65d65bf1307b8ba760c51759f6216b919";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.074.1/dmd.2.074.1.freebsd-64.zip"] = "6aef98eea18a113ade2b1c1ee16402c7792302a0";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.074.1/dmd.2.074.1.osx.zip"       ] = "419133c89a72c7586f409edc27bad529188f660a";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.075.0/dmd.2.075.0.windows.zip"   ] = "d0330d92a8c3d8e7a8b2ea7c5511bf45032c5b8c";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.075.0/dmd.2.075.0.linux.zip"     ] = "a382df36aa452323f4b6e971a02b67dca5cc07c0";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.075.0/dmd.2.075.0.freebsd-32.zip"] = "98a7e411dbe903f28a96b8a6abb0af69ad269d89";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.075.0/dmd.2.075.0.freebsd-64.zip"] = "291ca58d078446f5691e04865e0829976007886f";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.075.0/dmd.2.075.0.osx.zip"       ] = "68fa49fe9239b35123d09f3e0178df2f8c52453d";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.075.1/dmd.2.075.1.windows.zip"   ] = "8ae47dde29c2bf697be09140a84a8484c2479eb4";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.075.1/dmd.2.075.1.linux.zip"     ] = "caefa6140f984da199b35a375e667149edb90b49";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.075.1/dmd.2.075.1.freebsd-32.zip"] = "a327a3842a6f7b30677dda64ca4fb6d506f7e760";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.075.1/dmd.2.075.1.freebsd-64.zip"] = "8bedd9219d1d67e21dccd996360ee7c9010f8e1c";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.075.1/dmd.2.075.1.osx.zip"       ] = "c0a8ba5f1f85620b6de8763014e68b3a8757d93d";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.076.0/dmd.2.076.0.windows.zip"   ] = "e9dd7d41a46598059c08f0e712e8e0bb39a2648a";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.076.0/dmd.2.076.0.linux.zip"     ] = "772304613c0b23cbb51a902643588ca30cbf37cd";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.076.0/dmd.2.076.0.freebsd-32.zip"] = "bce45235c0d6fa37896b3166d91c4690c97b538f";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.076.0/dmd.2.076.0.freebsd-64.zip"] = "34b3885b8b135fb1923399540cefa0f48cf0b876";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.076.0/dmd.2.076.0.osx.zip"       ] = "81cfec8ee646c0e8ea83cfb65f33cdf3dc4da516";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.076.1/dmd.2.076.1.windows.zip"   ] = "95073776bc7d55a6b05f14c43c28bb34151f3037";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.076.1/dmd.2.076.1.linux.zip"     ] = "693533b60506d1ada255e47250c862fa2dc00e6a";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.076.1/dmd.2.076.1.freebsd-32.zip"] = "6a5d7eb43ff631246a6d9bb00d6285eedb7b2878";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.076.1/dmd.2.076.1.freebsd-64.zip"] = "bff01763ff8b615d66d652ac2c9b2cadaa23575c";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.076.1/dmd.2.076.1.osx.zip"       ] = "3604c8b1643298d18040116066aed6e8994c7b9e";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.077.0/dmd.2.077.0.windows.zip"   ] = "cfb0564b1f1f3ced94bd55c224846bfbac210547";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.077.0/dmd.2.077.0.linux.zip"     ] = "e506085aa1b4d4c5a7a793a02d9fafbb324610df";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.077.0/dmd.2.077.0.freebsd-32.zip"] = "c872f0096e3cb065977542ba5db50d271b721bb4";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.077.0/dmd.2.077.0.freebsd-64.zip"] = "07f1f7b34ca3b93c557192c7922c9ddc31703519";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.077.0/dmd.2.077.0.osx.zip"       ] = "7f65e52aac1f360e9e739ea0db0e603df3af2cc0";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.077.1/dmd.2.077.1.windows.zip"   ] = "d73318d9069ffc385d65df65b761983220dbb92e";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.077.1/dmd.2.077.1.linux.zip"     ] = "7c688032c224473db7ab240eaec34028158284cb";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.077.1/dmd.2.077.1.freebsd-32.zip"] = "deca6a7827daeba7519810101f26ebdfacc9503c";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.077.1/dmd.2.077.1.freebsd-64.zip"] = "adc7b72f4a8b7bd5cb8846a262289b5b13f17a6c";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.077.1/dmd.2.077.1.osx.zip"       ] = "d7c0141eb2c7b16306440d9f1a2976c835749121";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.078.0/dmd.2.078.0.windows.zip"   ] = "cead01381421c9dc5e155a9cb0abd54eab8d5456";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.078.0/dmd.2.078.0.linux.zip"     ] = "f8f3ad0c7f13eb54baf7879f3531da74ebcde9e3";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.078.0/dmd.2.078.0.freebsd-32.zip"] = "bd56779b866c7eece3f56799f8e466ff2fb7ed28";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.078.0/dmd.2.078.0.freebsd-64.zip"] = "9449477855c57b4bfb35844a28a8f1dcda4c6545";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.078.0/dmd.2.078.0.osx.zip"       ] = "16900bc9d995ae4d9041df65af0d6d7b55c6eef6";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.078.1/dmd.2.078.1.windows.zip"   ] = "cafe2f7061d02d27bdcc1c9c014840ef39d8fd17";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.078.1/dmd.2.078.1.linux.zip"     ] = "b5428efca613311b6f8ecf0e5d621a23ff69393d";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.078.1/dmd.2.078.1.freebsd-32.zip"] = "ac484a8a740e1f820f5f7cfebac3560810b724b1";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.078.1/dmd.2.078.1.freebsd-64.zip"] = "5cd8da3e7a3c6beb6c5f70d2f66e9c6c7d60a9d2";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.078.1/dmd.2.078.1.osx.zip"       ] = "04bf300fc90838754e329782d79034681ee0a3af";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.078.2/dmd.2.078.2.windows.zip"   ] = "7fa2a04dacdbddeec42c1d532057d51452e40cf6";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.078.2/dmd.2.078.2.linux.zip"     ] = "e72479cb8ee1ae46f813d392b072516f1043ca76";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.078.2/dmd.2.078.2.freebsd-32.zip"] = "95237d94eea72fb3b88d6adf6739853ef225607e";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.078.2/dmd.2.078.2.freebsd-64.zip"] = "ff26520260a998afd02bbe5a3eb0a5c2e2533741";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.078.2/dmd.2.078.2.osx.zip"       ] = "ecb631d71ce2eaf1601157314b187c8369d3edfa";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.078.3/dmd.2.078.3.windows.zip"   ] = "40a748a01109539aa97d006c0ddc60336866edbe";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.078.3/dmd.2.078.3.linux.zip"     ] = "54c85809da068df55d2d45e8e19aa14a8c0d0e71";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.078.3/dmd.2.078.3.freebsd-32.zip"] = "327c025dc81e111e219ffa214e6735fd30693c95";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.078.3/dmd.2.078.3.freebsd-64.zip"] = "b10baad3eadda45f68d721199d1cb8debf176538";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.078.3/dmd.2.078.3.osx.zip"       ] = "adadcbbef8d45161d1401286759899b38c78b3f9";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.079.0/dmd.2.079.0.windows.zip"   ] = "c179c69d23f7b82c0636ccb9dfa718750e49deee";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.079.0/dmd.2.079.0.linux.zip"     ] = "027372c4dc9937dbaed8fbbf8b7e98f426bbf1a9";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.079.0/dmd.2.079.0.freebsd-32.zip"] = "705e5745194202b8faf2f4654837fc69ccd0be24";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.079.0/dmd.2.079.0.freebsd-64.zip"] = "0e74b022f235a8d98329f2ef05084798c3342b96";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.079.0/dmd.2.079.0.osx.zip"       ] = "03cf07c77a0dc986e80424da94ab5a033d6720ec";
	}
}

alias dmdInstaller = singleton!DMDInstaller; /// ditto
