/**
 * ae.utils.text.html
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

module ae.utils.text.html;

import ae.utils.textout;

string encodeHtmlEntities(bool inAttribute = true)(string s)
{
	StringBuilder result;
	size_t start = 0;

	foreach (i, c; s)
		if (c=='<')
			result.put(s[start..i], "&lt;"),
			start = i+1;
		else
		if (c=='>')
			result.put(s[start..i], "&gt;"),
			start = i+1;
		else
		if (c=='&')
			result.put(s[start..i], "&amp;"),
			start = i+1;
		else
		if (inAttribute && c=='"')
			result.put(s[start..i], "&quot;"),
			start = i+1;
		else
		if (inAttribute && c=='\'')
			result.put(s[start..i], "&#39;"),
			start = i+1;

	if (!start)
		return s;

	result.put(s[start..$]);
	return result.get();
}
