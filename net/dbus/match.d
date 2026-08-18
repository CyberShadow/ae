/**
 * Structured D-Bus signal match rules.
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

module ae.net.dbus.match;

import std.conv : to;

import ae.net.dbus.common;

debug(ae_unittest) import std.string : indexOf;

/**
 * A validated, signal-only subset of the D-Bus match-rule grammar.
 */
struct DbusSignalMatch
{
private:
	bool signal_;
	DbusBusName sender_;
	DbusInterfaceName interface_;
	DbusMemberName member_;
	DbusObjectPath path_;
	DbusBusName destination_;
	bool[64] hasArguments_;
	string[64] arguments_;

	static void requireName(string value, string description)
	{
		if (!value.length)
			throw new DbusValidationException(description ~ " must be initialized");
	}

	void requireSignal() const
	{
		if (!signal_)
			throw new DbusValidationException("D-Bus signal matches must be created with signal()");
	}

	DbusSignalMatch copy() const
	{
		DbusSignalMatch result;
		result.signal_ = signal_;
		result.sender_ = sender_;
		result.interface_ = interface_;
		result.member_ = member_;
		result.path_ = path_;
		result.destination_ = destination_;
		foreach (index; 0 .. arguments_.length)
		{
			result.hasArguments_[index] = hasArguments_[index];
			result.arguments_[index] = arguments_[index];
		}
		return result;
	}

	static string quote(string value)
	{
		char[] result;
		result ~= '\'';
		foreach (dchar character; value)
		{
			if (character == '\'')
				result ~= "'\\''";
			else
				result ~= character;
		}
		result ~= '\'';
		return result.idup;
	}

	static void appendField(ref char[] result, string key, string value)
	{
		if (result.length)
			result ~= ',';
		result ~= key;
		result ~= '=';
		result ~= quote(value);
	}

public:
	static DbusSignalMatch signal()
	{
		DbusSignalMatch result;
		result.signal_ = true;
		return result;
	}

	DbusSignalMatch withSender(DbusBusName value) const
	{
		requireSignal();
		requireName(value.text, "D-Bus signal match sender");
		auto result = copy();
		result.sender_ = value;
		return result;
	}

	DbusSignalMatch withInterface(DbusInterfaceName value) const
	{
		requireSignal();
		requireName(value.text, "D-Bus signal match interface");
		auto result = copy();
		result.interface_ = value;
		return result;
	}

	DbusSignalMatch withMember(DbusMemberName value) const
	{
		requireSignal();
		requireName(value.text, "D-Bus signal match member");
		auto result = copy();
		result.member_ = value;
		return result;
	}

	DbusSignalMatch withPath(DbusObjectPath value) const
	{
		requireSignal();
		requireName(value.text, "D-Bus signal match path");
		auto result = copy();
		result.path_ = value;
		return result;
	}

	DbusSignalMatch withDestination(DbusBusName value) const
	{
		requireSignal();
		requireName(value.text, "D-Bus signal match destination");
		auto result = copy();
		result.destination_ = value;
		return result;
	}

	DbusSignalMatch withArgument(size_t index, string value) const
	{
		requireSignal();
		if (index >= arguments_.length)
			throw new DbusValidationException("D-Bus signal match arguments are limited to arg0 through arg63");
		auto result = copy();
		result.hasArguments_[index] = true;
		result.arguments_[index] = copyDbusText(value, "D-Bus signal match argument");
		return result;
	}

	package(ae.net.dbus) @property bool hasSender() const
	{
		return sender_.text.length != 0;
	}

	package(ae.net.dbus) @property DbusBusName sender() const
	{
		return sender_;
	}

	package(ae.net.dbus) @property bool hasInterface() const
	{
		return interface_.text.length != 0;
	}

	package(ae.net.dbus) @property DbusInterfaceName interfaceName() const
	{
		return interface_;
	}

	package(ae.net.dbus) @property bool hasMember() const
	{
		return member_.text.length != 0;
	}

	package(ae.net.dbus) @property DbusMemberName member() const
	{
		return member_;
	}

	package(ae.net.dbus) @property bool hasPath() const
	{
		return path_.text.length != 0;
	}

	package(ae.net.dbus) @property DbusObjectPath path() const
	{
		return path_;
	}

	package(ae.net.dbus) @property bool hasDestination() const
	{
		return destination_.text.length != 0;
	}

	package(ae.net.dbus) @property DbusBusName destination() const
	{
		return destination_;
	}

	package(ae.net.dbus) bool hasArgument(size_t index) const
	{
		assert(index < hasArguments_.length);
		return hasArguments_[index];
	}

	package(ae.net.dbus) string argument(size_t index) const
	{
		assert(index < arguments_.length);
		assert(hasArguments_[index]);
		return arguments_[index];
	}

	package(ae.net.dbus) @property string canonicalRule() const
	{
		requireSignal();
		char[] result;
		appendField(result, "type", "signal");
		if (hasSender)
			appendField(result, "sender", sender_.text);
		if (hasInterface)
			appendField(result, "interface", interface_.text);
		if (hasMember)
			appendField(result, "member", member_.text);
		if (hasPath)
			appendField(result, "path", path_.text);
		if (hasDestination)
			appendField(result, "destination", destination_.text);
		foreach (index; 0 .. arguments_.length)
			if (hasArguments_[index])
				appendField(result, "arg" ~ to!string(index), arguments_[index]);
		return result.idup;
	}
}

debug(ae_unittest)
private void expectDbusMatchValidation(void delegate() action)
{
	bool caught;
	try
		action();
	catch (DbusValidationException)
		caught = true;
	assert(caught);
}

debug(ae_unittest)
private string dbusMatchTestDecodeQuoted(string value)
{
	assert(value.length >= 2 && value[0] == '\'' && value[$ - 1] == '\'');
	char[] result;
	size_t index = 1;
	bool quoted = true;
	while (index < value.length)
	{
		auto character = value[index++];
		if (quoted)
		{
			if (character == '\'')
				quoted = false;
			else
				result ~= character;
		}
		else if (character == '\\')
		{
			assert(index < value.length && value[index] == '\'');
			result ~= value[index++];
		}
		else
		{
			assert(character == '\'');
			quoted = true;
		}
	}
	assert(!quoted);
	return result.idup;
}

debug(ae_unittest)
private string dbusMatchTestArgumentValue(string rule)
{
	auto separator = rule.indexOf(",arg0=");
	assert(separator != -1);
	return dbusMatchTestDecodeQuoted(rule[separator + 6 .. $]);
}

debug(ae_unittest) unittest
{
	auto empty = DbusSignalMatch.signal();
	auto senderAndMember = empty
		.withSender(DbusBusName.parse("org.example.Service"))
		.withMember(DbusMemberName.parse("Changed"));
	auto full = senderAndMember
		.withPath(DbusObjectPath.parse("/org/example/Object"))
		.withDestination(DbusBusName.parse(":1.5"))
		.withInterface(DbusInterfaceName.parse("org.example.Interface"))
		.withArgument(63, "sixty-three")
		.withArgument(10, "ten")
		.withArgument(2, "two")
		.withArgument(0, "zero");

	assert(empty.canonicalRule == "type='signal'");
	assert(senderAndMember.canonicalRule == "type='signal',sender='org.example.Service',member='Changed'");
	assert(full.canonicalRule == "type='signal',sender='org.example.Service',interface='org.example.Interface',member='Changed',path='/org/example/Object',destination=':1.5',arg0='zero',arg2='two',arg10='ten',arg63='sixty-three'");

	auto sparse = empty
		.withArgument(10, "ten")
		.withArgument(2, "two")
		.withArgument(63, "sixty-three")
		.withArgument(0, "zero")
		.withArgument(3, "three");
	assert(empty.canonicalRule == "type='signal'");
	assert(sparse.canonicalRule == "type='signal',arg0='zero',arg2='two',arg3='three',arg10='ten',arg63='sixty-three'");

	char[] mutableArgument = "before".dup;
	auto copiedArgument = empty.withArgument(1, cast(string) mutableArgument);
	mutableArgument[0] = 'A';
	assert(copiedArgument.canonicalRule == "type='signal',arg1='before'");
}

debug(ae_unittest) unittest
{
	string[] values = ["", "back\\slash", "'leading", "trailing'", "two''quotes", "mixed\\'text"];
	foreach (value; values)
	{
		auto rule = DbusSignalMatch.signal().withArgument(0, value).canonicalRule;
		assert(dbusMatchTestArgumentValue(rule) == value);
	}
	assert(DbusSignalMatch.signal().withArgument(0, "").canonicalRule ==
		"type='signal',arg0=''");
	assert(DbusSignalMatch.signal().withArgument(0, "back\\slash").canonicalRule ==
		"type='signal',arg0='back\\slash'");
	assert(DbusSignalMatch.signal().withArgument(0, "'leading").canonicalRule ==
		"type='signal',arg0=''\\''leading'");
	assert(DbusSignalMatch.signal().withArgument(0, "trailing'").canonicalRule ==
		"type='signal',arg0='trailing'\\'''");
	assert(DbusSignalMatch.signal().withArgument(0, "two''quotes").canonicalRule ==
		"type='signal',arg0='two'\\'''\\''quotes'");
	assert(DbusSignalMatch.signal().withArgument(0, "mixed\\'text").canonicalRule ==
		"type='signal',arg0='mixed\\'\\''text'");

	expectDbusMatchValidation({ DbusSignalMatch.signal().withArgument(64, "invalid"); });
	expectDbusMatchValidation({ DbusSignalMatch.signal().withArgument(0, "nul\0value"); });
	char[] invalidUtf8 = [cast(char) 0xff];
	expectDbusMatchValidation({ DbusSignalMatch.signal().withArgument(0, cast(string) invalidUtf8); });

	DbusBusName missingBusName;
	DbusInterfaceName missingInterface;
	DbusMemberName missingMember;
	DbusObjectPath missingPath;
	expectDbusMatchValidation({ DbusSignalMatch.signal().withSender(missingBusName); });
	expectDbusMatchValidation({ DbusSignalMatch.signal().withInterface(missingInterface); });
	expectDbusMatchValidation({ DbusSignalMatch.signal().withMember(missingMember); });
	expectDbusMatchValidation({ DbusSignalMatch.signal().withPath(missingPath); });
	expectDbusMatchValidation({ DbusSignalMatch.signal().withDestination(missingBusName); });

	DbusSignalMatch invalid;
	expectDbusMatchValidation({ auto ignored = invalid.canonicalRule; });
	expectDbusMatchValidation({ auto ignored = invalid.withArgument(0, "value"); });
}
