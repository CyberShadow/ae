/**
 * An improved HttpResponse class to ease writing pages.
 *
 * License:
 *   This Source Code Form is subject to the terms of
 *   the Mozilla Public License, v. 2.0. If a copy of
 *   the MPL was not distributed with this file, You
 *   can obtain one at http://mozilla.org/MPL/2.0/.
 *
 * Authors:
 *   Vladimir Panteleev <ae@cy.md>
 *   Simon Arlott
 */

module ae.net.http.responseex;

import std.algorithm.searching : skipOver, findSplit;
import std.base64;
import std.exception;
import std.string;
import std.conv;
import std.file;
import std.path;

public import ae.net.http.common;
import ae.net.ietf.headers;
import ae.sys.data;
import ae.sys.dataio;
import ae.utils.array;
import ae.utils.json;
import ae.utils.xml;
import ae.utils.text;
import ae.utils.mime;

/// HttpResponse with some code to ease creating responses
final class HttpResponseEx : HttpResponse
{
public:
	/// Redirect the UA to another location
	HttpResponseEx redirect(string location, HttpStatusCode status = HttpStatusCode.SeeOther)
	{
		setStatus(status);
		headers["Location"] = location;
		return this;
	}

	HttpResponseEx serveData(string data, string contentType = "text/html; charset=utf-8")
	{
		return serveData(Data(data), contentType);
	}

	HttpResponseEx serveData(Data[] data, string contentType)
	{
		setStatus(HttpStatusCode.OK);
		headers["Content-Type"] = contentType;
		this.data = data;
		return this;
	}

	HttpResponseEx serveData(Data data, string contentType)
	{
		return serveData([data], contentType);
	}

	string jsonCallback;
	HttpResponseEx serveJson(T)(T v)
	{
		string data = toJson(v);
		if (jsonCallback)
			return serveData(jsonCallback~'('~data~')', "text/javascript");
		else
			return serveData(data, "application/json");
	}

	HttpResponseEx serveText(string data)
	{
		return serveData(Data(data), "text/plain; charset=utf-8");
	}

	static bool checkPath(string path)
	{
		if (!path.length)
			return true;
		if (path.contains("..") || path[0]=='/' || path[0]=='\\' || path.contains("//") || path.contains("\\\\"))
			return false;
		return true;
	}

	static void detectMime(string name, ref Headers headers)
	{
		// Special case: .svgz
		if (name.endsWith(".svgz"))
			name = name[0 .. $ - 1] ~ ".gz";

		if (name.endsWith(".gz"))
		{
			auto mimeType = guessMime(name[0 .. $-3]);
			if (mimeType)
			{
				headers["Content-Type"] = mimeType;
				headers["Content-Encoding"] = "gzip";
				return;
			}
		}

		auto mimeType = guessMime(name);
		if (mimeType)
			headers["Content-Type"] = mimeType;
	}

	/// Send a file from the disk
	HttpResponseEx serveFile(string path, string fsBase, bool enableIndex = false, string urlBase="/")
	{
		if (!checkPath(path))
		{
			writeError(HttpStatusCode.Forbidden);
			return this;
		}

		assert(fsBase == "" || fsBase.endsWith("/"), "Invalid fsBase specified to serveFile");
		assert(urlBase.endsWith("/"), "Invalid urlBase specified to serveFile");

		string filename = fsBase ~ path;

		if (filename == "" || (filename.exists && filename.isDir))
		{
			if (filename.length && !filename.endsWith("/"))
				return redirect("/" ~ path ~ "/");
			else
			if (exists(filename ~ "index.html"))
				filename ~= "index.html";
			else
			if (!enableIndex)
			{
				writeError(HttpStatusCode.Forbidden);
				return this;
			}
			else
			{
				path = path.length ? path[0..$-1] : path;
				string title = `Directory listing of ` ~ encodeEntities(path=="" ? "/" : baseName(path));

				auto segments = [urlBase[0..$-1]] ~ path.split("/");
				string segmentUrl;
				string html;
				foreach (i, segment; segments)
				{
					segmentUrl ~= (i ? encodeUrlParameter(segment) : segment) ~ "/";
					html ~= `<a style="margin-left: 5px" href="` ~ segmentUrl ~ `">` ~ encodeEntities(segment) ~ `/</a>`;
				}

				html ~= `<ul>`;
				foreach (DirEntry de; dirEntries(filename, SpanMode.shallow))
				{
					auto name = baseName(de.name);
					auto suffix = de.isDir ? "/" : "";
					html ~= `<li><a href="` ~ encodeUrlParameter(name) ~ suffix ~ `">` ~ encodeEntities(name) ~ suffix ~ `</a></li>`;
				}
				html ~= `</ul>`;
				setStatus(HttpStatusCode.OK);
				writePage(title, html);
				return this;
			}
		}

		if (!exists(filename) || !isFile(filename))
		{
			writeError(HttpStatusCode.NotFound);
			return this;
		}

		detectMime(filename, headers);

		headers["Last-Modified"] = httpTime(timeLastModified(filename));
		//data = [mapFile(filename, MmMode.read)];
		data = [readData(filename)];
		setStatus(HttpStatusCode.OK);
		return this;
	}

	static string loadTemplate(string filename, string[string] dictionary)
	{
		return parseTemplate(readText(filename), dictionary);
	}

	static string parseTemplate(string data, string[string] dictionary)
	{
		import ae.utils.textout : StringBuilder;
		StringBuilder sb;
		while (true)
		{
			auto startpos = data.indexOf("<?");
			if(startpos==-1)
				break;
			auto endpos = data.indexOf("?>");
			if (endpos<startpos+2)
				throw new Exception("Bad syntax in template");
			string token = data[startpos+2 .. endpos];
			auto pvalue = token in dictionary;
			if(!pvalue)
				throw new Exception("Unrecognized token: " ~ token);
			sb.put(data[0 .. startpos], *pvalue);
			data = data[endpos+2 .. $];
		}
		sb.put(data);
		return sb.get();
	}

	void writePageContents(string title, string contentHTML)
	{
		string[string] dictionary = pageTokens.dup;
		dictionary["title"] = encodeEntities(title);
		dictionary["content"] = contentHTML;
		data = [Data(parseTemplate(pageTemplate, dictionary))];
		headers["Content-Type"] = "text/html; charset=utf-8";
	}

	void writePage(string title, string[] html ...)
	{
		if (!status)
			status = HttpStatusCode.OK;

		string content;
		foreach (string p; html)
			content ~= "<p>" ~ p ~ "</p>\n";

		string[string] dictionary;
		dictionary["title"] = encodeEntities(title);
		dictionary["content"] = content;
		writePageContents(title, parseTemplate(contentTemplate, dictionary));
	}

	static string getStatusExplanation(HttpStatusCode code)
	{
		switch(code)
		{
			case 400: return "The request could not be understood by the server due to malformed syntax.";
			case 401: return "You are not authorized to access this resource.";
			case 403: return "You have tried to access a restricted or unavailable resource, or attempted to circumvent server security.";
			case 404: return "The resource you are trying to access does not exist on the server.";
			case 405: return "The resource you are trying to access is not available using the method used in this request.";

			case 500: return "An unexpected error has occured within the server software.";
			case 501: return "The resource you are trying to access represents unimplemented functionality.";
			default: return "";
		}
	}

	HttpResponseEx writeError(HttpStatusCode code, string details=null)
	{
		setStatus(code);

		string[string] dictionary = errorTokens.dup;
		dictionary["code"] = to!string(cast(int)code);
		dictionary["message"] = encodeEntities(getStatusMessage(code));
		dictionary["explanation"] = encodeEntities(getStatusExplanation(code));
		dictionary["details"] = details ? "Error details:<br/><pre>" ~ encodeEntities(details) ~ "</pre>"  : "";
		string title = to!string(cast(int)code) ~ " - " ~ getStatusMessage(code);
		string html = parseTemplate(errorTemplate, dictionary);

		writePageContents(title, html);
		return this;
	}

	void setRefresh(int seconds, string location=null)
	{
		auto refresh = to!string(seconds);
		if (location)
			refresh ~= ";URL=" ~ location;
		headers["Refresh"] = refresh;
	}

	void disableCache()
	{
		.disableCache(headers);
	}

	void cacheForever()
	{
		.cacheForever(headers);
	}

	HttpResponseEx dup()
	{
		auto c = new HttpResponseEx;
		c.status = this.status;
		c.statusMessage = this.statusMessage;
		c.headers = this.headers.dup;
		c.data = this.data.dup;
		return c;
	}

	/**
	   Usage:
	   ---
	   if (!response.authorize(request,
	                           (username, password) => username == "JohnSmith" && password == "hunter2"))
	       return conn.serveResponse(response);
	   ---
	*/
	bool authorize(HttpRequest request, bool delegate(string username, string password) authenticator)
	{
		bool check()
		{
			auto authorization = request.headers.get("Authorization", null);
			if (!authorization)
				return false; // No authorization header
			if (!authorization.skipOver("Basic "))
				return false; // Unknown authentication algorithm
			try
				authorization = cast(string)Base64.decode(authorization);
			catch (Base64Exception)
				return false; // Bad encoding
			auto parts = authorization.findSplit(":");
			if (!parts[1].length)
				return false; // Bad username/password formatting
			auto username = parts[0];
			auto password = parts[2];
			if (!authenticator(username, password))
				return false; // Unknown username/password
			return true;
		}

		if (!check())
		{
			headers["WWW-Authenticate"] = `Basic`;
			writeError(HttpStatusCode.Unauthorized);
			return false;
		}
		return true;
	}

	static pageTemplate =
`<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Strict//EN" "http://www.w3.org/TR/xhtml1/DTD/xhtml1-strict.dtd">

<html xmlns="http://www.w3.org/1999/xhtml" xml:lang="en" lang="en">
  <head>
    <title><?title?></title>
    <meta http-equiv="Content-Type" content="text/html; charset=utf-8"/>
    <style type="text/css">
      body
      {
        padding: 0;
        margin: 0;
        border-width: 0;
        font-family: Tahoma, sans-serif;
      }
    </style>
  </head>
  <body>
   <div style="background-color: #FFBFBF; width: 100%; height: 75px;">
    <div style="position: relative; left: 150px; width: 300px; color: black; font-weight: bold; font-size: 30px;">
     <span style="color: #FF0000; font-size: 65px;">D</span>HTTP
    </div>
   </div>
   <div style="background-color: #FFC7C7; width: 100%; height: 4px;"></div>
   <div style="background-color: #FFCFCF; width: 100%; height: 4px;"></div>
   <div style="background-color: #FFD7D7; width: 100%; height: 4px;"></div>
   <div style="background-color: #FFDFDF; width: 100%; height: 4px;"></div>
   <div style="background-color: #FFE7E7; width: 100%; height: 4px;"></div>
   <div style="background-color: #FFEFEF; width: 100%; height: 4px;"></div>
   <div style="background-color: #FFF7F7; width: 100%; height: 4px;"></div>
   <div style="position: relative; top: 40px; left: 10%; width: 80%;">
<?content?>
   </div>
  </body>
</html>`;

	string[string] pageTokens;

	static contentTemplate =
`    <p><span style="font-weight: bold; font-size: 40px;"><?title?></span></p>
<?content?>
`;

	static errorTemplate =
`    <p><span style="font-weight: bold; font-size: 40px;"><span style="color: #FF0000; font-size: 100px;"><?code?></span>(<?message?>)</span></p>
    <p><?explanation?></p>
    <p><?details?></p>
`;
	string[string] errorTokens;
}
