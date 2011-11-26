/* ***** BEGIN LICENSE BLOCK *****
 * Version: MPL 1.1/GPL 3.0
 *
 * The contents of this file are subject to the Mozilla Public License Version
 * 1.1 (the "License"); you may not use this file except in compliance with
 * the License. You may obtain a copy of the License at
 * http://www.mozilla.org/MPL/
 *
 * Software distributed under the License is distributed on an "AS IS" basis,
 * WITHOUT WARRANTY OF ANY KIND, either express or implied. See the License
 * for the specific language governing rights and limitations under the
 * License.
 *
 * The Original Code is the Team15 library.
 *
 * The Initial Developer of the Original Code is
 * Vladimir Panteleev <vladimir@thecybershadow.net>
 * Portions created by the Initial Developer are Copyright (C) 2006-2011
 * the Initial Developer. All Rights Reserved.
 *
 * Contributor(s):
 *   Simon Arlott
 *
 * Alternatively, the contents of this file may be used under the terms of the
 * GNU General Public License Version 3 (the "GPL") or later, in which case
 * the provisions of the GPL are applicable instead of those above. If you
 * wish to allow use of your version of this file only under the terms of the
 * GPL, and not to allow others to use your version of this file under the
 * terms of the MPL, indicate your decision by deleting the provisions above
 * and replace them with the notice and other provisions required by the GPL.
 * If you do not delete the provisions above, a recipient may use your version
 * of this file under the terms of either the MPL or the GPL.
 *
 * ***** END LICENSE BLOCK ***** */

/// An improved HttpResponse class to ease writing pages.
module ae.net.http.responseex;

import std.string;
import std.conv;
import std.file;
import std.path;

public import ae.net.http.common;
import ae.sys.data;
import ae.sys.dataio;
import ae.utils.json;
import ae.utils.xml;

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

	HttpResponseEx serveData(string data, string contentType = "text/html")
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
		return serveData(Data(data), "text/plain");
	}

	static bool checkPath(string file)
	{
		if (file.length && (file.indexOf("..") != -1 || file[0]=='/' || file[0]=='\\' || file.indexOf("//") != -1 || file.indexOf("\\\\") != -1))
			return false;
		return true;
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
					html ~= `<li><a href="` ~ encodeEntities(de.name) ~ `">` ~ encodeEntities(de.name) ~ `</a></li>`;
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

		setStatus(HttpStatusCode.OK);
		switch (toLower(extension(filename)))
		{
			case ".txt":
				headers["Content-Type"] = "text/plain";
				break;
			case ".htm":
			case ".html":
				headers["Content-Type"] = "text/html";
				break;
			case ".js":
				headers["Content-Type"] = "text/javascript";
				break;
			case ".css":
				headers["Content-Type"] = "text/css";
				break;
			case ".png":
				headers["Content-Type"] = "image/png";
				break;
			case ".gif":
				headers["Content-Type"] = "image/gif";
				break;
			case ".jpg":
			case ".jpeg":
				headers["Content-Type"] = "image/jpeg";
				break;
			case ".ico":
				headers["Content-Type"] = "image/vnd.microsoft.icon";
				break;
			default:
				// let the UA decide
				break;
		}
		data = readData(filename);
		return this;
	}

	static string loadTemplate(string filename, string[string] dictionary)
	{
		return parseTemplate(readText(filename), dictionary);
	}

	static string parseTemplate(string data, string[string] dictionary)
	{
		for(;;)
		{
			auto startpos = data.indexOf("<?");
			if(startpos==-1)
				return data;
			auto endpos = data[startpos .. $].indexOf("?>");
			if(endpos<2)
				throw new Exception("Bad syntax in template");
			string token = data[startpos+2 .. startpos+endpos];
			if(!(token in dictionary))
				throw new Exception("Unrecognized token: " ~ token);
			data = data[0 .. startpos] ~ dictionary[token] ~ data[startpos+endpos+2 .. $];
		}
	}

	void writePageContents(string title, string content)
	{
		string[string] dictionary;
		dictionary["title"] = title;
		dictionary["content"] = content;
		data = Data(parseTemplate(pageTemplate, dictionary));
		headers["Content-Type"] = "text/html";
	}

	void writePage(string title, string[] text ...)
	{
		if (!status)
			status = HttpStatusCode.OK;

		string content;
		foreach (string p; text)
			content ~= "<p>" ~ p ~ "</p>\n";

		string[string] dictionary;
		dictionary["title"] = title;
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
		dictionary["message"] = getStatusMessage(code);
		dictionary["explanation"] = getStatusExplanation(code);
		dictionary["details"] = details ? "Error details:<br/><strong>" ~ details ~ "</strong>"  : "";
		string data = parseTemplate(errorTemplate, dictionary);

		writePageContents(to!string(cast(int)code) ~ " - " ~ getStatusMessage(code), data);
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
		// Better stay within the UNIX epoch.
		// TODO: update or properly fix this by 2030
		headers["Expires"] = "Wed, 01 Jan 2030 00:00:00 GMT";
	}

	static pageTemplate =
`<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Strict//EN" "http://www.w3.org/TR/xhtml1/DTD/xhtml1-strict.dtd">

<html xmlns="http://www.w3.org/1999/xhtml" xml:lang="en" lang="en">
  <head>
    <title><?title?></title>
    <meta http-equiv="Content-Type" content="text/html; charset=iso-8859-1"/>
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
