/**
 * XmlParser client which builds a DOM efficiently.
 * WORK IN PROGRESS.
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

module ae.utils.xmldom;

import std.exception;

import ae.utils.xmlparser;
import ae.utils.alloc;

enum XmlNodeType
{
	root,
	tag,
	attribute,
	directive,
	processingInstruction,
	text
}


struct XmlDom(STRING=string, XML_STRING=XmlString!STRING)
{
	struct Node
	{
		XmlNodeType type;
		union
		{
			STRING tag;
			alias tag attributeName;
			XML_STRING text;
		}
		union
		{
			XML_STRING attributeValue; /// Attribute tags only
			Node* firstChild; /// Non-attribute tags only
		}
		Node* nextSibling;
		Node* parent;
	}

	Node* root;

	struct Cursor
	{
		Node* currentParent, currentSibling;

		void descend()
		{
			assert(currentSibling, "Nowhere to descend to");
			currentParent = currentSibling;
			//currentSibling = null;
			currentSibling = currentSibling.firstChild;
		}

		void ascend()
		{
			assert(currentParent, "Nowhere to ascend to");
			currentSibling = currentParent;
			currentParent = currentSibling.parent;
		}

		void insertNode(Node* n)
		{
			n.parent = currentParent;
			auto pNext = currentSibling ? &currentSibling.nextSibling : &currentParent.firstChild;
			n.nextSibling = *pNext;
		}

		/// Assumes we are at the last sibling
		void appendNode(Node* n)
		{
			n.parent = currentParent;
			n.nextSibling = null;
			auto pNext = currentSibling ? &currentSibling.nextSibling : &currentParent.firstChild;
			assert(*pNext, "Cannot append when not at the last sibling");
			currentSibling = *pNext = n;
		}

		@property bool empty() { return currentSibling !is null; }
		alias currentSibling front;
		void popFront() { currentSibling = currentSibling.nextSibling; }
	}

	Cursor getCursor()
	{
		assert(root, "No root node");
		Cursor cursor;
		cursor.currentParent = root;
		cursor.currentSibling = null;
		return cursor;
	}
}

struct XmlDomWriter(DOM_, alias ALLOCATOR=HeapAllocator)
{
	alias DOM_ DOM;

	DOM dom;

	alias DOM.Node Node;

	ALLOCATOR!Node allocator;

	private Node* newNode()
	{
		auto n = allocator.allocate();
		n.nextSibling = null;
		return n;
	}

	DOM.Cursor newDocument()
	{
		with (*(dom.root = newNode()))
			type = XmlNodeType.root,
			parent = null;
		return dom.getCursor();
	}
}

/// STRING_FILTER is a policy type which determines how strings are
/// transformed for permanent storage inside the DOM.
/// By default, we store slices of the original XML document.
/// However, if the parsing is done using temporary buffers,
/// STRING_FILTER will want to copy (.idup) the strings before
/// letting us store them.
/// STRING_FILTER can also be used to implement a string pool, to
/// make a trade-off between memory consumption and speed
/// (an XML document is likely to contain many repeating strings,
/// such as tag and attribute names). Merging identical strings
/// to obtain unique string pointers or IDs would also allow very
/// quick tag/attribute name lookup, and avoid repeated entity
/// decoding.
struct XmlDomParser(WRITER, alias STRING_FILTER=NoopStringFilter, bool CHECKED=true)
{
	WRITER writer;
	WRITER.DOM.Cursor cursor;

	STRING_FILTER stringFilter;

	alias WRITER.Node Node;

	private Node* addNode(XmlNodeType type)
	{
		assert(cursor.currentParent.type != XmlNodeType.attribute);
		Node* n = writer.newNode();
		n.type = type;
		cursor.appendNode(n);
		return n;
	}

	void startDocument()
	{
		cursor = writer.newDocument();
	}

	void text(XML_STRING)(XML_STRING s)
	{
		with (*addNode(XmlNodeType.text))
			text = stringFilter.handleXmlString(s);
	}

	void directive(XML_STRING)(XML_STRING s)
	{
		with (*addNode(XmlNodeType.directive))
			text = stringFilter.handleXmlString(s);
	}

	void startProcessingInstruction(STRING)(STRING s)
	{
		with (*addNode(XmlNodeType.processingInstruction))
			tag = stringFilter.handleString(s);
		cursor.descend();
	}

	void endProcessingInstruction()
	{
		cursor.ascend();
	}

	void startTag(STRING)(STRING s)
	{
		with (*addNode(XmlNodeType.tag))
			tag = stringFilter.handleString(s);
		cursor.descend();
	}

	void attribute(STRING, XML_STRING)(STRING name, XML_STRING value)
	{
		with (*addNode(XmlNodeType.attribute))
		{
			attributeName  = stringFilter.handleString   (name);
			attributeValue = stringFilter.handleXmlString(value);
		}
	}

	void endAttributes() {}

	void endAttributesAndTag() {}

	void endTag(STRING)(STRING s)
	{
		cursor.ascend();
		static if (CHECKED)
			enforce(stringFilter.handleString(s) == cursor.currentSibling.tag);
	}

	void endDocument()
	{
		cursor.ascend();
		enforce(cursor.currentSibling is writer.dom.root, "Unexpected end of document");
	}
}

struct NoopStringFilter
{
	auto handleString   (S)(S s) { return s; }
	auto handleXmlString(S)(S s) { return s; }
}

unittest
{
	// Test instantiation
	alias XmlDom!string DOM;
	alias XmlDomWriter!DOM WRITER;
	alias XmlDomParser!WRITER OUTPUT;
	alias XmlParser!(string, OUTPUT) PARSER;
	PARSER p;
}
