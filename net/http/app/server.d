/**
 * Flexible app server glue, supporting all
 * protocols implemented in this library.
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

module ae.net.http.app.server;

debug version(unittest) version = SSL;

import std.algorithm.comparison;
import std.algorithm.searching;
import std.array;
import std.conv;
import std.exception;
import std.file;
import std.format;
import std.process : environment;
import std.socket;
import std.stdio : stderr;
import std.typecons;

import ae.net.asockets;
import ae.net.http.cgi.common;
import ae.net.http.cgi.script;
import ae.net.http.fastcgi.app;
import ae.net.http.responseex;
import ae.net.http.scgi.app;
import ae.net.http.server;
import ae.net.shutdown;
import ae.net.ssl;
import ae.sys.log;
import ae.utils.array;

struct ServerConfig
{
	enum Transport
	{
		inet,
		unix,
		stdin,
		accept,
	}
	Transport transport;

	struct Listen
	{
		string addr;
		ushort port;
		string socketPath;
	}
	Listen listen;

	enum Protocol
	{
		http,
		cgi,
		scgi,
		fastcgi,
	}
	Protocol protocol;

	Nullable!bool nph;

	struct SSL
	{
		string cert, key;
	}
	SSL ssl;

	string logDir;
	string prefix = "/";
	string username;
	string password;
}

struct Server(bool useSSL)
{
	static if (useSSL)
	{
		import ae.net.ssl.openssl;
		mixin SSLUseLib;
	}

	immutable ServerConfig[string] config;

	this(immutable ServerConfig[string] config)
	{
		this.config = config;
	}

	void delegate(
		HttpRequest request,
		immutable ref ServerConfig serverConfig,
		void delegate(HttpResponse) handleResponse,
		ref Logger log,
	) handleRequest;

	string banner;

	void startServer(string serverName)
	{
		auto pserverConfig = serverName in config;
		pserverConfig.enforce(format!"Did not find a server named %s."(serverName));
		startServer(serverName, *pserverConfig, true);
	}

	void startServers()
	{
		enforce(config.length, "No servers are configured.");

		foreach (name, serverConfig; config)
			startServer(name, serverConfig, false);

		enforce(socketManager.size(), "No servers to start!");
		socketManager.loop();
	}

	bool runImplicitServer()
	{
		if (inCGI())
		{
			runImplicitServer(
				ServerConfig.Transport.stdin,
				ServerConfig.Protocol.cgi,
				"cgi",
				"CGI",
				"a CGI script");
			return true;
		}

		if (inFastCGI())
		{
			runImplicitServer(
				ServerConfig.Transport.accept,
				ServerConfig.Protocol.fastcgi,
				"fastcgi",
				"FastCGI",
				"a FastCGI application");
			return true;
		}

		return false;
	}

private:

	void runImplicitServer(
		ServerConfig.Transport transport,
		ServerConfig.Protocol protocol,
		string serverName,
		string protocolText,
		string kindText,
	)
	{
		auto pserverConfig = serverName in config;
		enum errorFmt =
			"This program was invoked as %2$s, but no \"%1$s\" server is configured.\n\n" ~
			"Please configure a server named %1$s.";
		enforce(pserverConfig, format!errorFmt(serverName, kindText));
		enforce(pserverConfig.transport == transport,
			format!"The transport must be set to %s in the %s server for implicit %s requests."
			(transport, serverName, protocolText));
		enforce(pserverConfig.protocol == protocol,
			format!"The protocol must be set to %s in the %s server for implicit %s requests."
			(protocol, serverName, protocolText));

		startServer(serverName, *pserverConfig, true);
		socketManager.loop();
	}


	void startServer(string name, immutable ServerConfig serverConfig, bool exclusive)
	{
		scope(failure) stderr.writefln("Error with server %s:", name);

		auto isSomeCGI = serverConfig.protocol.among(
			ServerConfig.Protocol.cgi,
			ServerConfig.Protocol.scgi,
			ServerConfig.Protocol.fastcgi);

		// Check options
		if (serverConfig.listen.addr)
			enforce(serverConfig.transport == ServerConfig.Transport.inet,
				"listen.addr should only be set with transport = inet");
		if (serverConfig.listen.port)
			enforce(serverConfig.transport == ServerConfig.Transport.inet,
				"listen.port should only be set with transport = inet");
		if (serverConfig.listen.socketPath)
			enforce(serverConfig.transport == ServerConfig.Transport.unix,
				"listen.socketPath should only be set with transport = unix");
		if (serverConfig.protocol == ServerConfig.Protocol.cgi)
			enforce(serverConfig.transport == ServerConfig.Transport.stdin,
				"CGI can only be used with transport = stdin");
		if (serverConfig.ssl.cert || serverConfig.ssl.key)
			enforce(serverConfig.protocol == ServerConfig.Protocol.http,
				"SSL can only be used with protocol = http");
		if (!serverConfig.nph.isNull)
			enforce(isSomeCGI,
				"Setting NPH only makes sense with protocol = cgi, scgi, or fastcgi");
		enforce(serverConfig.prefix.startsWith("/") && serverConfig.prefix.endsWith("/"),
			"Server prefix should start and end with /");

		if (!exclusive && serverConfig.transport.among(
				ServerConfig.Transport.stdin,
				ServerConfig.Transport.accept))
		{
			stderr.writefln("Skipping exclusive server %1$s.", name);
			return;
		}

		static if (useSSL) SSLContext ctx;
		if (serverConfig.ssl !is ServerConfig.SSL.init)
		{
			static if (useSSL)
			{
				ctx = ssl.createContext(SSLContext.Kind.server);
				ctx.setCertificate(serverConfig.ssl.cert);
				ctx.setPrivateKey(serverConfig.ssl.key);
			}
			else
				throw new Exception("This executable was built without SSL support. Cannot use SSL, sorry!");
		}

		// Place on heap to extend lifetime past scope,
		// even though this function creates a closure
		Logger* log = {
			Logger log;
			auto logName = "Server-" ~ name;
			string logDir = serverConfig.logDir;
			if (logDir is null)
				logDir = "/dev/stderr";
			switch (logDir)
			{
				case "/dev/stderr":
					log = consoleLogger(logName);
					break;
				case "/dev/null":
					log = nullLogger();
					break;
				default:
					log = fileLogger(logDir ~ "/" ~ logName);
					break;
			}
			return [log].ptr;
		}();

		SocketServer server;
		string protocol = join(
			(serverConfig.transport == ServerConfig.Transport.inet ? [] : [serverConfig.transport.text]) ~
			(
				(serverConfig.protocol == ServerConfig.Protocol.http && serverConfig.ssl !is ServerConfig.SSL.init)
				? ["https"]
				: (
					[serverConfig.protocol.text] ~
					(serverConfig.ssl is ServerConfig.SSL.init ? [] : ["tls"])
				)
			),
			"+");

		bool nph;
		if (isSomeCGI)
			nph = serverConfig.nph.isNull ? isNPH() : serverConfig.nph.get;

		string[] serverAddrs;
		if (serverConfig.protocol == ServerConfig.Protocol.fastcgi)
			serverAddrs = environment.get("FCGI_WEB_SERVER_ADDRS", null).split(",");

		void handleConnection(IConnection c, string localAddressStr, string remoteAddressStr)
		{
			static if (useSSL) if (ctx)
				c = ssl.createAdapter(ctx, c);

			void handleRequest(HttpRequest request, void delegate(HttpResponse) handleResponse)
			{
				void logAndHandleResponse(HttpResponse response)
				{
					log.log([
						"", // align IP to tab
						request ? request.remoteHosts(remoteAddressStr).get(0, remoteAddressStr) : remoteAddressStr,
						response ? text(cast(ushort)response.status) : "-",
						request ? format("%9.2f ms", request.age.total!"usecs" / 1000f) : "-",
						request ? request.method : "-",
						request ? protocol ~ "://" ~ localAddressStr ~ request.resource : "-",
						response ? response.headers.get("Content-Type", "-") : "-",
						request ? request.headers.get("Referer", "-") : "-",
						request ? request.headers.get("User-Agent", "-") : "-",
					].join("\t"));

					handleResponse(response);
				}

				this.handleRequest(request, serverConfig, &logAndHandleResponse, *log);
			}

			final switch (serverConfig.protocol)
			{
				case ServerConfig.Protocol.cgi:
				{
					auto cgiRequest = readCGIRequest();
					auto request = new CGIHttpRequest(cgiRequest);
					bool responseWritten;
					void handleResponse(HttpResponse response)
					{
						if (nph)
							writeNPHResponse(response);
						else
							writeCGIResponse(response);
						responseWritten = true;
					}

					handleRequest(request, &handleResponse);
					assert(responseWritten);
					break;
				}
				case ServerConfig.Protocol.scgi:
				{
					auto conn = new SCGIConnection(c);
					conn.log = *log;
					conn.nph = nph;
					void handleSCGIRequest(ref CGIRequest cgiRequest)
					{
						auto request = new CGIHttpRequest(cgiRequest);
						handleRequest(request, &conn.sendResponse);
					}
					conn.handleRequest = &handleSCGIRequest;
					break;
				}
				case ServerConfig.Protocol.fastcgi:
				{
					if (serverAddrs && !serverAddrs.canFind(remoteAddressStr))
					{
						log.log("Address not in FCGI_WEB_SERVER_ADDRS, rejecting");
						c.disconnect("Forbidden by FCGI_WEB_SERVER_ADDRS");
						return;
					}
					auto fconn = new FastCGIResponderConnection(c);
					fconn.log = *log;
					fconn.nph = nph;
					void handleCGIRequest(ref CGIRequest cgiRequest, void delegate(HttpResponse) handleResponse)
					{
						auto request = new CGIHttpRequest(cgiRequest);
						handleRequest(request, handleResponse);
					}
					fconn.handleRequest = &handleCGIRequest;
					break;
				}
				case ServerConfig.Protocol.http:
				{
					alias connRemoteAddressStr = remoteAddressStr;
					alias handleServerRequest = handleRequest;
					auto self = &this;

					final class HttpConnection : BaseHttpServerConnection
					{
					protected:
						this()
						{
							this.log = log;
							if (self.banner)
								this.banner = self.banner;
							this.handleRequest = &onRequest;

							super(c);
						}

						void onRequest(HttpRequest request)
						{
							handleServerRequest(request, &sendResponse);
						}

						override bool acceptMore() { return server.isListening; }
						override string formatLocalAddress(HttpRequest r) { return protocol ~ "://" ~ localAddressStr; }
						override @property string remoteAddressStr() { return connRemoteAddressStr; }
					}
					new HttpConnection();
					break;
				}
			}
		}

		final switch (serverConfig.transport)
		{
			case ServerConfig.Transport.stdin:
				static if (is(FileConnection))
				{
					import std.stdio : stdin, stdout;
					import core.sys.posix.unistd : dup;
					auto c = new Duplex(
						new FileConnection(stdin.fileno.dup),
						new FileConnection(stdout.fileno.dup),
					);
					handleConnection(c,
						environment.get("REMOTE_ADDR", "-"),
						environment.get("SERVER_NAME", "-"));
					c.disconnect();
					return;
				}
				else
					throw new Exception("Sorry, transport = stdin is not supported on this platform!");
			case ServerConfig.Transport.accept:
				server = SocketServer.fromStdin();
				break;
			case ServerConfig.Transport.inet:
			{
				auto tcpServer = new TcpServer();
				tcpServer.listen(serverConfig.listen.port, serverConfig.listen.addr);
				server = tcpServer;
				break;
			}
			case ServerConfig.Transport.unix:
			{
				server = new SocketServer();
				static if (is(UnixAddress))
				{
					string socketPath = serverConfig.listen.socketPath;
					// Work around "path too long" errors with long $PWD
					{
						import std.path : relativePath;
						auto relPath = relativePath(socketPath);
						if (relPath.length < socketPath.length)
							socketPath = relPath;
					}
					socketPath.remove().collectException();

					AddressInfo ai;
					ai.family = AddressFamily.UNIX;
					ai.type = SocketType.STREAM;
					ai.address = new UnixAddress(socketPath);
					server.listen([ai]);

					addShutdownHandler({ socketPath.remove(); });
				}
				else
					throw new Exception("UNIX sockets are not available on this platform");
			}
		}

		addShutdownHandler({ server.close(); });

		server.handleAccept =
			(SocketConnection incoming)
			{
				handleConnection(incoming, incoming.localAddressStr, incoming.remoteAddressStr);
			};

		foreach (address; server.localAddresses)
			log.log("Listening on " ~ formatAddress(protocol, address) ~ " [" ~ to!string(address.addressFamily) ~ "]");
	}
}

unittest
{
	Server!false testServer;
}
