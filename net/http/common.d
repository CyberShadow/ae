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

import std.string, std.conv, std.ascii;
import std.exception;

import ae.utils.text;
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
	Data data;
}

/// HTTP request class
class HttpRequest : HttpMessage
{
public:
	string method = "GET";
	string proxy;
	ushort port = 80; // client only

	this()
	{
	}

	this(string resource)
	{
		this.resource = resource;
	}

	@property string resource()
	{
		return resource_;
	}

	@property void resource(string value)
	{
		resource_ = value;

		// applies to both Client/Server as some clients put a full URL in the GET line instead of using a "Host" header
		if (resource_.length>7 && resource_[0 .. 7] == "http://")
		{
			auto pathstart = resource_[7 .. $].indexOf('/');
			if (pathstart == -1)
			{
				host = resource_[7 .. $];
				resource_ = "/";
			}
			else
			{
				host = resource_[7 .. 7 + pathstart];
				resource_ = resource_[7 + pathstart .. $];
			}
			auto portstart = host().indexOf(':');
			if (portstart != -1)
			{
				port = to!ushort(host[portstart+1..$]);
				host = host[0..portstart];
			}
		}
	}

	@property string host()
	{
		return headers["Host"];
	}

	@property void host(string value)
	{
		headers["Host"] = value;
	}

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

	string[string] decodePostData()
	{
		auto data = (cast(string)data.contents).idup;
		if (data.length is 0)
			return null;

		string contentType;
		foreach (header, value; headers)
			if (icmp(header, "Content-Type")==0)
				contentType = value;
		if (contentType is null)
			throw new Exception("Can't get content type header");

		switch (contentType)
		{
			case "application/x-www-form-urlencoded":
				return decodeUrlParameters(data);
			default:
				throw new Exception("Unknown Content-Type: " ~ contentType);
		}
	}

private:
	string resource_;
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
			default: return "";
		}
	}

	/// If the data is compressed, return the decompressed data
	// this is not a property on purpose - to avoid using it multiple times as it will unpack the data on every access
	Data getContent()
	{
		if ("Content-Encoding" in headers && headers["Content-Encoding"]=="deflate")
			return zlib.uncompress(data);
		else
		if ("Content-Encoding" in headers && headers["Content-Encoding"]=="gzip")
			return gzip.uncompress(data);
		else
			return data;
		assert(0);
	}

	void setContent(Data content, string[] supported)
	{
		foreach(method;supported ~ ["*"])
			switch(method)
			{
				case "deflate":
					headers["Content-Encoding"] = method;
					headers.add("Vary", "Accept-Encoding");
					data = zlib.compress(content);
					return;
				case "gzip":
					headers["Content-Encoding"] = method;
					headers.add("Vary", "Accept-Encoding");
					data = gzip.compress(content);
					return;
				case "*":
					if("Content-Encoding" in headers)
						headers.remove("Content-Encoding");
					data = content;
					return;
				default:
					break;
			}
		assert(0);
	}

	/// called by the server to compress content if possible
	void compress(string acceptEncoding)
	{
		auto contentType = "Content-Type" in headers ? headers["Content-Type"] : null;
		if (!contentType.startsWith("text/") && contentType!="application/json")
			return;
		if ("Content-Encoding" in headers)
			return;
		setContent(data, parseItemList(acceptEncoding));
	}
}

/// parses a list in the format of "a, b, c;q=0.5, d" and returns an array of items sorted by "q" (["a", "b", "d", "c"])
// NOTE: this code is crap.
string[] parseItemList(string s)
{
	string[] items = s.split(",");
	foreach(ref item;items)
		item = strip(item);

	struct Item
	{
		float q=1.0;
		string str;

		int opCmp(Item* i)
		{
			if(q<i.q) return  1;
			else
			if(q>i.q) return -1;
			else      return  0;
		}

		static Item opCall(string s)
		{
			Item i;
			sizediff_t p;
			while((p=s.lastIndexOf(';'))!=-1)
			{
				string param = s[p+1..$];
				s = strip(s[0..p]);
				auto p2 = param.indexOf('=');
				assert(p2!=-1);
				string name=strip(param[0..p2]), value=strip(param[p2+1..$]);
				switch(name)
				{
					case "q":
						i.q = to!float(value);
						break;
					default:
					// fail on unsupported
				}
			}
			i.str = s;
			return i;
		}
	}

	Item[] structs;
	foreach(item;items)
		structs ~= [Item(item)];
	structs.sort;
	string[] result;
	foreach(item;structs)
		result ~= [item.str];
	return result;
}

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

unittest
{
	assert(parseItemList("a, b, c;q=0.5, d") == ["a", "b", "d", "c"]);
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
	for (int i=0; i<encoded.length; i++)
		if (encoded[i] == '%')
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
