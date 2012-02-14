/**
 * Simple XML-RPC serializer.
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

module ae.utils.xmlrpc;

import std.string;
import std.conv;
import std.exception;

import ae.utils.xml;

XmlNode valueToXml(T)(T v)
{
	static if (is(T : string))
		return (new XmlNode(XmlNodeType.Node, "value"))
			.addChild((new XmlNode(XmlNodeType.Node, "string"))
				.addChild(new XmlNode(XmlNodeType.Text, v))
			);
	else
	static if (is(T : long))
		return (new XmlNode(XmlNodeType.Node, "value"))
			.addChild((new XmlNode(XmlNodeType.Node, "integer"))
				.addChild(new XmlNode(XmlNodeType.Text, to!string(v)))
			);
	else
	static if (is(T U : U[]))
	{
		XmlNode data = new XmlNode(XmlNodeType.Node, "data");
		foreach (item; v)
			data.addChild(valueToXml(item));
		return (new XmlNode(XmlNodeType.Node, "value"))
			.addChild((new XmlNode(XmlNodeType.Node, "array"))
				.addChild(data)
			);
	}
	else
	static if (is(T==struct))
	{
		XmlNode s = new XmlNode(XmlNodeType.Node, "struct");
		foreach (i, field; v.tupleof)
			s.addChild((new XmlNode(XmlNodeType.Node, "member"))
				.addChild((new XmlNode(XmlNodeType.Node, "name"))
					.addChild(new XmlNode(XmlNodeType.Text, v.tupleof[i].stringof[2..$]))
				)
				.addChild(valueToXml(field))
			);
		return (new XmlNode(XmlNodeType.Node, "value"))
			.addChild(s);
	}
	else
	static if (is(typeof(T.keys)) && is(typeof(T.values)))
	{
		XmlNode s = new XmlNode(XmlNodeType.Node, "struct");
		foreach (key, value; v)
			s.addChild((new XmlNode(XmlNodeType.Node, "member"))
				.addChild((new XmlNode(XmlNodeType.Node, "name"))
					.addChild(new XmlNode(XmlNodeType.Text, key))
				)
				.addChild(valueToXml(value))
			);
		return (new XmlNode(XmlNodeType.Node, "value"))
			.addChild(s);
	}
	else
	static if (is(typeof(*v)))
		return valueToXml(*v);
	else
		static assert(0, "Can't encode " ~ T.stringof ~ " to XML-RPC");
}

XmlDocument formatXmlRpcCall(T...)(string methodName, T params)
{
	auto paramsNode = new XmlNode(XmlNodeType.Node, "params");

	foreach (param; params)
		paramsNode.addChild((new XmlNode(XmlNodeType.Node, "param"))
			.addChild(valueToXml(param))
		);

	auto doc =
		(new XmlDocument())
		.addChild((new XmlNode(XmlNodeType.Meta, "xml"))
			.addAttribute("version", "1.0")
		)
		.addChild((new XmlNode(XmlNodeType.Node, "methodCall"))
			.addChild((new XmlNode(XmlNodeType.Node, "methodName"))
				.addChild(new XmlNode(XmlNodeType.Text, methodName))
			)
			.addChild(paramsNode)
		);
	return cast(XmlDocument)doc;
}

T parseXmlValue(T)(XmlNode value)
{
	enforce(value.type==XmlNodeType.Node && value.tag == "value", "Expected <value> node");
	enforce(value.children.length==1, "Expected one <value> child");
	XmlNode typeNode = value[0];
	enforce(typeNode.type==XmlNodeType.Node, "Expected <value> child to be XML node");
	string valueType = typeNode.tag;

	static if (is(T : string))
	{
		enforce(valueType == "string", "Expected <string>");
		enforce(typeNode.children.length==1, "Expected one <string> child");
		XmlNode contentNode = typeNode[0];
		enforce(contentNode.type==XmlNodeType.Text, "Expected <string> child to be text node");
		return contentNode.tag;
	}
	else
	static if (is(T == bool))
	{
		enforce(valueType == "boolean", "Expected <boolean>");
		enforce(typeNode.children.length==1, "Expected one <boolean> child");
		XmlNode contentNode = typeNode[0];
		enforce(contentNode.type==XmlNodeType.Text, "Expected <boolean> child to be text node");
		enforce(contentNode.tag == "0" || contentNode.tag == "1", "Expected <boolean> child to be 0 or 1");
		return contentNode.tag == "1";
	}
	else
	static if (is(T : long))
	{
		enforce(valueType == "integer" || valueType == "int" || valueType == "i4", "Expected <integer> or <int> or <i4>");
		enforce(typeNode.children.length==1, "Expected one <integer> child");
		XmlNode contentNode = typeNode[0];
		enforce(contentNode.type==XmlNodeType.Text, "Expected <integer> child to be text node");
		string s = contentNode.tag;
		static if (is(T==byte))
			return to!byte(s);
		else
		static if (is(T==ubyte))
			return to!ubyte(s);
		else
		static if (is(T==short))
			return to!short(s);
		else
		static if (is(T==ushort))
			return to!ushort(s);
		else
		static if (is(T==int))
			return to!int(s);
		else
		static if (is(T==uint))
			return to!uint(s);
		else
		static if (is(T==long))
			return to!long(s);
		else
		static if (is(T==ulong))
			return to!ulong(s);
		else
			static assert(0, "Don't know how to parse numerical type " ~ T.stringof);
	}
	else
	static if (is(T == double))
	{
		enforce(valueType == "double", "Expected <double>");
		enforce(typeNode.children.length==1, "Expected one <double> child");
		XmlNode contentNode = typeNode[0];
		enforce(contentNode.type==XmlNodeType.Text, "Expected <double> child to be text node");
		string s = contentNode.tag;
		return to!double(s);
	}
	else
	static if (is(T U : U[]))
	{
		enforce(valueType == "array", "Expected <array>");
		enforce(typeNode.children.length==1, "Expected one <array> child");
		XmlNode dataNode = typeNode[0];
		enforce(dataNode.type==XmlNodeType.Node && dataNode.tag == "data", "Expected <data>");
		T result = new U[dataNode.children.length];
		foreach (i, child; dataNode.children)
			result[i] = parseXmlValue!(U)(child);
		return result;
	}
	else
	static if (is(T==struct))
	{
		enforce(valueType == "struct", "Expected <struct>");
		T v;
		foreach (memberNode; typeNode.children)
		{
			enforce(memberNode.type==XmlNodeType.Node && memberNode.tag == "member", "Expected <member>");
			enforce(memberNode.children.length == 2, "Expected 2 <member> children");
			auto nameNode = memberNode[0];
			enforce(nameNode.type==XmlNodeType.Node && nameNode.tag == "name", "Expected <name>");
			enforce(nameNode.children.length == 1, "Expected one <name> child");
			XmlNode contentNode = nameNode[0];
			enforce(contentNode.type==XmlNodeType.Text, "Expected <name> child to be text node");
			string memberName = contentNode.tag;

			bool found;
			foreach (i, field; v.tupleof)
				if (v.tupleof[i].stringof[2..$] == memberName)
				{
					v.tupleof[i] = parseXmlValue!(typeof(v.tupleof[i]))(memberNode[1]);
					found = true;
					break;
				}
			enforce(found, "Unknown field " ~ memberName);
		}
		return v;
	}
	else
		static assert(0, "Can't decode " ~ T.stringof ~ " from XML-RPC");
}

class XmlRpcException : Exception
{
	int faultCode;
	string faultString;

	this(int faultCode, string faultString)
	{
		this.faultCode = faultCode;
		this.faultString = faultString;
		super(format("XML-RPC error %d (%s)", faultCode, faultString));
	}
}

T parseXmlRpcResponse(T)(XmlDocument doc)
{
	auto methodResponse = doc["methodResponse"];
	auto fault = methodResponse.findChild("fault");
	if (fault)
	{
		struct Fault
		{
			int faultCode;
			string faultString;
		}
		auto details = parseXmlValue!(Fault)(fault["value"]);
		throw new XmlRpcException(details.faultCode, details.faultString);
	}

	auto params = methodResponse.findChild("params");
	enforce(params.children.length==1, "Only one response parameter supported");
	return parseXmlValue!(T)(params["param"][0]);
}
