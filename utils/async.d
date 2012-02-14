/**
 * Asynchronous programming helpers
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

module ae.utils.async;

void asyncApply(T)(T[] arr, void delegate(T value, void delegate() next) f, void delegate() done = null)
{
	size_t index = 0;

	void next()
	{
		if (index < arr.length)
			f(arr[index++], &next);
		else
		if (done)
			done();
	}

	next();
}
