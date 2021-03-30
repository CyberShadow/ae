/**
 * Automatically select the Network implementation
 * that's most likely to work on the current system.
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

module ae.sys.net.system;

version(Windows)
{
	// ae.sys.windows.dll does not compile on
	// 2.066 or earlier due to a compiler bug.
	static if (__VERSION__ > 2_066)
		import ae.sys.net.wininet;
	else
		import ae.sys.net.curl;
}
else
{
	import ae.sys.net.ae;
	import ae.net.ssl.openssl;
	mixin SSLUseLib;
}
