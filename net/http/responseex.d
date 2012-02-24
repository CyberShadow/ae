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
 *   Vladimir Panteleev <vladimir@thecybershadow.net>
 *   Simon Arlott
 */

module ae.net.http.responseex;

import std.string;
import std.conv;
import std.file;
import std.path;
import std.datetime;

public import ae.net.http.common;
import ae.sys.data;
import ae.sys.dataio;
import ae.utils.json;
import ae.utils.xml;
import ae.utils.time;
import ae.utils.mime;

/// HttpResponse with some code to ease creating responses
final class HttpResponseEx : HttpResponse
{
public:
	/// Set the response status code and message
	void setStatus(HttpStatusCode code)
	{
		status = code;
		statusMessage = getStatusMessage(code);
	}

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

	HttpResponseEx serveData(Data data, string contentType)
	{
		setStatus(HttpStatusCode.OK);
		headers["Content-Type"] = contentType;
		this.data = data;
		return this;
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

	static bool checkPath(string file)
	{
		if (file.length && (file.indexOf("..") != -1 || file[0]=='/' || file[0]=='\\' || file.indexOf("//") != -1 || file.indexOf("\\\\") != -1))
			return false;
		return true;
	}

	static string httpTime(SysTime time)
	{
		// Apache is bad at timezones
		time.timezone = UTC();
		return formatTime(TimeFormats.RFC2822, time);
	}

	/// Send a file from the disk
	HttpResponseEx serveFile(string file, string location, bool enableIndex = false)
	{
		if (!checkPath(file))
		{
			writeError(HttpStatusCode.Forbidden);
			return this;
		}

		string filename = location ~ file;

		if ((filename=="" || isDir(filename)))
		{
			if (filename.length && !filename.endsWith("/"))
				return redirect(filename ~ "/");
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
				string title = `Directory listing of /` ~ encodeEntities(file);
				string html = `<ul>`;
				foreach (DirEntry de; dirEntries(filename, SpanMode.shallow))
				{
					string basefilename = baseName(encodeEntities(de.name));
					if (de.isDir)
						html ~= `<li><a href="` ~ basefilename ~ `/">` ~ basefilename ~ `/</a></li>`;
					else
						html ~= `<li><a href="` ~ basefilename ~ `">` ~ basefilename ~ `</a></li>`;
				}
				html ~= `</ul>`;
				writePage(title, html);
				return this;
			}
		}

		if (!exists(filename) || !isFile(filename))
		{
			writeError(HttpStatusCode.NotFound);
			return this;
		}

		auto mimeType = guessMime(filename);
		if (mimeType)
			headers["Content-Type"] = mimeType;

		setStatus(HttpStatusCode.OK);
		data = readData(filename);
		headers["Last-Modified"] = httpTime(timeLastModified(filename));
		return this;
	}

	static string loadTemplate(string filename, string[string] dictionary)
	{
		return parseTemplate(readText(filename), dictionary);
	}

	static string parseTemplate(string data, string[string] dictionary)
	{
		import ae.utils.textout;
		StringBuilder sb;
		for(;;)
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
		string[string] dictionary;
		dictionary["title"] = encodeEntities(title);
		dictionary["content"] = contentHTML;
		data = Data(parseTemplate(pageTemplate, dictionary));
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

			case 500: return "An unexpected error has occured within the server software.";
			case 501: return "The resource you are trying to access represents an unimplemented functionality.";
			default: return "";
		}
	}

	HttpResponseEx writeError(HttpStatusCode code, string details=null)
	{
		setStatus(code);

		string[string] dictionary;
		dictionary["code"] = to!string(cast(int)code);
		dictionary["message"] = encodeEntities(getStatusMessage(code));
		dictionary["explanation"] = encodeEntities(getStatusExplanation(code));
		dictionary["details"] = details ? "Error details:<br/><strong>" ~ encodeEntities(details) ~ "</strong>"  : "";
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
		headers["Expires"] = "Mon, 26 Jul 1997 05:00:00 GMT";  // disable IE caching
		//headers["Last-Modified"] = "" . gmdate( "D, d M Y H:i:s" ) . " GMT";
		headers["Cache-Control"] = "no-cache, must-revalidate";
		headers["Pragma"] = "no-cache";
	}

	void cacheForever()
	{
		headers["Expires"] = httpTime(Clock.currTime().add!"years"(1));
		headers["Cache-Control"] = "public, max-age=31536000";
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

	static contentTemplate =
`    <p><span style="font-weight: bold; font-size: 40px;"><?title?></span></p>
<?content?>
`;

	static errorTemplate =
`    <p><span style="font-weight: bold; font-size: 40px;"><span style="color: #FF0000; font-size: 100px;"><?code?></span>(<?message?>)</span></p>
    <p><?explanation?></p>
    <p><?details?></p>
`;
}
