/**
 * D-Bus introspection XML, generated from interface descriptions.
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

module ae.net.dbus.introspection;

import ae.net.dbus.description;

/// The `<interface>` element describing `description`, one element or
/// attribute per line. Usable at compile time.
string dbusInterfaceXml(const DbusInterfaceDescription description)
{
	string xml = "<interface name=\"" ~ xmlText(description.name.text) ~ "\">\n";
	foreach (method; description.methods)
	{
		if (!method.inArgs.length && !method.outArgs.length)
		{
			xml ~= "  <method name=\"" ~ xmlText(method.name.text) ~ "\"/>\n";
			continue;
		}
		xml ~= "  <method name=\"" ~ xmlText(method.name.text) ~ "\">\n";
		foreach (arg; method.inArgs)
			xml ~= "    " ~ argumentXml(arg, " direction=\"in\"");
		foreach (arg; method.outArgs)
			xml ~= "    " ~ argumentXml(arg, " direction=\"out\"");
		xml ~= "  </method>\n";
	}
	foreach (signal; description.signals)
	{
		if (!signal.args.length)
		{
			xml ~= "  <signal name=\"" ~ xmlText(signal.name.text) ~ "\"/>\n";
			continue;
		}
		xml ~= "  <signal name=\"" ~ xmlText(signal.name.text) ~ "\">\n";
		foreach (arg; signal.args)
			xml ~= "    " ~ argumentXml(arg, "");
		xml ~= "  </signal>\n";
	}
	foreach (property; description.properties)
	{
		auto element = "  <property name=\"" ~ xmlText(property.name.text) ~
			"\" type=\"" ~ xmlText(property.type.text) ~
			"\" access=\"" ~ accessText(property.access) ~ "\"";
		if (property.emitsChangedSignal == DbusEmitsChangedSignal.true_)
		{
			xml ~= element ~ "/>\n";
			continue;
		}
		xml ~= element ~ ">\n";
		xml ~= "    <annotation name=\"org.freedesktop.DBus.Property.EmitsChangedSignal\" value=\"" ~
			emitsChangedSignalText(property.emitsChangedSignal) ~ "\"/>\n";
		xml ~= "  </property>\n";
	}
	return xml ~ "</interface>\n";
}

/// The `<interface>` element describing the D-Bus interface declared by
/// the D interface `I`, as a compile-time constant.
enum string dbusIntrospectionXml(I) = dbusInterfaceXml(dbusInterfaceDescription!I);

/// A complete introspection document for one object path: the interfaces
/// implemented there (as `dbusInterfaceXml` fragments) and the names of
/// its direct children.
package(ae.net.dbus) string dbusNodeXml(scope const(string)[] interfaceFragments,
	scope const(string)[] children)
{
	string xml = dbusIntrospectionDoctype ~ "<node>\n";
	foreach (fragment; interfaceFragments)
		xml ~= indent(fragment);
	foreach (child; children)
		xml ~= "  <node name=\"" ~ xmlText(child) ~ "\"/>\n";
	return xml ~ "</node>\n";
}

private:

enum dbusIntrospectionDoctype =
	"<!DOCTYPE node PUBLIC \"-//freedesktop//DTD D-BUS Object Introspection 1.0//EN\"\n" ~
	"\"http://www.freedesktop.org/standards/dbus/1.0/introspect.dtd\">\n";

/// Every text placed in the document is a validated D-Bus name or
/// signature, or an argument or path element name, none of which may
/// contain characters that would need escaping.
string xmlText(string text)
{
	// Typed descriptions and raw registration validate all inputs before this internal check.
	foreach (char c; text)
		assert(c != '<' && c != '>' && c != '&' && c != '"' && c != '\'',
			"D-Bus introspection text must not contain XML markup characters: " ~ text);
	return text;
}

string argumentXml(const DbusArgumentDescription arg, string direction)
{
	auto name = arg.name.length ? " name=\"" ~ xmlText(arg.name) ~ "\"" : "";
	return "<arg" ~ name ~ " type=\"" ~ xmlText(arg.type.text) ~ "\"" ~ direction ~ "/>\n";
}

string accessText(DbusPropertyAccess access)
{
	final switch (access)
	{
		case DbusPropertyAccess.read: return "read";
		case DbusPropertyAccess.write: return "write";
		case DbusPropertyAccess.readwrite: return "readwrite";
	}
}

string emitsChangedSignalText(DbusEmitsChangedSignal value)
{
	final switch (value)
	{
		case DbusEmitsChangedSignal.true_: return "true";
		case DbusEmitsChangedSignal.invalidates: return "invalidates";
		case DbusEmitsChangedSignal.const_: return "const";
		case DbusEmitsChangedSignal.false_: return "false";
	}
}

string indent(string fragment)
{
	string result;
	bool lineStart = true;
	foreach (char c; fragment)
	{
		if (lineStart)
			result ~= "  ";
		result ~= c;
		lineStart = c == '\n';
	}
	return result;
}

debug(ae_unittest) import ae.net.dbus.signature : DbusOut;
debug(ae_unittest) import ae.utils.promise : Promise;

debug(ae_unittest)
@DbusInterface("org.example.Introspected")
interface DbusIntrospectionTestInterface
{
	Promise!void Play();
	Promise!(DbusOut!(uint, string)) GetPosition();
	@DbusMember("Seek") Promise!int seek(long offset, int);
	@DbusProperty Promise!double Volume();
	@DbusProperty Promise!void Volume(double value);
	@DbusPropertyAttribute(DbusEmitsChangedSignal.invalidates) Promise!string Title();
	@DbusPropertyAttribute(DbusEmitsChangedSignal.const_) Promise!void Mode(string value);
	alias Seeked = DbusSignal!("Seeked", long);
	alias Stopped = DbusSignal!("Stopped");
}

debug(ae_unittest) unittest
{
	static assert(dbusIntrospectionXml!DbusIntrospectionTestInterface ==
`<interface name="org.example.Introspected">
  <method name="Play"/>
  <method name="GetPosition">
    <arg type="u" direction="out"/>
    <arg type="s" direction="out"/>
  </method>
  <method name="Seek">
    <arg name="offset" type="x" direction="in"/>
    <arg type="i" direction="in"/>
    <arg type="i" direction="out"/>
  </method>
  <signal name="Seeked">
    <arg type="x"/>
  </signal>
  <signal name="Stopped"/>
  <property name="Volume" type="d" access="readwrite"/>
  <property name="Title" type="s" access="read">
    <annotation name="org.freedesktop.DBus.Property.EmitsChangedSignal" value="invalidates"/>
  </property>
  <property name="Mode" type="s" access="write">
    <annotation name="org.freedesktop.DBus.Property.EmitsChangedSignal" value="const"/>
  </property>
</interface>
`);
}

debug(ae_unittest) unittest
{
	import ae.net.dbus.common : DbusInterfaceName;

	DbusInterfaceDescription empty;
	empty.name = DbusInterfaceName.parse("org.example.Empty");
	assert(dbusNodeXml([dbusInterfaceXml(empty)], ["a", "b"]) ==
`<!DOCTYPE node PUBLIC "-//freedesktop//DTD D-BUS Object Introspection 1.0//EN"
"http://www.freedesktop.org/standards/dbus/1.0/introspect.dtd">
<node>
  <interface name="org.example.Empty">
  </interface>
  <node name="a"/>
  <node name="b"/>
</node>
`);
	assert(dbusNodeXml(null, null) == dbusIntrospectionDoctype ~ "<node>\n</node>\n");
}
