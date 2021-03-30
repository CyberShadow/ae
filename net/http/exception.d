/**
 * Allows throwing exceptions with HTTP status codes.
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

module ae.net.http.exception;

import std.exception;

import ae.net.http.common;

/// Encapsulates an HTTP status as a D exception.
class HttpException : Exception
{
	HttpStatusCode status;

	this(HttpStatusCode status, string msg = null)
	{
		this.status = status;
		super(msg);
	}
}

///
unittest
{
	import ae.net.http.responseex : HttpResponseEx;
	auto response = new HttpResponseEx;
	bool evilDetected = true;
	try
	{
		if (evilDetected)
			throw new HttpException(HttpStatusCode.Forbidden, "Do no evil!");
	}
	catch (HttpException e)
		response.writeError(e.status, e.msg);
	catch (Exception e)
		response.writeError(HttpStatusCode.InternalServerError, e.msg);
}

/// Throws a corresponding `HttpException` if `val` is false-ish.
T httpEnforce(T)(T val, HttpStatusCode status, string msg = null)
{
	return enforce(val, new HttpException(status, msg));
}
