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

/// Returns `true` if node `n` is a tag, and its tag name is `tag`.
bool isTag(XmlNode n, string tag, XmlNodeType type = XmlNodeType.Node)
{
	return n.type == type && n.tag ==  tag;
}

/// Like `isTag`, but if `n` does not satisfy the criteria and it has one child node,
/// check it recursively instead. Returns the satisfying node or `null`.
XmlNode findOnlyChild(XmlNode n, string tag, XmlNodeType type = XmlNodeType.Node)
{
	return n.isTag(tag, type) ? n :
		n.children.length != 1 ? null :
		n.children[0].findOnlyChild(tag, type);
}

/// ditto
XmlNode findOnlyChild(XmlNode n, XmlNodeType type)
{
	return n.type == type ? n :
		n.children.length != 1 ? null :
		n.children[0].findOnlyChild(type);
}

/// Search recursively for all nodes which are tags and have the tag name `tag`.
XmlNode[] findNodes(XmlNode n, string tag)
{
	if (n.isTag(tag))
		return [n];
	return n.children.map!(n => findNodes(n, tag)).join;
}

/// Create a new node with the given properties.
XmlNode newNode(XmlNodeType type, string tag, string[string] attributes = null, XmlNode[] children = null)
{
	auto node = new XmlNode(type, tag);
	node.attributes = attributes;
	node.children = children;
	return node;
}

/// Create a tag new node with the given properties.
XmlNode newNode(string tag, string[string] attributes = null, XmlNode[] children = null)
{
	return newNode(XmlNodeType.Node, tag, attributes, children);
}

/// Create a text node with the given contents.
XmlNode newTextNode(string text)
{
	return newNode(XmlNodeType.Text, text);
}
