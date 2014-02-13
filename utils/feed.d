/**
 * RSS/ATOM feed generation
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

module ae.utils.feed;

import std.datetime;

import ae.utils.xmlwriter;
import ae.utils.time;

/// ATOM writer
struct AtomFeedWriter
{
	XmlWriter xml;

	private void putTag(string name)(string content)
	{
		xml.startTag!name();
		xml.text(content);
		xml.endTag!name();
	}

	private void putTimeTag(string name)(SysTime time)
	{
		xml.startTag!name();
		.putTime!(TimeFormats.ATOM)(xml.output, time);
		xml.endTag!name();
	}

	void startFeed(string feedUrl, string title, SysTime updated)
	{
		xml.startDocument();

		xml.startTagWithAttributes!"feed"();
		xml.addAttribute!"xmlns"("http://www.w3.org/2005/Atom");
		xml.endAttributes();

		xml.startTagWithAttributes!"link"();
		xml.addAttribute!"rel"("self");
		xml.addAttribute!"type"("application/atom+xml");
		xml.addAttribute!"href"(feedUrl);
		xml.endAttributesAndTag();

		putTag!"id"(feedUrl);
		putTag!"title"(title);
		putTimeTag!"updated"(updated);
	}

	void putEntry(string url, string title, string authorName, SysTime time, string contentHtml, string link=null)
	{
		xml.startTag!"entry"();

		putTag!"id"(url);
		putTag!"title"(title);
		putTimeTag!"published"(time);
		putTimeTag!"updated"(time);

		xml.startTag!"author"();
		putTag!"name"(authorName);
		xml.endTag!"author"();

		if (link)
		{
			xml.startTagWithAttributes!"link"();
			xml.addAttribute!"href"(link);
			xml.endAttributesAndTag();
		}

		xml.startTagWithAttributes!"content"();
		xml.addAttribute!"type"("html");
		xml.endAttributes();
		xml.text(contentHtml);
		xml.endTag!"content"();

		xml.endTag!"entry"();
	}

	void endFeed()
	{
		xml.endTag!"feed"();
	}
}
