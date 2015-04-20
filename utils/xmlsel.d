/**
 * ae.utils.xmlsel
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

module ae.utils.xmlsel;

import std.algorithm;
import std.exception;
import std.string;

import ae.utils.xmllite;

/// A slow and simple CSS "selector".
XmlNode[] find(XmlNode[] roots, string selector, bool allowEmpty = true)
{
	selector = selector.strip();
	while (selector.length)
	{
		bool recursive = true;
		if (selector[0] == '>')
		{
			recursive = false;
			selector = selector[1..$].stripLeft();
		}

		string spec = selector; selector = null;
		foreach (i, c; spec)
			if (c == ' ' || c == '>')
			{
				selector = spec[i..$].stripLeft();
				spec = spec[0..i];
				break;
			}

		string tag, id, cls;

		string* tgt = &tag;
		foreach (c; spec)
			if (c == '.')
				tgt = &cls;
			else
			if (c == '#')
				tgt = &id;
			else
				*tgt ~= c;
		if (tag == "*")
			tag = null;

		XmlNode[] findSpec(XmlNode n)
		{
			XmlNode[] result;
			foreach (c; n.children)
				if (c.type == XmlNodeType.Node)
				{
					if (tag && c.tag != tag)
						goto wrong;
					if (id && c.attributes.get("id", null) != id)
						goto wrong;
					if (cls && !c.attributes.get("class", null).split().canFind(cls))
						goto wrong;
					result ~= c;

				wrong:
					if (recursive)
						result ~= findSpec(c);
				}
			return result;
		}

		XmlNode[] newRoots;

		foreach (root; roots)
			newRoots ~= findSpec(root);
		roots = newRoots;
		if (!allowEmpty)
			enforce(roots.length, "Can't find " ~ spec);
	}

	return roots;
}

XmlNode find(XmlNode roots, string selector)
{
	return find([roots], selector, false)[0];
}

XmlNode[] findAll(XmlNode roots, string selector)
{
	return find([roots], selector);
}

unittest
{
	enum xmlText =
		`<doc>`
			`<test>Test 1</test>`
			`<node id="test2">Test 2</node>`
			`<node class="test3">Test 3</node>`
		`</doc>`;
	auto doc = xmlText.xmlParse();
	assert(doc.find("test"  ).text == "Test 1");
	assert(doc.find("#test2").text == "Test 2");
	assert(doc.find(".test3").text == "Test 3");

	assert(doc.find("doc test").text == "Test 1");
	assert(doc.find("doc>test").text == "Test 1");
	assert(doc.find("doc> test").text == "Test 1");
	assert(doc.find("doc >test").text == "Test 1");
	assert(doc.find("doc > test").text == "Test 1");

	assert(![doc].find("foo").length);
	assert(![doc].find("#foo").length);
	assert(![doc].find(".foo").length);
	assert(![doc].find("doc foo").length);
	assert(![doc].find("foo test").length);
}
