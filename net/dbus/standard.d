/**
 * The standard `org.freedesktop.DBus.*` object interfaces, declared as
 * typed D-Bus interfaces.
 *
 * Clients can call them through `dbusProxy`; the object registry takes
 * their descriptions and introspection fragments from here.
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

module ae.net.dbus.standard;

import ae.net.dbus.description;
import ae.net.dbus.introspection;
import ae.net.dbus.value : DbusVariant;
import ae.utils.promise : Promise;

/// `org.freedesktop.DBus.Peer`, implemented on every object path.
@DbusInterface("org.freedesktop.DBus.Peer")
interface DbusPeer
{
	Promise!void Ping(); ///
	Promise!string GetMachineId(); ///
}

/// `org.freedesktop.DBus.Introspectable`, implemented on every object path.
@DbusInterface("org.freedesktop.DBus.Introspectable")
interface DbusIntrospectable
{
	Promise!string Introspect(); /// Returns the XML introspection document.
}

/// `org.freedesktop.DBus.Properties`, implemented on every exported object.
@DbusInterface("org.freedesktop.DBus.Properties")
interface DbusProperties
{
	Promise!DbusVariant Get(string interface_name, string property_name); ///
	Promise!void Set(string interface_name, string property_name, DbusVariant value); ///
	Promise!(DbusVariant[string]) GetAll(string interface_name); ///
	/// Arguments: interface name, changed properties, invalidated properties.
	alias PropertiesChanged = DbusSignal!("PropertiesChanged", string, DbusVariant[string], string[]);
}

package(ae.net.dbus):

enum dbusPeerDescription = dbusInterfaceDescription!DbusPeer;
enum dbusIntrospectableDescription = dbusInterfaceDescription!DbusIntrospectable;
enum dbusPropertiesDescription = dbusInterfaceDescription!DbusProperties;

enum dbusPeerXml = dbusIntrospectionXml!DbusPeer;
enum dbusIntrospectableXml = dbusIntrospectionXml!DbusIntrospectable;
enum dbusPropertiesXml = dbusIntrospectionXml!DbusProperties;

debug(ae_unittest) unittest
{
	static assert(dbusPeerXml ==
`<interface name="org.freedesktop.DBus.Peer">
  <method name="Ping"/>
  <method name="GetMachineId">
    <arg type="s" direction="out"/>
  </method>
</interface>
`);
	static assert(dbusIntrospectableXml ==
`<interface name="org.freedesktop.DBus.Introspectable">
  <method name="Introspect">
    <arg type="s" direction="out"/>
  </method>
</interface>
`);
	static assert(dbusPropertiesXml ==
`<interface name="org.freedesktop.DBus.Properties">
  <method name="Get">
    <arg name="interface_name" type="s" direction="in"/>
    <arg name="property_name" type="s" direction="in"/>
    <arg type="v" direction="out"/>
  </method>
  <method name="Set">
    <arg name="interface_name" type="s" direction="in"/>
    <arg name="property_name" type="s" direction="in"/>
    <arg name="value" type="v" direction="in"/>
  </method>
  <method name="GetAll">
    <arg name="interface_name" type="s" direction="in"/>
    <arg type="a{sv}" direction="out"/>
  </method>
  <signal name="PropertiesChanged">
    <arg type="s"/>
    <arg type="a{sv}"/>
    <arg type="as"/>
  </signal>
</interface>
`);
	static assert(dbusPropertiesDescription.methods[0].inArgs[0].name == "interface_name");
	static assert(dbusPeerDescription.methods.length == 2);
	static assert(dbusIntrospectableDescription.methods[0].outArgs[0].type.text == "s");
}
