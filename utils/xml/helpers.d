/**
 * Useful ae.utils.xml helpers
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

module ae.utils.xml.helpers;

import std.algorithm.iteration;
import std.array;

import ae.utils.xml.lite;

bool isTag(XmlNode n, string tag, XmlNodeType type = XmlNodeType.Node)
{
	return n.type == type && n.tag ==  tag;
}

XmlNode findOnlyChild(XmlNode n, string tag, XmlNodeType type = XmlNodeType.Node)
{
	return n.isTag(tag, type) ? n :
		n.children.length != 1 ? null :
		n.children[0].findOnlyChild(tag, type);
}

XmlNode findOnlyChild(XmlNode n, XmlNodeType type)
{
	return n.type == type ? n :
		n.children.length != 1 ? null :
		n.children[0].findOnlyChild(type);
}

XmlNode[] findNodes(XmlNode n, string tag)
{
	if (n.isTag(tag))
		return [n];
	return n.children.map!(n => findNodes(n, tag)).join;
}

XmlNode newNode(XmlNodeType type, string tag, string[string] attributes = null, XmlNode[] children = null)
{
	auto node = new XmlNode(type, tag);
	node.attributes = attributes;
	node.children = children;
	return node;
}

XmlNode newNode(string tag, string[string] attributes = null, XmlNode[] children = null)
{
	return newNode(XmlNodeType.Node, tag, attributes, children);
}

XmlNode newTextNode(string text)
{
	return newNode(XmlNodeType.Text, text);
}
