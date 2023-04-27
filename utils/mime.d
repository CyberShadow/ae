/**
 * MIME types for common extensions.
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

module ae.utils.mime;

import std.string;
import std.path;

/// Return a likely MIME type for a file with the given name.
string guessMime(string fileName, string defaultResult = null)
{
	string ext = toLower(extension(fileName));

	if (ext.endsWith("-opt"))
		ext = ext[0..$-4]; // HACK

	switch (ext)
	{
		case ".txt":
			return "text/plain";
		case ".htm":
		case ".html":
			return "text/html";
		case ".js":
			return "text/javascript";
		case ".json":
			return "application/json";
		case ".wasm":
			return "application/wasm";
		case ".css":
			return "text/css";
		case ".png":
			return "image/png";
		case ".gif":
			return "image/gif";
		case ".jpg":
		case ".jpeg":
			return "image/jpeg";
		case ".svg":
			return "image/svg+xml";
		case ".ico":
			return "image/vnd.microsoft.icon";
		case ".swf":
			return "application/x-shockwave-flash";
		case ".wav":
			return "audio/wav";
		case ".mp3":
			return "audio/mpeg";
		case ".webm":
			return "video/webm";
		case ".mp4":
			return "video/mp4";

		case ".c":
			return "text/x-csrc";
		case ".h":
			return "text/x-chdr";
		case ".cpp":
		case ".c++":
		case ".cxx":
		case ".cc":
			return "text/x-c++src";
		case ".hpp":
		case ".h++":
		case ".hxx":
		case ".hh":
			return "text/x-c++hdr";
		case ".d": // by extension :P
			return "text/x-dsrc";
		case ".di":
			return "text/x-dhdr";

		// https://pki-tutorial.readthedocs.io/en/latest/mime.html

		case ".p8":
		// case ".key":
			return "application/pkcs8";
		case ".p10":
		// case ".csr":
			return "application/pkcs10";
		// case ".cer":
		// 	return "application/pkix-cert";
		// case ".crl":
		// 	return "application/pkix-crl";
		case ".p7c":
			return "application/pkcs7-mime";

		// case ".crt":
		// case ".der":
		// 	return "application/x-x509-ca-cert";
		// case ".crt":
		// 	return "application/x-x509-user-cert";
		// case ".crl":
		// 	return "application/x-pkcs7-crl";

		case ".pem":
			return "application/x-pem-file";
		case ".p12":
		case ".pfx":
			return "application/x-pkcs12";

		case ".p7b":
		case ".spc":
			return "application/x-pkcs7-certificates";
		case ".p7r":
			return "application/x-pkcs7-certreqresp";

		default:
			return defaultResult;
	}
}
