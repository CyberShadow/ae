/**
 * JSON-RPC over standard I/O.
 *
 * Provides a JSON-RPC connection using stdin/stdout with
 * newline-delimited JSON framing.
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

module ae.net.jsonrpc.stdio;

version (Posix):

import core.sys.posix.unistd : STDIN_FILENO, STDOUT_FILENO;

import ae.net.asockets : Duplex, FileConnection, LineBufferedAdapter;
import ae.net.jsonrpc.ndjson : lineDelimitedJsonRpcConnection;

/// Create a JSON-RPC connection over stdin/stdout using newline-delimited JSON.
///
/// Each JSON-RPC message is a single line terminated by '\n'.
/// This is suitable for use with language servers, CLI tools, or
/// piped communication between processes.
///
/// Note: This transport uses POSIX file descriptors and integrates
/// with the ae event loop for non-blocking I/O.
///
/// Example:
/// ---
/// auto conn = stdioLDJsonRpcConnection();
/// auto codec = new JsonRpcServerCodec(conn);
/// codec.handleRequest = &dispatcher.dispatch;
/// socketManager.loop();
/// ---
LineBufferedAdapter stdioLDJsonRpcConnection()
{
	auto stdinConn = new FileConnection(STDIN_FILENO);
	auto stdoutConn = new FileConnection(STDOUT_FILENO);
	auto duplex = new Duplex(stdinConn, stdoutConn);
	return lineDelimitedJsonRpcConnection(duplex);
}

// TODO: Consider adding LSP-style Content-Length framing as an alternative
// framing mode for Language Server Protocol compatibility.
