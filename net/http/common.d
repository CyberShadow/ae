/**
 * Concepts shared between HTTP clients and servers.
 *
 * License:
 *   This Source Code Form is subject to the terms of
 *   the Mozilla Public License, v. 2.0. If a copy of
 *   the MPL was not distributed with this file, You
 *   can obtain one at http://mozilla.org/MPL/2.0/.
 *
 * Authors:
 *   Stéphan Kochen <stephan@kochen.nl>
 *   Vladimir Panteleev <vladimir@thecybershadow.net>
 *   Simon Arlott
 */

module ae.net.http.common;

import core.time;

import std.string;
import std.conv;
import std.ascii;
import std.exception;
import std.datetime;

import ae.utils.text;
import ae.utils.array;
import ae.utils.time;
import ae.net.ietf.headers;
import ae.sys.data;
import zlib = ae.utils.zlib;
import gzip = ae.utils.gzip;

/// Base HTTP message class
private abstract class HttpMessage
{
public:
	string protocolVersion = "1.0";
	Headers headers;
	Data[] data;
	SysTime creationTime;

	this()
	{
		creationTime = Clock.currTime();
	}

	@property Duration age()
	{
		return Clock.currTime() - creationTime;
	}
}

/// HTTP request class
class HttpRequest : HttpMessage
{
public:
	string method = "GET";
	string proxy;

	this()
	{
	}

	this(string resource)
	{
		this.resource = resource;
	}

	/// Resource part of URL (everything after the hostname)
	@property string resource()
	{
		return _resource;
	}

	/// Setting the resource to a full URL will fill in the Host header, as well.
	@property void resource(string value)
	{
		_resource = value;

		// applies to both Client/Server as some clients put a full URL in the GET line instead of using a "Host" header
		if (_resource.length>7 && icmp(_resource[0 .. 7], "http://")==0)
		{
			auto pathstart = _resource[7 .. $].indexOf('/');
			if (pathstart == -1)
			{
				host = _resource[7 .. $];
				_resource = "/";
			}
			else
			{
				host = _resource[7 .. 7 + pathstart];
				_resource = _resource[7 + pathstart .. $];
			}
			auto portstart = host().indexOf(':');
			if (portstart != -1)
			{
				port = to!ushort(host[portstart+1..$]);
				host = host[0..portstart];
			}
		}
	}

	/// The hostname, without the port number
	@property string host()
	{
		string _host = headers.get("Host", null);
		auto colon = _host.lastIndexOf(":");
		return colon<0 ? _host : _host[0..colon];
	}

	@property void host(string _host)
	{
		auto _port = this.port;
		headers["Host"] = _port==80 ? _host : _host ~ ":" ~ text(_port);
	}

	/// Port number, from Host header (defaults to 80)
	@property ushort port()
	{
		if ("Host" in headers)
		{
			string _host = headers["Host"];
			auto colon = _host.lastIndexOf(":");
			return colon<0 ? 80 : to!ushort(_host[colon+1..$]);
		}
		else
			return _port;
	}

	@property void port(ushort _port)
	{
		if ("Host" in headers)
		{
			if (_port == 80)
				headers["Host"] = this.host;
			else
				headers["Host"] = this.host ~ ":" ~ text(_port);
		}
		else
			this._port = _port;
	}

	/// Path part of request (until the ?)
	@property string path()
	{
		auto p = resource.indexOf('?');
		if (p >= 0)
			return resource[0..p];
		else
			return resource;
	}

	/// Query string part of request (atfer the ?)
	@property string queryString()
	{
		auto p = resource.indexOf('?');
		if (p >= 0)
			return resource[p+1..$];
		else
			return null;
	}

	/// AA of query string parameters
	@property string[string] urlParameters()
	{
		return decodeUrlParameters(queryString);
	}

	/// Reconstruct full URL from host, port and resource
	@property string url()
	{
		return "http://" ~ host ~ (port==80 ? null : to!string(port)) ~ resource;
	}

	@property string proxyHost()
	{
		auto portstart = proxy.indexOf(':');
		if (portstart != -1)
			return proxy[0..portstart];
		return proxy;
	}

	@property ushort proxyPort()
	{
		auto portstart = proxy.indexOf(':');
		if (portstart != -1)
			return to!ushort(proxy[portstart+1..$]);
		return 80;
	}

	/// Parse the first line in a HTTP request ("METHOD /resource HTTP/1.x").
	void parseRequestLine(string reqLine)
	{
		enforce(reqLine.length > 10, "Request line too short");
		auto methodEnd = reqLine.indexOf(' ');
		enforce(methodEnd > 0, "Malformed request line");
		method = reqLine[0 .. methodEnd];
		reqLine = reqLine[methodEnd + 1 .. reqLine.length];

		auto resourceEnd = reqLine.lastIndexOf(' ');
		enforce(resourceEnd > 0, "Malformed request line");
		resource = reqLine[0 .. resourceEnd];

		string protocol = reqLine[resourceEnd+1..$];
		enforce(protocol.startsWith("HTTP/"));
		protocolVersion = protocol[5..$];
	}

	/// Decodes submitted form data, and returns an AA of values.
	string[string] decodePostData()
	{
		auto data = cast(string)data.joinToHeap();
		if (data.length is 0)
			return null;

		string contentType = headers.get("Content-Type", "");

		switch (contentType)
		{
			case "application/x-www-form-urlencoded":
				return decodeUrlParameters(data);
			case "":
				throw new Exception("No Content-Type");
			default:
				throw new Exception("Unknown Content-Type: " ~ contentType);
		}
	}

	/// Get list of hosts as specified in headers (e.g. X-Forwarded-For).
	/// First item in returned array is the node furthest away.
	/// Duplicates are removed.
	/// Specify socket remote address in remoteHost to add it to the list.
	string[] remoteHosts(string remoteHost = null)
	{
		return
			(headers.get("X-Forwarded-For", null).split(",").amap!strip() ~
			 headers.get("X-Forwarded-Host", null) ~
			 remoteHost)
			.afilter!`a`()
			.auniq();
	}

	unittest
	{
		auto req = new HttpRequest();
		assert(req.remoteHosts() == []);
		assert(req.remoteHosts("3.3.3.3") == ["3.3.3.3"]);

		req.headers["X-Forwarded-For"] = "1.1.1.1, 2.2.2.2";
		req.headers["X-Forwarded-Host"] = "2.2.2.2";
		assert(req.remoteHosts("3.3.3.3") == ["1.1.1.1", "2.2.2.2", "3.3.3.3"]);
	}

private:
	string _resource;
	ushort _port = 80; // used only when no "Host" in headers; otherwise, taken from there
}

/// HTTP response status codes
enum HttpStatusCode : ushort
{
	Continue=100,
	SwitchingProtocols=101,

	OK=200,
	Created=201,
	Accepted=202,
	NonAuthoritativeInformation=203,
	NoContent=204,
	ResetContent=205,
	PartialContent=206,

	MultipleChoices=300,
	MovedPermanently=301,
	Found=302,
	SeeOther=303,
	NotModified=304,
	UseProxy=305,
	//(Unused)=306,
	TemporaryRedirect=307,

	BadRequest=400,
	Unauthorized=401,
	PaymentRequired=402,
	Forbidden=403,
	NotFound=404,
	MethodNotAllowed=405,
	NotAcceptable=406,
	ProxyAuthenticationRequired=407,
	RequestTimeout=408,
	Conflict=409,
	Gone=410,
	LengthRequired=411,
	PreconditionFailed=412,
	RequestEntityTooLarge=413,
	RequestUriTooLong=414,
	UnsupportedMediaType=415,
	RequestedRangeNotSatisfiable=416,
	ExpectationFailed=417,

	InternalServerError=500,
	NotImplemented=501,
	BadGateway=502,
	ServiceUnavailable=503,
	GatewayTimeout=504,
	HttpVersionNotSupported=505
}

/// HTTP reply class
class HttpResponse : HttpMessage
{
public:
	ushort status;
	string statusMessage;

	int compressionLevel = 1;

	static string getStatusMessage(HttpStatusCode code)
	{
		switch(code)
		{
			case 100: return "Continue";
			case 101: return "Switching Protocols";

			case 200: return "OK";
			case 201: return "Created";
			case 202: return "Accepted";
			case 203: return "Non-Authoritative Information";
			case 204: return "No Content";
			case 205: return "Reset Content";
			case 206: return "Partial Content";
			case 300: return "Multiple Choices";
			case 301: return "Moved Permanently";
			case 302: return "Found";
			case 303: return "See Other";
			case 304: return "Not Modified";
			case 305: return "Use Proxy";
			case 306: return "(Unused)";
			case 307: return "Temporary Redirect";

			case 400: return "Bad Request";
			case 401: return "Unauthorized";
			case 402: return "Payment Required";
			case 403: return "Forbidden";
			case 404: return "Not Found";
			case 405: return "Method Not Allowed";
			case 406: return "Not Acceptable";
			case 407: return "Proxy Authentication Required";
			case 408: return "Request Timeout";
			case 409: return "Conflict";
			case 410: return "Gone";
			case 411: return "Length Required";
			case 412: return "Precondition Failed";
			case 413: return "Request Entity Too Large";
			case 414: return "Request-URI Too Long";
			case 415: return "Unsupported Media Type";
			case 416: return "Requested Range Not Satisfiable";
			case 417: return "Expectation Failed";

			case 500: return "Internal Server Error";
			case 501: return "Not Implemented";
			case 502: return "Bad Gateway";
			case 503: return "Service Unavailable";
			case 504: return "Gateway Timeout";
			case 505: return "HTTP Version Not Supported";
			default: return null;
		}
	}

	/// Set the response status code and message
	void setStatus(HttpStatusCode code)
	{
		status = code;
		statusMessage = getStatusMessage(code);
	}

	final void parseStatusLine(string statusLine)
	{
		auto versionEnd = statusLine.indexOf(' ');
		if (versionEnd == -1)
			throw new Exception("Malformed status line");
		protocolVersion = statusLine[0..versionEnd];
		statusLine = statusLine[versionEnd+1..statusLine.length];

		auto statusEnd = statusLine.indexOf(' ');
		if (statusEnd == -1)
			throw new Exception("Malformed status line");
		status = cast(HttpStatusCode)to!ushort(statusLine[0 .. statusEnd]);
		statusMessage = statusLine[statusEnd+1..statusLine.length];
	}

	/// If the data is compressed, return the decompressed data
	// this is not a property on purpose - to avoid using it multiple times as it will unpack the data on every access
	// TODO: there is no reason for above limitation
	Data getContent()
	{
		if ("Content-Encoding" in headers && headers["Content-Encoding"]=="deflate")
			return zlib.uncompress(data).joinData();
		else
		if ("Content-Encoding" in headers && headers["Content-Encoding"]=="gzip")
			return gzip.uncompress(data).joinData();
		else
			return data.joinData();
		assert(0);
	}

	protected void compressWithDeflate()
	{
		data = zlib.compress(data, zlib.ZlibOptions(compressionLevel));
	}

	protected void compressWithGzip()
	{
		data = gzip.compress(data, zlib.ZlibOptions(compressionLevel));
	}

	/// Called by the server to compress content, if possible/appropriate
	final package void optimizeData(string acceptEncoding)
	{
		if ("Content-Encoding" in headers)
			return; // data is already encoded
		auto contentType = headers.get("Content-Type", null);
		if (contentType.startsWith("text/") || contentType=="application/json")
		{
			auto supported = parseItemList(acceptEncoding) ~ ["*"];

			foreach (method; supported)
				switch (method)
				{
					case "deflate":
						headers["Content-Encoding"] = method;
						headers.add("Vary", "Accept-Encoding");
						compressWithDeflate();
						return;
					case "gzip":
						headers["Content-Encoding"] = method;
						headers.add("Vary", "Accept-Encoding");
						compressWithGzip();
						return;
					case "*":
						if("Content-Encoding" in headers)
							headers.remove("Content-Encoding");
						return;
					default:
						break;
				}
			assert(0);
		}
	}
}

void disableCache(ref Headers headers)
{
	headers["Expires"] = "Mon, 26 Jul 1997 05:00:00 GMT";  // disable IE caching
	//headers["Last-Modified"] = "" . gmdate( "D, d M Y H:i:s" ) . " GMT";
	headers["Cache-Control"] = "no-cache, must-revalidate";
	headers["Pragma"] = "no-cache";
}

void cacheForever(ref Headers headers)
{
	headers["Expires"] = httpTime(Clock.currTime().add!"years"(1));
	headers["Cache-Control"] = "public, max-age=31536000";
}

string httpTime(SysTime time)
{
	// Apache is bad at timezones
	time.timezone = UTC();
	return time.format!(TimeFormats.RFC2822)();
}

import std.algorithm : sort;

/// Parses a list in the format of "a, b, c;q=0.5, d" and returns
/// an array of items sorted by "q" (["a", "b", "d", "c"])
string[] parseItemList(string s)
{
	static struct Item
	{
		float q = 1.0;
		string str;

		this(string s)
		{
			auto params = s.split(";");
			if (!params.length) return;
			str = params[0];
			foreach (param; params[1..$])
				if (param.startsWith("q="))
					q = to!float(param[2..$]);
		}
	}

	return s
		.split(",")
		.amap!(a => Item(strip(a)))()
		.asort!`a.q > b.q`()
		.amap!`a.str`();
}

unittest
{
	assert(parseItemList("a, b, c;q=0.5, d") == ["a", "b", "d", "c"]);
}

// TODO: optimize / move to HtmlWriter
string httpEscape(string str)
{
	string result;
	foreach(c;str)
		switch(c)
		{
			case '<':
				result ~= "&lt;";
				break;
			case '>':
				result ~= "&gt;";
				break;
			case '&':
				result ~= "&amp;";
				break;
			case '\xDF':  // the beta-like symbol
				result ~= "&szlig;";
				break;
			default:
				result ~= [c];
		}
	return result;
}

string encodeUrlParameter(string param)
{
	string s;
	foreach (c; param)
		if (!isAlphaNum(c) && c!='-' && c!='_')
			s ~= format("%%%02X", cast(ubyte)c);
		else
			s ~= c;
	return s;
}

string encodeUrlParameters(string[string] dic)
{
	string[] segs;
	foreach (name, value; dic)
		segs ~= encodeUrlParameter(name) ~ '=' ~ encodeUrlParameter(value);
	return join(segs, "&");
}

string decodeUrlParameter(string encoded)
{
	string s;
	for (auto i=0; i<encoded.length; i++)
		if (encoded[i] == '%' && i+3 <= encoded.length)
		{
			s ~= cast(char)fromHex!ubyte(encoded[i+1..i+3]);
			i += 2;
		}
		else
		if (encoded[i] == '+')
			s ~= ' ';
		else
			s ~= encoded[i];
	return s;
}

string[string] decodeUrlParameters(string qs)
{
	string[] segs = split(qs, "&");
	string[string] dic;
	foreach (pair; segs)
	{
		auto p = pair.indexOf('=');
		if (p < 0)
			dic[decodeUrlParameter(pair)] = null;
		else
			dic[decodeUrlParameter(pair[0..p])] = decodeUrlParameter(pair[p+1..$]);
	}
	return dic;
}

struct MultipartPart
{
	string[string] headers;
	Data data;
}

Data encodeMultipart(MultipartPart[] parts, string boundary)
{
	Data data;
	foreach (ref part; parts)
	{
		data ~= "--" ~ boundary ~ "\r\n";
		foreach (name, value; part.headers)
			data ~= name ~ ": " ~ value ~ "\r\n";
		data ~= "\r\n";
		assert((cast(string)part.data.contents).indexOf(boundary) < 0);
		data ~= part.data;
	}
	data ~= "\r\n--" ~ boundary ~ "--\r\n";
	return data;
}
