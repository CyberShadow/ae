/**
 * ae.utils.path
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

module ae.utils.path;

import std.path;

string rebasePath(string path, string oldBase, string newBase)
{
	return buildPath(newBase, path.absolutePath.relativePath(oldBase.absolutePath));
}
