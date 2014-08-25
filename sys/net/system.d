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
 *   Vladimir Panteleev <vladimir@thecybershadow.net>
 */

module ae.sys.net.system;

version(Windows)
	import ae.sys.net.wininet;
else
{
	import ae.sys.net.ae;
	import ae.net.ssl.openssl;
}
