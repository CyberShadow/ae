/**
 * Code to convert strings from a few common codepages to UTF-8.
 * Loosely based on https://github.com/adamdruppe/misc-stuff-including-D-programming-language-web-stuff/blob/master/characterencodings.d
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

module ae.utils.iconv;

import std.string;
import std.array;
import std.conv;
import std.exception;

import ae.utils.text : ascii;

/// Convert text in an arbitrary (known) encoding to UTF-8.
/// Params:
///   data  = text to convert
///   cp    = the name of the source character encoding
///   force = do not throw on errors; instead, do a best-effort translation
string toUtf8(in ascii data, string cp, bool force)
{
	cp = toLower(cp).replace("-", "");

	// Windows-1252 is a superset of ISO-8859-1
	if (cp == "iso88591")
		cp = "windows1252";

	switch (cp)
	{
		case "utf8":
		{
			import std.utf;
			validate(data);
			return data;
		}
		case "usascii":
		{
			if (hasHighAsciiChars(data))
			{
				if (force)
					return stripNonAscii(data);
				else
					throw new Exception("Non-ASCII characters in US-ASCII text");
			}

			return data;
		}
		case "utf16":
			enforce(data.length % 2 == 0, "Bad number of bytes for utf16");
			return to!string(cast(wstring)data);
		case "utf32":
			enforce(data.length % 4 == 0, "Bad number of bytes for utf32");
			return to!string(cast(dstring)data);
		default:
		{
			if (!hasHighAsciiChars(data))
				return data;

			if (cp in codepages)
			{
				wstring cpData = codepages[cp];
				wchar[] result = new wchar[data.length];
				foreach (size_t i, ubyte b; data)
					result[i] = b < 0x80 ? b : cpData[b - 0x80];
				return to!string(assumeUnique(result));
			}
			else
			if (force)
				return stripNonAscii(data);
			else
				throw new Exception("Don't know how to decode " ~ cp);
		}
	}
}

bool hasHighAsciiChars(in ascii data)
{
	foreach (char b; data)
		if (b >= 0x80)
			return true;
	return false;
}

string stripNonAscii(in ascii data)
{
	wchar[] result = new wchar[data.length];
	foreach (size_t i, ubyte b; data)
		result[i] = b < 0x80 ? b : '\uFFFD';
	return to!string(assumeUnique(result));
}


immutable shared wstring[string] codepages;

shared static this()
{
	codepages["windows1250"] = "€‚„…†‡‰Š‹ŚŤŽŹ‘’“”•–—™š›śťžź ˇ˘Ł¤Ą¦§¨©Ş«¬­®Ż°±˛ł´µ¶·¸ąş»Ľ˝ľżŔÁÂĂÄĹĆÇČÉĘËĚÍÎĎĐŃŇÓÔŐÖ×ŘŮÚŰÜÝŢßŕáâăäĺćçčéęëěíîďđńňóôőö÷řůúűüýţ˙"w;
	codepages["windows1251"] = "ЂЃ‚ѓ„…†‡€‰Љ‹ЊЌЋЏђ‘’“”•–—™љ›њќћџ ЎўЈ¤Ґ¦§Ё©Є«¬­®Ї°±Ііґµ¶·ё№є»јЅѕїАБВГДЕЖЗИЙКЛМНОПРСТУФХЦЧШЩЪЫЬЭЮЯабвгдежзийклмнопрстуфхцчшщъыьэюя"w;
	codepages["windows1252"] = "€‚ƒ„…†‡ˆ‰Š‹ŒŽ‘’“”•–—˜™š›œžŸ ¡¢£¤¥¦§¨©ª«¬­®¯°±²³´µ¶·¸¹º»¼½¾¿ÀÁÂÃÄÅÆÇÈÉÊËÌÍÎÏÐÑÒÓÔÕÖ×ØÙÚÛÜÝÞßàáâãäåæçèéêëìíîïðñòóôõö÷øùúûüýþÿ"w;
	codepages["windows1253"] = "€‚ƒ„…†‡‰‹‘’“”•–—™› ΅Ά£¤¥¦§¨©«¬­®―°±²³΄µ¶·ΈΉΊ»Ό½ΎΏΐΑΒΓΔΕΖΗΘΙΚΛΜΝΞΟΠΡΣΤΥΦΧΨΩΪΫάέήίΰαβγδεζηθικλμνξοπρςστυφχψωϊϋόύώ"w;
	codepages["windows1254"] = "€‚ƒ„…†‡ˆ‰Š‹Œ‘’“”•–—˜™š›œŸ ¡¢£¤¥¦§¨©ª«¬­®¯°±²³´µ¶·¸¹º»¼½¾¿ÀÁÂÃÄÅÆÇÈÉÊËÌÍÎÏĞÑÒÓÔÕÖ×ØÙÚÛÜİŞßàáâãäåæçèéêëìíîïğñòóôõö÷øùúûüışÿ"w;
	codepages["windows1255"] = "€‚ƒ„…†‡ˆ‰‹‘’“”•–—˜™› ¡¢£₪¥¦§¨©×«¬­®¯°±²³´µ¶·¸¹÷»¼½¾¿ְֱֲֳִֵֶַָֹֺֻּֽ־ֿ׀ׁׂ׃װױײ׳״אבגדהוזחטיךכלםמןנסעףפץצקרשת‎‏"w;
	codepages["windows1256"] = "€پ‚ƒ„…†‡ˆ‰ٹ‹Œچژڈگ‘’“”•–—ک™ڑ›œ‌‍ں ،¢£¤¥¦§¨©ھ«¬­®¯°±²³´µ¶·¸¹؛»¼½¾؟ہءآأؤإئابةتثجحخدذرزسشصض×طظعغـفقكàلâمنهوçèéêëىيîïًٌٍَôُِ÷ّùْûü‎‏ے"w;
	codepages["windows1257"] = "€‚„…†‡‰‹¨ˇ¸‘’“”•–—™›¯˛ ¢£¤¦§Ø©Ŗ«¬­®Æ°±²³´µ¶·ø¹ŗ»¼½¾æĄĮĀĆÄÅĘĒČÉŹĖĢĶĪĻŠŃŅÓŌÕÖ×ŲŁŚŪÜŻŽßąįāćäåęēčéźėģķīļšńņóōõö÷ųłśūüżž˙"w;
	codepages["windows1258"] = "€‚ƒ„…†‡ˆ‰‹Œ‘’“”•–—˜™›œŸ ¡¢£¤¥¦§¨©ª«¬­®¯°±²³´µ¶·¸¹º»¼½¾¿ÀÁÂĂÄÅÆÇÈÉÊË̀ÍÎÏĐÑ̉ÓÔƠÖ×ØÙÚÛÜỮßàáâăäåæçèéêë́íîïđṇ̃óôơö÷øùúûüư₫ÿ"w;
	codepages["koi8r"] =       "─│┌┐└┘├┤┬┴┼▀▄█▌▐░▒▓⌠■∙√≈≤≥ ⌡°²·÷═║╒ё╓╔╕╖╗╘╙╚╛╜╝╞╟╠╡Ё╢╣╤╥╦╧╨╩╪╫╬©юабцдефгхийклмнопярстужвьызшэщчъЮАБЦДЕФГХИЙКЛМНОПЯРСТУЖВЬЫЗШЭЩЧЪ"w;
	codepages["koi8u"] =       "─│┌┐└┘├┤┬┴┼▀▄█▌▐░▒▓⌠■∙√≈≤≥ ⌡°²·÷═║╒ёє╔ії╗╘╙╚╛ґў╞╟╠╡ЁЄ╣ІЇ╦╧╨╩╪ҐЎ©юабцдефгхийклмнопярстужвьызшэщчъЮАБЦДЕФГХИЙКЛМНОПЯРСТУЖВЬЫЗШЭЩЧЪ"w;
	codepages["iso88591"] =    " ¡¢£¤¥¦§¨©ª«¬­®¯°±²³´µ¶·¸¹º»¼½¾¿ÀÁÂÃÄÅÆÇÈÉÊËÌÍÎÏÐÑÒÓÔÕÖ×ØÙÚÛÜÝÞßàáâãäåæçèéêëìíîïðñòóôõö÷øùúûüýþÿ"w;
	codepages["iso88592"] =    " Ą˘Ł¤ĽŚ§¨ŠŞŤŹ­ŽŻ°ą˛ł´ľśˇ¸šşťź˝žżŔÁÂĂÄĹĆÇČÉĘËĚÍÎĎĐŃŇÓÔŐÖ×ŘŮÚŰÜÝŢßŕáâăäĺćçčéęëěíîďđńňóôőö÷řůúűüýţ˙"w;
	codepages["iso88593"] =    " Ħ˘£¤Ĥ§¨İŞĞĴ­Ż°ħ²³´µĥ·¸ışğĵ½żÀÁÂÄĊĈÇÈÉÊËÌÍÎÏÑÒÓÔĠÖ×ĜÙÚÛÜŬŜßàáâäċĉçèéêëìíîïñòóôġö÷ĝùúûüŭŝ˙"w;
	codepages["iso88594"] =    " ĄĸŖ¤ĨĻ§¨ŠĒĢŦ­Ž¯°ą˛ŗ´ĩļˇ¸šēģŧŊžŋĀÁÂÃÄÅÆĮČÉĘËĖÍÎĪĐŅŌĶÔÕÖ×ØŲÚÛÜŨŪßāáâãäåæįčéęëėíîīđņōķôõö÷øųúûüũū˙"w;
	codepages["iso88595"] =    " ЁЂЃЄЅІЇЈЉЊЋЌ­ЎЏАБВГДЕЖЗИЙКЛМНОПРСТУФХЦЧШЩЪЫЬЭЮЯабвгдежзийклмнопрстуфхцчшщъыьэюя№ёђѓєѕіїјљњћќ§ўџ"w;
	codepages["iso88596"] =    " ¤،­؛؟ءآأؤإئابةتثجحخدذرزسشصضطظعغـفقكلمنهوىيًٌٍَُِّْ"w;
	codepages["iso88597"] =    " ʽʼ£¦§¨©«¬­―°±²³΄΅Ά·ΈΉΊ»Ό½ΎΏΐΑΒΓΔΕΖΗΘΙΚΛΜΝΞΟΠΡΣΤΥΦΧΨΩΪΫάέήίΰαβγδεζηθικλμνξοπρςστυφχψωϊϋόύώ"w;
	codepages["iso88598"] =    " ¢£¤¥¦§¨©×«¬­®‾°±²³´µ¶·¸¹÷»¼½¾‗אבגדהוזחטיךכלםמןנסעףפץצקרשת"w;
	codepages["iso88599"] =    " ¡¢£¤¥¦§¨©ª«¬­®¯°±²³´µ¶·¸¹º»¼½¾¿ÀÁÂÃÄÅÆÇÈÉÊËÌÍÎÏĞÑÒÓÔÕÖ×ØÙÚÛÜİŞßàáâãäåæçèéêëìíîïğñòóôõö÷øùúûüışÿ"w;
	codepages["iso885913"] =   " ”¢£¤„¦§Ø©Ŗ«¬­®Æ°±²³“µ¶·ø¹ŗ»¼½¾æĄĮĀĆÄÅĘĒČÉŹĖĢĶĪĻŠŃŅÓŌÕÖ×ŲŁŚŪÜŻŽßąįāćäåęēčéźėģķīļšńņóōõö÷ųłśūüżž’"w;
	codepages["iso885915"] =   " ¡¢£€¥Š§š©ª«¬­®¯°±²³Žµ¶·ž¹º»ŒœŸ¿ÀÁÂÃÄÅÆÇÈÉÊËÌÍÎÏÐÑÒÓÔÕÖ×ØÙÚÛÜÝÞßàáâãäåæçèéêëìíîïðñòóôõö÷øùúûüýþÿ"w;
}

deprecated string toUtf8(in ubyte[] data, string cp, bool force) { return toUtf8(cast(ascii)data, cp, force); }
deprecated bool hasHighAsciiChars(in ubyte[] data) { return hasHighAsciiChars(cast(ascii)data); }
