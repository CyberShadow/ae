/**
 * Serving D-Bus objects: the per-connection object registry and the
 * dispatch of incoming method calls.
 *
 * Every `DbusConnection` owns one `DbusObjectRegistry`
 * (`DbusConnection.objects`).  Applications register interface
 * implementations at object paths; each implementation pairs a runtime
 * `DbusInterfaceDescription` with promise-returning handlers.  This is
 * the untyped layer; `ae.net.dbus.exporter.exportObject` builds such an
 * implementation from a typed `@DbusInterface` D interface.
 *
 * Handlers reply by settling their promise.  Throwing or rejecting with a
 * `DbusError` sends that error
 * name and message; any other `Exception` sends
 * `org.freedesktop.DBus.Error.Failed` with its message.
 *
 * The registry implements the standard interfaces itself.  `Peer` is
 * answered on every path.  Registered objects and their ancestors answer
 * `Introspectable`, with a document listing their interfaces and child
 * nodes.  Registered objects also answer `Properties`, which calls the
 * property handlers of their interfaces and checks the declared types
 * and access in both directions.  Property changes are not announced
 * automatically; emit `PropertiesChanged` with
 * `DbusConnection.emitSignal`.
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

module ae.net.dbus.service;

import ae.net.dbus.common;
import ae.net.dbus.description;
import ae.net.dbus.introspection;
import ae.net.dbus.signature : parseDbusVariantSignature;
import ae.net.dbus.standard;
import ae.net.dbus.value : DbusBody, DbusVariant;
import ae.utils.promise : Promise, all, resolve;

/// Answers one method call.  The reply body must have the method's
/// declared out-signature. A received `DbusRemoteError` is forwarded only
/// by explicitly throwing `new DbusError(e.errorName, e.remoteMessage)`.
alias DbusMethodHandler = Promise!DbusBody delegate(const ref DbusMessage call);

/// Reads a property.  The variant must hold the property's declared type.
alias DbusPropertyGetter = Promise!DbusVariant delegate();

/// Writes a property.  The variant holds the property's declared type.
alias DbusPropertySetter = Promise!void delegate(DbusVariant value);

/// The accessors of one property.  `get` is null exactly when the property
/// is not readable, and `set` exactly when it is not writable.
struct DbusPropertyHandlers
{
	DbusPropertyGetter get; ///
	DbusPropertySetter set; ///
}

/// One interface implementation, ready to register at an object path.
struct DbusInterfaceImplementation
{
	DbusInterfaceDescription description; ///
	DbusMethodHandler[] methods; /// Aligned with `description.methods`.
	DbusPropertyHandlers[] properties; /// Aligned with `description.properties`.
}

/// The objects served by one connection.
final class DbusObjectRegistry
{
	/// Serves `implementation` at `path` until the returned registration
	/// is unregistered.
	///
	/// Throws `DbusValidationException` if `path` already has an interface
	/// of that name, if the interface is one of the standard interfaces
	/// the registry implements itself (`DbusPeer`, `DbusIntrospectable`,
	/// `DbusProperties`), if the description has empty or duplicate member
	/// names, if an argument name is neither empty nor an identifier
	/// (ASCII letters, digits and underscores, not starting with a digit),
	/// if an argument or property type is not exactly one complete type,
	/// if the handler arrays are not aligned with the description, or if a
	/// handler is missing or present contrary to the member's declaration.
	/// The description is copied, so later changes to the caller's
	/// arrays do not affect the registration.
	DbusInterfaceRegistration register(DbusObjectPath path,
		DbusInterfaceImplementation implementation)
	{
		if (!path.text.length)
			throw new DbusValidationException("D-Bus object registration requires a path");
		validateImplementation(implementation);
		auto name = implementation.description.name.text;
		foreach (standard; [dbusPeerDescription.name.text,
			dbusIntrospectableDescription.name.text, dbusPropertiesDescription.name.text])
			if (name == standard)
				throw new DbusValidationException("D-Bus interface " ~ name ~
					" is implemented by the object registry");
		auto registrations = path.text in objects_;
		if (registrations !is null)
			foreach (registration; *registrations)
				if (registration.interfaceName.text == name)
					throw new DbusValidationException("D-Bus interface " ~ name ~
						" is already registered at " ~ path.text);

		auto registration = new DbusInterfaceRegistration(this, path,
			DbusInterfaceEntry(implementation));
		objects_[path.text] ~= registration;
		return registration;
	}

package(ae.net.dbus):
	/// Whether no interface is registered.  A connection with registered
	/// objects cannot become a monitor.
	@property bool empty() const
	{
		return objects_.length == 0;
	}

	/// `send` assigns a serial to a message that expects no reply and
	/// writes it; `open` tells whether the connection can still send.
	this(void delegate(DbusMessage) send, bool delegate() open)
	{
		assert(send !is null && open !is null);
		send_ = send;
		open_ = open;
		peer_ = DbusInterfaceEntry(DbusInterfaceImplementation(dbusPeerDescription,
			[&peerPing, &peerGetMachineId]));
		introspectable_ = DbusInterfaceEntry(DbusInterfaceImplementation(
			dbusIntrospectableDescription, [&introspect]));
		properties_ = DbusInterfaceEntry(DbusInterfaceImplementation(
			dbusPropertiesDescription, [&propertiesGet, &propertiesSet, &propertiesGetAll]));
	}

	/// Answers an incoming method call received on a ready connection.
	void dispatch(DbusMessage call)
	{
		assert(call.messageType == DbusMessageType.methodCall);
		if (expectsReply(call) && !call.headers.sender.text.length)
			throw new DbusProtocolException("incoming D-Bus method calls require SENDER for a reply");

		auto path = call.headers.path.text;
		auto interfaceName = call.headers.interfaceName.text;
		if (interfaceName == dbusPeerDescription.name.text)
			return dispatchMethod(call, peer_);

		auto entries = entries(path);
		if (!entries.length)
			return sendError(call, DbusErrorNames.unknownObject,
				"No such object path '" ~ path ~ "'");
		if (!interfaceName.length)
			return dispatchUnqualified(call, entries);
		foreach (entry; entries)
			if (entry.implementation.description.name.text == interfaceName)
				return dispatchMethod(call, *entry);
		sendError(call, DbusErrorNames.unknownInterface,
			"No such interface '" ~ interfaceName ~ "' at object path '" ~ path ~ "'");
	}

private:
	void delegate(DbusMessage) send_;
	bool delegate() open_;
	DbusInterfaceRegistration[][string] objects_;
	DbusInterfaceEntry peer_, introspectable_, properties_;

	/// The interfaces at `path`, standard ones first: those of a
	/// registered object, `Peer` and `Introspectable` on an ancestor of
	/// registered objects or at the root, and none elsewhere.
	const(DbusInterfaceEntry)*[] entries(string path) const
	{
		auto registrations = path in objects_;
		if (registrations is null)
			return path == "/" || childNames(path).length ?
				[&peer_, &introspectable_] : null;
		const(DbusInterfaceEntry)*[] result = [&peer_, &introspectable_, &properties_];
		foreach (registration; *registrations)
			result ~= &registration.entry_;
		return result;
	}

	/// The distinct first path elements of registered objects below
	/// `path`, sorted.
	string[] childNames(string path) const
	{
		import std.algorithm.searching : findSplitBefore, startsWith;
		import std.algorithm.sorting : sort;

		auto prefix = path == "/" ? "/" : path ~ "/";
		bool[string] names;
		foreach (objectPath, registrations; objects_)
			if (objectPath.length > prefix.length && objectPath.startsWith(prefix))
				names[objectPath[prefix.length .. $].findSplitBefore("/")[0]] = true;
		return names.keys.sort.release;
	}

	void unregister(DbusInterfaceRegistration registration)
	{
		auto path = registration.path.text;
		auto registrations = objects_[path];
		DbusInterfaceRegistration[] remaining;
		foreach (other; registrations)
			if (other !is registration)
				remaining ~= other;
		assert(remaining.length + 1 == registrations.length);
		if (remaining.length)
			objects_[path] = remaining;
		else
			objects_.remove(path);
	}

	/// A call without an interface goes to the only interface on the
	/// object that has the member; the spec leaves ambiguity to the
	/// implementation, and it is answered like a missing member.
	void dispatchUnqualified(DbusMessage call, const(DbusInterfaceEntry)*[] entries)
	{
		auto member = call.headers.member.text;
		const(DbusInterfaceEntry)* match;
		size_t matches;
		foreach (entry; entries)
			foreach (method; entry.implementation.description.methods)
				if (method.name.text == member)
				{
					match = entry;
					matches++;
				}
		if (matches != 1)
			return sendError(call, DbusErrorNames.unknownMethod,
				(matches ? "Ambiguous" : "No such") ~ " method '" ~ member ~
				"' at object path '" ~ call.headers.path.text ~ "'");
		dispatchMethod(call, *match);
	}

	void dispatchMethod(DbusMessage call, ref const DbusInterfaceEntry entry)
	{
		auto member = call.headers.member.text;
		foreach (index, method; entry.implementation.description.methods)
		{
			if (method.name.text != member)
				continue;
			auto signature = call.body.signature.text;
			if (signature != entry.inSignatures[index])
				return sendError(call, DbusErrorNames.invalidArgs,
					"Method '" ~ member ~ "' expects signature '" ~ entry.inSignatures[index] ~
					"', got '" ~ signature ~ "'");
			return respond(call, invokeHandler(entry.implementation.methods[index], call),
				entry.outSignatures[index]);
		}
		sendError(call, DbusErrorNames.unknownMethod,
			"No such method '" ~ member ~ "' in interface '" ~
			entry.implementation.description.name.text ~ "'");
	}

	static Promise!DbusBody invokeHandler(DbusMethodHandler handler, const ref DbusMessage call)
	{
		try
			return handler(call);
		catch (Exception exception)
		{
			auto result = new Promise!DbusBody;
			result.reject(exception);
			return result;
		}
	}

	/// Sends the handler's result once it settles.  Settlement is not
	/// ordered with the connection's lifecycle, so a result that arrives
	/// after the connection closed or started becoming a monitor cannot
	/// be sent and is dropped.
	void respond(DbusMessage call, Promise!DbusBody result, string outSignature)
	{
		if (!expectsReply(call))
			return result.ignoreResult();
		result.then((DbusBody body) {
			if (!open_())
				return;
			if (body.signature.text != outSignature)
				return sendError(call, DbusErrorNames.failed,
					"Method '" ~ call.headers.member.text ~ "' returned signature '" ~
					body.signature.text ~ "' instead of '" ~ outSignature ~ "'");
			sendResponse(call, body);
		}, (Exception exception) {
			if (!open_())
				return;
			auto error = cast(DbusError) exception;
			auto remote = cast(DbusRemoteError) exception;
			auto message = remote ? remote.errorName.text ~ ": " ~ remote.remoteMessage : exception.msg;
			sendError(call, error ? error.errorName : DbusErrorNames.failed, message);
		}).ignoreResult();
	}

	void sendError(const ref DbusMessage call, DbusErrorName name, string message)
	{
		if (!expectsReply(call))
			return;
		sendResponse(call, DbusBody.init, name, message);
	}

	void sendResponse(const ref DbusMessage call, DbusBody body,
		DbusErrorName errorName = DbusErrorName.init, string message = null)
	{
		DbusMessage reply;
		reply.messageType = errorName.text.length ? DbusMessageType.error : DbusMessageType.methodReturn;
		reply.headers.errorName = errorName;
		reply.headers.replySerial = call.serial;
		reply.headers.destination = call.headers.sender;
		try
		{
			reply.body = errorName.text.length ? DbusBody.from(message) : body;
			send_(reply);
		}
		catch (Exception)
		{
			reply.messageType = DbusMessageType.error;
			reply.headers.errorName = DbusErrorNames.failed;
			reply.body = DbusBody.from("D-Bus reply could not be sent");
			send_(reply);
		}
	}

	Promise!DbusBody peerPing(const ref DbusMessage)
	{
		return resolve(DbusBody.from());
	}

	Promise!DbusBody peerGetMachineId(const ref DbusMessage)
	{
		return resolve(DbusBody.from(readDbusMachineId(dbusMachineIdPaths)));
	}

	/// The document lists the interfaces at the path, as `entries`
	/// orders them, and the children.
	Promise!DbusBody introspect(const ref DbusMessage call)
	{
		auto path = call.headers.path.text;
		string[] fragments;
		foreach (entry; entries(path))
			fragments ~= entry.xml;
		return resolve(DbusBody.from(dbusNodeXml(fragments, childNames(path))));
	}

	/// A property of the object a `Properties` call was sent to.
	static struct PropertyTarget
	{
		const(DbusInterfaceEntry)* entry;
		size_t index;

		@property const(DbusPropertyDescription) description() const
		{
			return entry.implementation.description.properties[index];
		}

		@property DbusPropertyHandlers handlers() const
		{
			return entry.implementation.properties[index];
		}

		/// The getter's value, checked against the declared type.
		Promise!DbusVariant read() const
		{
			auto property = description;
			Promise!DbusVariant value;
			try
				value = handlers.get();
			catch (Exception exception)
			{
				value = new Promise!DbusVariant;
				value.reject(exception);
			}
			return value.then((DbusVariant variant) {
				if (variant.containedSignature.text != property.type.text)
					throw new DbusError(DbusErrorNames.failed, "Property '" ~
						property.name.text ~ "' returned type '" ~
						variant.containedSignature.text ~ "' instead of '" ~
						property.type.text ~ "'");
				return variant;
			});
		}
	}

	/// The interfaces a `Properties` call with this interface argument
	/// addresses: the named one, or all of them if it is empty.
	const(DbusInterfaceEntry)*[] propertyInterfaces(const ref DbusMessage call,
		string interfaceName)
	{
		auto all = entries(call.headers.path.text);
		if (!interfaceName.length)
			return all;
		foreach (entry; all)
			if (entry.implementation.description.name.text == interfaceName)
				return [entry];
		throw new DbusError(DbusErrorNames.unknownInterface, "No such interface '" ~
			interfaceName ~ "' at object path '" ~ call.headers.path.text ~ "'");
	}

	PropertyTarget findProperty(const ref DbusMessage call)
	{
		auto values = call.body.values;
		auto propertyName = values[1].get!string;
		foreach (entry; propertyInterfaces(call, values[0].get!string))
			foreach (index, property; entry.implementation.description.properties)
				if (property.name.text == propertyName)
					return PropertyTarget(entry, index);
		throw new DbusError(DbusErrorNames.unknownProperty,
			"No such property '" ~ propertyName ~ "'");
	}

	Promise!DbusBody propertiesGet(const ref DbusMessage call)
	{
		auto target = findProperty(call);
		if (target.handlers.get is null)
			throw new DbusError(DbusErrorNames.invalidArgs,
				"Property '" ~ target.description.name.text ~ "' is not readable");
		return target.read().then((DbusVariant value) => DbusBody.from(value));
	}

	Promise!DbusBody propertiesSet(const ref DbusMessage call)
	{
		auto target = findProperty(call);
		auto property = target.description;
		if (target.handlers.set is null)
			throw new DbusError(DbusErrorNames.propertyReadOnly,
				"Property '" ~ property.name.text ~ "' is read-only");
		auto value = call.body.values[2].get!DbusVariant;
		if (value.containedSignature.text != property.type.text)
			throw new DbusError(DbusErrorNames.invalidArgs, "Property '" ~
				property.name.text ~ "' has type '" ~ property.type.text ~
				"', got '" ~ value.containedSignature.text ~ "'");
		return target.handlers.set(value).then(() => DbusBody.from());
	}

	/// Collects the readable properties; with an empty interface argument,
	/// a name shared by several interfaces takes the value of the first.
	/// If any getter fails, GetAll fails as a whole.
	Promise!DbusBody propertiesGetAll(const ref DbusMessage call)
	{
		string[] names;
		Promise!DbusVariant[] values;
		bool[string] seen;
		foreach (entry; propertyInterfaces(call, call.body.values[0].get!string))
			foreach (index, property; entry.implementation.description.properties)
			{
				auto name = property.name.text;
				if (property.access == DbusPropertyAccess.write || name in seen)
					continue;
				seen[name] = true;
				names ~= name;
				values ~= PropertyTarget(entry, index).read();
			}
		return all(values).then((DbusVariant[] results) {
			DbusVariant[string] dictionary;
			foreach (index, name; names)
				dictionary[name] = results[index];
			return DbusBody.from(dictionary);
		});
	}
}

/// One interface registered at one object path.
final class DbusInterfaceRegistration
{
	@property DbusObjectPath path() const { return path_; } ///
	@property DbusInterfaceName interfaceName() const { return entry_.implementation.description.name; } ///
	/// True until `unregister` is called.
	@property bool active() const { return registry_ !is null; }

	/// Stops serving the interface.  Calls already being handled still
	/// get their replies.
	void unregister()
	{
		assert(active, "D-Bus interface registration is not active");
		registry_.unregister(this);
		registry_ = null;
	}

private:
	DbusObjectRegistry registry_;
	DbusObjectPath path_;
	DbusInterfaceEntry entry_;

	this(DbusObjectRegistry registry, DbusObjectPath path, DbusInterfaceEntry entry)
	{
		registry_ = registry;
		path_ = path;
		entry_ = entry;
	}
}

/// Reads the machine ID from the first of `paths` that can be read (the
/// D-Bus reference implementation reads `/var/lib/dbus/machine-id`, then
/// `/etc/machine-id`).  Throws if none can be read, or if the first
/// readable file does not hold a valid machine ID.
package(ae.net.dbus) string readDbusMachineId(scope const(string)[] paths)
{
	import std.file : FileException, readText;
	import std.string : strip;

	foreach (path; paths)
	{
		string text;
		try
			text = readText(path);
		catch (FileException)
			continue;
		auto id = text.strip;
		if (id.length != 32)
			throw new DbusException("Invalid D-Bus machine ID in " ~ path);
		foreach (char c; id)
			if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')))
				throw new DbusException("Invalid D-Bus machine ID in " ~ path);
		return id;
	}
	throw new DbusException("Cannot read the D-Bus machine ID");
}

private:

enum dbusMachineIdPaths = ["/var/lib/dbus/machine-id", "/etc/machine-id"];

package(ae.net.dbus) struct DbusErrorNames
{
	static immutable unknownObject = DbusErrorName.parse("org.freedesktop.DBus.Error.UnknownObject");
	static immutable unknownInterface = DbusErrorName.parse("org.freedesktop.DBus.Error.UnknownInterface");
	static immutable unknownMethod = DbusErrorName.parse("org.freedesktop.DBus.Error.UnknownMethod");
	static immutable invalidArgs = DbusErrorName.parse("org.freedesktop.DBus.Error.InvalidArgs");
	static immutable unknownProperty = DbusErrorName.parse("org.freedesktop.DBus.Error.UnknownProperty");
	static immutable propertyReadOnly = DbusErrorName.parse("org.freedesktop.DBus.Error.PropertyReadOnly");
	static immutable failed = DbusErrorName.parse("org.freedesktop.DBus.Error.Failed");
}

/// An implementation together with what dispatch derives from its
/// description once, at registration.
struct DbusInterfaceEntry
{
	DbusInterfaceImplementation implementation;
	string[] inSignatures, outSignatures;
	/// The `<interface>` introspection fragment.
	string xml;

	/// Copies the whole description graph and the handler arrays of
	/// `implementation`, so that the caller cannot change a validated
	/// registration.
	this(DbusInterfaceImplementation implementation)
	{
		with (implementation)
		{
			description.methods = description.methods.dup;
			foreach (ref method; description.methods)
			{
				method.inArgs = method.inArgs.dup;
				method.outArgs = method.outArgs.dup;
			}
			description.signals = description.signals.dup;
			foreach (ref signal; description.signals)
				signal.args = signal.args.dup;
			description.properties = description.properties.dup;
			methods = methods.dup;
			properties = properties.dup;
		}
		this.implementation = implementation;
		foreach (method; implementation.description.methods)
		{
			inSignatures ~= dbusArgumentsSignature(method.inArgs).text;
			outSignatures ~= dbusArgumentsSignature(method.outArgs).text;
		}
		xml = dbusInterfaceXml(implementation.description);
	}
}

bool expectsReply(const ref DbusMessage call)
{
	return !(call.flags & DbusMessageFlag.noReplyExpected);
}

void validateImplementation(const ref DbusInterfaceImplementation implementation)
{
	auto description = &implementation.description;
	if (!description.name.text.length)
		throw new DbusValidationException("D-Bus interface descriptions require a name");
	string[] memberNames(T)(const(T)[] members)
	{
		string[] names;
		foreach (member; members)
			names ~= member.name.text;
		return names;
	}
	foreach (names; [memberNames(description.methods),
		memberNames(description.signals), memberNames(description.properties)])
		foreach (index, name; names)
		{
			if (!name.length)
				throw new DbusValidationException("D-Bus interface " ~
					description.name.text ~ " has a member without a name");
			foreach (other; names[0 .. index])
				if (other == name)
					throw new DbusValidationException("D-Bus interface " ~
						description.name.text ~ " declares " ~ name ~ " twice");
		}

	foreach (method; description.methods)
	{
		validateArguments(description.name.text, method.name.text, method.inArgs);
		validateArguments(description.name.text, method.name.text, method.outArgs);
	}
	foreach (signal; description.signals)
		validateArguments(description.name.text, signal.name.text, signal.args);
	foreach (property; description.properties)
		validateCompleteType(description.name.text, property.name.text, property.type);

	if (implementation.methods.length != description.methods.length ||
		implementation.properties.length != description.properties.length)
		throw new DbusValidationException("D-Bus interface " ~ description.name.text ~
			" handlers are not aligned with its description");
	foreach (index, handler; implementation.methods)
		if (handler is null)
			throw new DbusValidationException("D-Bus method " ~ description.name.text ~
				"." ~ description.methods[index].name.text ~ " has no handler");
	foreach (index, handlers; implementation.properties)
	{
		auto property = description.properties[index];
		auto readable = property.access != DbusPropertyAccess.write;
		auto writable = property.access != DbusPropertyAccess.read;
		if ((handlers.get !is null) != readable || (handlers.set !is null) != writable)
			throw new DbusValidationException("D-Bus property " ~ description.name.text ~
				"." ~ property.name.text ~ " handlers do not match its access");
	}
}

void validateArguments(string interfaceName, string member,
	const(DbusArgumentDescription)[] args)
{
	foreach (arg; args)
	{
		if (!isDbusArgumentName(arg.name))
			throw new DbusValidationException("D-Bus interface " ~ interfaceName ~
				" member " ~ member ~ " has an invalid argument name");
		validateCompleteType(interfaceName, member, arg.type);
	}
}

void validateCompleteType(string interfaceName, string member,
	DbusSignature type)
{
	try
		parseDbusVariantSignature(type.text);
	catch (DbusValidationException e)
		throw new DbusValidationException("D-Bus interface " ~ interfaceName ~
			" member " ~ member ~ " must use exactly one complete type per argument or property");
}

debug(ae_unittest)
{
	import ae.net.asockets : socketManager;
	import std.algorithm.searching : canFind;
	import ae.utils.promise : Promise;

	@DbusInterface("org.example.Service")
	interface DbusServiceTestInterface
	{
		Promise!int Add(int a, int b);
		Promise!void Act();
		Promise!void Unique();
		@DbusProperty Promise!double Volume();
		@DbusProperty Promise!void Volume(double value);
		@DbusProperty Promise!string Name();
		@DbusProperty Promise!void Secret(string value);
	}

	@DbusInterface("org.example.Other")
	interface DbusServiceTestOther
	{
		Promise!void Act();
		@DbusProperty Promise!string Name();
		@DbusProperty Promise!int Count();
	}

	/// A registry whose connection records what it sends.
	final class DbusServiceTestHarness
	{
		DbusObjectRegistry registry;
		DbusMessage[] sent;
		bool open = true;

		this()
		{
			registry = new DbusObjectRegistry((DbusMessage message) {
				assert(open);
				sent ~= message;
			}, () => open);
		}

		void dispatch(string path, string interfaceName, string member,
			DbusBody body = DbusBody.from(), ubyte flags = 0, uint serial = 7,
			string sender = ":1.99")
		{
			DbusMessage call;
			call.messageType = DbusMessageType.methodCall;
			call.serial = serial;
			call.flags = flags;
			if (sender.length)
				call.headers.sender = DbusBusName.parse(sender);
			call.headers.path = DbusObjectPath.parse(path);
			if (interfaceName.length)
				call.headers.interfaceName = DbusInterfaceName.parse(interfaceName);
			call.headers.member = DbusMemberName.parse(member);
			call.body = body;
			registry.dispatch(call);
		}

		/// The only message sent since the last call, which must be an
		/// error reply to serial 7 named `name`.
		string takeError(string name, uint serial = 7)
		{
			assert(sent.length == 1);
			auto reply = sent[0];
			sent = null;
			assert(reply.messageType == DbusMessageType.error);
			assert(reply.serial == 0);
			assert(reply.headers.errorName.text == "org.freedesktop.DBus.Error." ~ name ||
				reply.headers.errorName.text == name);
			assert(reply.headers.replySerial == serial);
			assert(reply.headers.destination.text == ":1.99");
			assert(reply.body.signature.text == "s");
			return reply.body.values[0].get!string;
		}

		DbusMessage takeReturn(string signature, uint serial = 7)
		{
			assert(sent.length == 1);
			auto reply = sent[0];
			sent = null;
			assert(reply.messageType == DbusMessageType.methodReturn);
			assert(reply.headers.replySerial == serial);
			assert(reply.headers.destination.text == ":1.99");
			assert(reply.body.signature.text == signature);
			return reply;
		}
	}

	/// An implementation of `DbusServiceTestInterface` whose methods
	/// record their calls and answer through `results`.
	final class DbusServiceTestObject
	{
		string[] calls;
		Promise!DbusBody delegate(const ref DbusMessage call)[string] results;
		/// Property values, keyed by "interface.Property".
		DbusVariant[string] values;
		/// When set, getters throw it.
		Exception getFailure;

		DbusInterfaceImplementation implementation(string interfaceName = null)
		{
			auto description = interfaceName.length ?
				dbusInterfaceDescription!DbusServiceTestOther :
				dbusInterfaceDescription!DbusServiceTestInterface;
			DbusInterfaceImplementation result;
			result.description = description;
			foreach (method; description.methods)
				result.methods ~= handler(method.name.text);
			foreach (property; description.properties)
				result.properties ~= propertyHandlers(
					description.name.text ~ "." ~ property.name.text, property.access);
			return result;
		}

		DbusPropertyHandlers propertyHandlers(string key, DbusPropertyAccess access)
		{
			DbusPropertyHandlers handlers;
			if (access != DbusPropertyAccess.write)
				handlers.get = {
					if (getFailure !is null)
						throw getFailure;
					return resolve(values[key]);
				};
			if (access != DbusPropertyAccess.read)
				handlers.set = (DbusVariant value) {
					values[key] = value;
					return resolve();
				};
			return handlers;
		}

		DbusMethodHandler handler(string name)
		{
			return (const ref DbusMessage call) {
				calls ~= name;
				return results[name](call);
			};
		}

		this()
		{
			results["Add"] = (const ref DbusMessage call) => resolve(DbusBody.from(
				call.body.values[0].get!int + call.body.values[1].get!int));
			results["Act"] = (const ref DbusMessage call) => resolve(DbusBody.from());
			results["Unique"] = (const ref DbusMessage call) => resolve(DbusBody.from());
			values["org.example.Service.Volume"] = DbusVariant.of(0.25);
			values["org.example.Service.Name"] = DbusVariant.of("service");
			values["org.example.Other.Name"] = DbusVariant.of("other");
			values["org.example.Other.Count"] = DbusVariant.of(3);
		}
	}
}

// Routing and the built-in error replies, which are sent synchronously.
debug(ae_unittest) unittest
{
	auto harness = new DbusServiceTestHarness;
	auto object = new DbusServiceTestObject;
	auto path = DbusObjectPath.parse("/org/example/a");
	harness.registry.register(path, object.implementation);
	harness.registry.register(path, object.implementation("org.example.Other"));

	harness.dispatch("/org/example/b", "org.example.Service", "Add", DbusBody.from(1, 2));
	assert(harness.takeError("UnknownObject") == "No such object path '/org/example/b'");
	// An ancestor of an object has only the Peer and Introspectable interfaces.
	harness.dispatch("/org/example", "org.example.Service", "Add", DbusBody.from(1, 2));
	harness.takeError("UnknownInterface");

	harness.dispatch("/org/example/a", "org.example.Missing", "Add", DbusBody.from(1, 2));
	assert(harness.takeError("UnknownInterface") ==
		"No such interface 'org.example.Missing' at object path '/org/example/a'");

	harness.dispatch("/org/example/a", "org.example.Service", "Missing");
	assert(harness.takeError("UnknownMethod") ==
		"No such method 'Missing' in interface 'org.example.Service'");
	harness.dispatch("/org/example/a", null, "Missing");
	assert(harness.takeError("UnknownMethod") ==
		"No such method 'Missing' at object path '/org/example/a'");
	harness.dispatch("/org/example/a", null, "Act");
	assert(harness.takeError("UnknownMethod") ==
		"Ambiguous method 'Act' at object path '/org/example/a'");
	harness.dispatch("/org/example/a", "org.freedesktop.DBus.Peer", "Missing");
	harness.takeError("UnknownMethod");

	harness.dispatch("/org/example/a", "org.example.Service", "Add", DbusBody.from(1));
	assert(harness.takeError("InvalidArgs") ==
		"Method 'Add' expects signature 'ii', got 'i'");
	harness.dispatch("/anywhere", "org.freedesktop.DBus.Peer", "Ping", DbusBody.from("x"));
	assert(harness.takeError("InvalidArgs") ==
		"Method 'Ping' expects signature '', got 's'");
	assert(object.calls.length == 0);

	// A reply needs somewhere to go.
	bool missingSender;
	try
		harness.dispatch("/org/example/b", "org.example.Service", "Add",
			DbusBody.from(1, 2), 0, 7, null);
	catch (DbusProtocolException)
		missingSender = true;
	assert(missingSender);
	assert(harness.sent.length == 0);
}

// Handler replies are sent once their promise settles.
debug(ae_unittest) unittest
{
	auto harness = new DbusServiceTestHarness;
	auto object = new DbusServiceTestObject;
	auto path = DbusObjectPath.parse("/org/example/a");
	harness.registry.register(path, object.implementation);
	harness.registry.register(path, object.implementation("org.example.Other"));

	harness.dispatch("/org/example/a", "org.example.Service", "Add", DbusBody.from(2, 3));
	assert(object.calls == ["Add"]);
	assert(harness.sent.length == 0);
	socketManager.loop();
	assert(harness.takeReturn("i").body.values[0].get!int == 5);

	// Without an interface, a member found on exactly one interface,
	// including the standard ones, is dispatched there.
	harness.dispatch("/org/example/a", null, "Unique", DbusBody.from(), 0, 8);
	socketManager.loop();
	harness.takeReturn("", 8);
	assert(object.calls == ["Add", "Unique"]);
	harness.dispatch("/org/example/a", null, "Ping", DbusBody.from(), 0, 9);
	socketManager.loop();
	harness.takeReturn("", 9);

	// Peer is answered on every path, registered or not.
	harness.dispatch("/not/registered", "org.freedesktop.DBus.Peer", "Ping");
	socketManager.loop();
	harness.takeReturn("");

	auto pending = new Promise!DbusBody;
	object.results["Act"] = (const ref DbusMessage call) => pending;
	harness.dispatch("/org/example/a", "org.example.Service", "Act");
	socketManager.loop();
	assert(harness.sent.length == 0);
	pending.fulfill(DbusBody.from());
	socketManager.loop();
	harness.takeReturn("");
}

// Exception mapping and the declared out-signature.
debug(ae_unittest) unittest
{
	auto harness = new DbusServiceTestHarness;
	auto object = new DbusServiceTestObject;
	harness.registry.register(DbusObjectPath.parse("/a"), object.implementation);

	void expect(Promise!DbusBody delegate(const ref DbusMessage) result,
		string errorName, string errorMessage)
	{
		object.results["Act"] = result;
		harness.dispatch("/a", "org.example.Service", "Act");
		socketManager.loop();
		assert(harness.takeError(errorName) == errorMessage);
	}

	auto custom = DbusErrorName.parse("org.example.Error.Custom");
	expect(delegate Promise!DbusBody (const ref DbusMessage call) {
		throw new DbusError(custom, "custom failure");
	}, "org.example.Error.Custom", "custom failure");
	expect(delegate Promise!DbusBody (const ref DbusMessage call) {
		auto result = new Promise!DbusBody;
		result.reject(new DbusError(custom, null));
		return result;
	}, "org.example.Error.Custom", "org.example.Error.Custom");
	expect(delegate Promise!DbusBody (const ref DbusMessage call) {
		DbusMessage remoteReply;
		auto result = new Promise!DbusBody;
		result.reject(new DbusRemoteError(DbusErrorName.parse("org.example.Error.Remote"),
			"forwarded", remoteReply));
		return result;
	}, "Failed", "org.example.Error.Remote: forwarded");
	expect(delegate Promise!DbusBody (const ref DbusMessage call) {
		auto remote = new DbusRemoteError(DbusErrorName.parse("org.example.Error.Remote"),
			"forwarded", DbusMessage.init);
		throw new DbusError(remote.errorName, remote.remoteMessage);
	}, "org.example.Error.Remote", "forwarded");
	expect(delegate Promise!DbusBody (const ref DbusMessage call) {
		throw new Exception("plain failure");
	}, "Failed", "plain failure");
	expect(delegate Promise!DbusBody (const ref DbusMessage call) {
		auto result = new Promise!DbusBody;
		result.reject(new Exception("plain rejection"));
		return result;
	}, "Failed", "plain rejection");
	expect((const ref DbusMessage call) => resolve(DbusBody.from(1)),
		"Failed", "Method 'Act' returned signature 'i' instead of ''");
}

// Invalid handler errors still produce a reply to the original call.
debug(ae_unittest) unittest
{
	auto harness = new DbusServiceTestHarness;
	auto object = new DbusServiceTestObject;
	harness.registry.register(DbusObjectPath.parse("/a"), object.implementation);
	object.results["Act"] = delegate Promise!DbusBody (const ref DbusMessage call) {
		throw new DbusError(DbusErrorName.init, "invalid name");
	};
	harness.dispatch("/a", "org.example.Service", "Act", DbusBody.from(), 0, 41);
	socketManager.loop();
	assert(harness.takeError("Failed", 41).length);
}

// An invalid UTF-8 exception message is replaced by an encodable error.
debug(ae_unittest) unittest
{
	auto harness = new DbusServiceTestHarness;
	auto object = new DbusServiceTestObject;
	harness.registry.register(DbusObjectPath.parse("/a"), object.implementation);
	object.results["Act"] = delegate Promise!DbusBody (const ref DbusMessage call) {
		throw new Exception(cast(string) [cast(char) 0xff]);
	};
	harness.dispatch("/a", "org.example.Service", "Act", DbusBody.from(), 0, 42);
	socketManager.loop();
	assert(harness.takeError("Failed", 42).length);
}

// No reply is sent when none is expected or once the connection has
// closed; unregistering does not cancel replies to calls in progress.
debug(ae_unittest) unittest
{
	auto harness = new DbusServiceTestHarness;
	auto object = new DbusServiceTestObject;
	auto registration = harness.registry.register(DbusObjectPath.parse("/a"),
		object.implementation);

	harness.dispatch("/a", "org.example.Service", "Add", DbusBody.from(2, 3),
		DbusMessageFlag.noReplyExpected, 7, null);
	harness.dispatch("/missing", "org.example.Service", "Add", DbusBody.from(2, 3),
		DbusMessageFlag.noReplyExpected);
	object.results["Act"] = delegate Promise!DbusBody (const ref DbusMessage call) {
		auto result = new Promise!DbusBody;
		result.reject(new Exception("ignored"));
		return result;
	};
	harness.dispatch("/a", "org.example.Service", "Act", DbusBody.from(),
		DbusMessageFlag.noReplyExpected);
	socketManager.loop();
	assert(object.calls == ["Add", "Act"]);
	assert(harness.sent.length == 0);

	auto pending = new Promise!DbusBody;
	object.results["Act"] = (const ref DbusMessage call) => pending;
	harness.dispatch("/a", "org.example.Service", "Act");
	registration.unregister();
	assert(!registration.active);
	pending.fulfill(DbusBody.from());
	socketManager.loop();
	harness.takeReturn("");

	registration = harness.registry.register(DbusObjectPath.parse("/a"),
		object.implementation);
	auto late = new Promise!DbusBody;
	object.results["Act"] = (const ref DbusMessage call) => late;
	harness.dispatch("/a", "org.example.Service", "Act");
	auto lateFailure = new Promise!DbusBody;
	object.results["Act"] = (const ref DbusMessage call) => lateFailure;
	harness.dispatch("/a", "org.example.Service", "Act");
	harness.open = false;
	late.fulfill(DbusBody.from());
	lateFailure.reject(new Exception("too late"));
	socketManager.loop();
	assert(harness.sent.length == 0);
}

// Registration rules and unregistration.
debug(ae_unittest) unittest
{
	auto harness = new DbusServiceTestHarness;
	auto object = new DbusServiceTestObject;
	auto path = DbusObjectPath.parse("/a");

	void expectRejected(DbusObjectPath path, DbusInterfaceImplementation implementation)
	{
		bool rejected;
		try
			harness.registry.register(path, implementation);
		catch (DbusValidationException)
			rejected = true;
		assert(rejected);
	}

	auto service = harness.registry.register(path, object.implementation);
	auto other = harness.registry.register(path, object.implementation("org.example.Other"));
	assert(service.path.text == "/a" && service.active);
	assert(other.interfaceName.text == "org.example.Other");
	expectRejected(path, object.implementation);
	expectRejected(DbusObjectPath.init, object.implementation);

	foreach (description; [dbusPeerDescription, dbusIntrospectableDescription,
		dbusPropertiesDescription])
	{
		DbusInterfaceImplementation standard;
		standard.description = description;
		foreach (method; description.methods)
			standard.methods ~= (const ref DbusMessage call) => resolve(DbusBody.from());
		expectRejected(DbusObjectPath.parse("/b"), standard);
	}

	auto bad = object.implementation;
	bad.description.name = DbusInterfaceName.init;
	expectRejected(DbusObjectPath.parse("/b"), bad);
	bad = object.implementation;
	bad.methods = bad.methods[0 .. $ - 1];
	expectRejected(DbusObjectPath.parse("/b"), bad);
	bad = object.implementation;
	bad.properties = bad.properties[0 .. $ - 1];
	expectRejected(DbusObjectPath.parse("/b"), bad);
	bad = object.implementation;
	bad.methods[0] = null;
	expectRejected(DbusObjectPath.parse("/b"), bad);
	foreach (index; 0 .. 3)
	{
		bad = object.implementation;
		bad.properties = bad.properties.dup;
		bad.properties[index] = DbusPropertyHandlers.init;
		expectRejected(DbusObjectPath.parse("/b"), bad);
	}
	bad = object.implementation;
	bad.properties = bad.properties.dup;
	bad.properties[1].set = (DbusVariant) => resolve();
	expectRejected(DbusObjectPath.parse("/b"), bad);
	bad = object.implementation;
	bad.description.methods = bad.description.methods.dup;
	bad.description.methods[1].name = bad.description.methods[0].name;
	expectRejected(DbusObjectPath.parse("/b"), bad);
	bad = object.implementation;
	bad.description.properties = bad.description.properties.dup;
	bad.description.properties[2].name = DbusMemberName.init;
	expectRejected(DbusObjectPath.parse("/b"), bad);

	// Methods, signals and properties are separate namespaces.
	auto shared_ = object.implementation;
	shared_.description.name = DbusInterfaceName.parse("org.example.Shared");
	shared_.description.properties = shared_.description.properties.dup;
	shared_.description.properties[0].name = shared_.description.methods[0].name;
	harness.registry.register(DbusObjectPath.parse("/b"), shared_).unregister();

	service.unregister();
	assert(!service.active && other.active);
	harness.dispatch("/a", "org.example.Service", "Add", DbusBody.from(2, 3));
	harness.takeError("UnknownInterface");
	harness.dispatch("/a", null, "Act");
	socketManager.loop();
	harness.takeReturn("");
	other.unregister();
	harness.dispatch("/a", "org.example.Other", "Act");
	harness.takeError("UnknownObject");

	// The path and interface can be registered again.
	harness.registry.register(path, object.implementation);
}

/// A raw implementation with arguments in every nested array.
debug(ae_unittest)
DbusInterfaceImplementation dbusServiceTestMutable()
{
	DbusInterfaceImplementation implementation;
	implementation.description.name = DbusInterfaceName.parse("org.example.Mutable");
	implementation.description.methods = [DbusMethodDescription(DbusMemberName.parse("Echo"),
		[DbusArgumentDescription("input", DbusSignature.parse("s"))],
		[DbusArgumentDescription("output", DbusSignature.parse("i"))])];
	implementation.description.signals = [DbusSignalDescription(DbusMemberName.parse("Changed"),
		[DbusArgumentDescription("value", DbusSignature.parse("s"))])];
	implementation.description.properties = [DbusPropertyDescription(DbusMemberName.parse("Level"),
		DbusSignature.parse("i"), DbusPropertyAccess.read)];
	implementation.methods = [(const ref DbusMessage call) => resolve(DbusBody.from(5))];
	DbusPropertyHandlers level;
	level.get = () => resolve(DbusVariant.of(7));
	implementation.properties = [level];
	return implementation;
}

/// Changes everything `implementation` shares with its registration.
debug(ae_unittest)
void dbusServiceTestMutate(ref DbusInterfaceImplementation implementation)
{
	foreach (ref method; implementation.description.methods)
	{
		method.inArgs[0] = DbusArgumentDescription("x", DbusSignature.parse("b"));
		method.outArgs[0] = DbusArgumentDescription("y", DbusSignature.parse("b"));
		method.inArgs = null;
		method.outArgs = null;
	}
	implementation.description.signals[0].args[0] =
		DbusArgumentDescription("z", DbusSignature.parse("b"));
	implementation.description.signals[0].args = null;
	implementation.description.properties[0].type = DbusSignature.parse("b");
	implementation.methods[0] = null;
}

// A registration is independent of every array it was made from.
debug(ae_unittest) unittest
{
	auto harness = new DbusServiceTestHarness;
	auto implementation = dbusServiceTestMutable();
	harness.registry.register(DbusObjectPath.parse("/a"), implementation);
	dbusServiceTestMutate(implementation);

	harness.dispatch("/a", "org.example.Mutable", "Echo", DbusBody.from("text"));
	socketManager.loop();
	assert(harness.takeReturn("i").body.values[0].get!int == 5);
	harness.dispatch("/a", "org.example.Mutable", "Echo", DbusBody.from(true));
	harness.takeError("InvalidArgs");
}

// Raw descriptions are validated where they enter the registry: argument
// names must be empty or identifiers, and every argument and property
// type exactly one complete type.
debug(ae_unittest) unittest
{
	auto harness = new DbusServiceTestHarness;
	auto path = DbusObjectPath.parse("/a");

	DbusInterfaceImplementation make(DbusArgumentDescription inArg, DbusArgumentDescription outArg,
		DbusArgumentDescription signalArg, DbusSignature propertyType)
	{
		DbusInterfaceImplementation implementation;
		implementation.description.name = DbusInterfaceName.parse("org.example.Raw");
		implementation.description.methods = [DbusMethodDescription(DbusMemberName.parse("Do"),
			[inArg], [outArg])];
		implementation.description.signals = [DbusSignalDescription(
			DbusMemberName.parse("Done"), [signalArg])];
		implementation.description.properties = [DbusPropertyDescription(
			DbusMemberName.parse("Level"), propertyType, DbusPropertyAccess.read)];
		implementation.methods = [(const ref DbusMessage call) => resolve(DbusBody.from())];
		DbusPropertyHandlers level;
		level.get = () => resolve(DbusVariant.of(7));
		implementation.properties = [level];
		return implementation;
	}
	auto s = DbusSignature.parse("s");
	auto good = DbusArgumentDescription("ok_1", s);

	bool accepted(DbusInterfaceImplementation implementation)
	{
		try
			harness.registry.register(path, implementation).unregister();
		catch (DbusValidationException)
			return false;
		return true;
	}

	assert(accepted(make(good, good, good, s)));
	assert(accepted(make(DbusArgumentDescription("", s), good, good, s)));
	assert(accepted(make(DbusArgumentDescription("_", s), good, good, s)));
	foreach (name; ["a<b", "a>b", "a&b", "a\"b", "a'b", "a b", "1a", "a-b", "a.b", "\u00e9"])
	{
		auto bad = DbusArgumentDescription(name, s);
		assert(!accepted(make(bad, good, good, s)));
		assert(!accepted(make(good, bad, good, s)));
		assert(!accepted(make(good, good, bad, s)));
	}

	// An empty type (an uninitialised signature) or several types.
	foreach (type; [DbusSignature.init, DbusSignature.parse("ss"), DbusSignature.parse("si")])
	{
		assert(!accepted(make(DbusArgumentDescription("a", type), good, good, s)));
		assert(!accepted(make(good, DbusArgumentDescription("a", type), good, s)));
		assert(!accepted(make(good, good, DbusArgumentDescription("a", type), s)));
		assert(!accepted(make(good, good, good, type)));
	}
	auto complex = DbusSignature.parse("a{s(iv)}");
	assert(accepted(make(DbusArgumentDescription("a", complex), good, good, complex)));
}

// Introspection of registered objects and their ancestors.
debug(ae_unittest) unittest
{
	auto harness = new DbusServiceTestHarness;
	auto object = new DbusServiceTestObject;
	harness.registry.register(DbusObjectPath.parse("/a/b"), object.implementation);
	harness.registry.register(DbusObjectPath.parse("/a/b"),
		object.implementation("org.example.Other"));
	harness.registry.register(DbusObjectPath.parse("/a/c/d"),
		object.implementation("org.example.Other"));
	harness.registry.register(DbusObjectPath.parse("/ab"),
		object.implementation("org.example.Other"));

	string introspect(string path)
	{
		harness.dispatch(path, "org.freedesktop.DBus.Introspectable", "Introspect");
		socketManager.loop();
		return harness.takeReturn("s").body.values[0].get!string;
	}

	assert(introspect("/") ==
`<!DOCTYPE node PUBLIC "-//freedesktop//DTD D-BUS Object Introspection 1.0//EN"
"http://www.freedesktop.org/standards/dbus/1.0/introspect.dtd">
<node>
  <interface name="org.freedesktop.DBus.Peer">
    <method name="Ping"/>
    <method name="GetMachineId">
      <arg type="s" direction="out"/>
    </method>
  </interface>
  <interface name="org.freedesktop.DBus.Introspectable">
    <method name="Introspect">
      <arg type="s" direction="out"/>
    </method>
  </interface>
  <node name="a"/>
  <node name="ab"/>
</node>
`);
	assert(introspect("/a") == dbusNodeXml([dbusPeerXml, dbusIntrospectableXml], ["b", "c"]));
	assert(introspect("/a/c") == dbusNodeXml([dbusPeerXml, dbusIntrospectableXml], ["d"]));
	assert(introspect("/a/b") == dbusNodeXml([dbusPeerXml, dbusIntrospectableXml,
		dbusPropertiesXml, dbusIntrospectionXml!DbusServiceTestInterface,
		dbusIntrospectionXml!DbusServiceTestOther], null));

	// Unqualified calls reach the interfaces of objects and ancestors.
	harness.dispatch("/a/b", null, "Introspect");
	socketManager.loop();
	harness.takeReturn("s");
	harness.dispatch("/a", null, "Introspect");
	socketManager.loop();
	harness.takeReturn("s");
	harness.dispatch("/a", null, "Ping");
	socketManager.loop();
	harness.takeReturn("");
	harness.dispatch("/a", "org.freedesktop.DBus.Properties", "GetAll", DbusBody.from(""));
	harness.takeError("UnknownInterface");
	harness.dispatch("/a", null, "GetAll", DbusBody.from(""));
	harness.takeError("UnknownMethod");

	harness.dispatch("/a/x", "org.freedesktop.DBus.Introspectable", "Introspect");
	assert(harness.takeError("UnknownObject") == "No such object path '/a/x'");
	harness.dispatch("/a/b/c", "org.freedesktop.DBus.Introspectable", "Introspect");
	harness.takeError("UnknownObject");
	harness.dispatch("/a/b", "org.freedesktop.DBus.Introspectable", "Introspect",
		DbusBody.from(1));
	harness.takeError("InvalidArgs");

	auto empty = new DbusServiceTestHarness;
	empty.dispatch("/", "org.freedesktop.DBus.Introspectable", "Introspect");
	socketManager.loop();
	assert(empty.takeReturn("s").body.values[0].get!string ==
		dbusNodeXml([dbusPeerXml, dbusIntrospectableXml], null));
}

// Introspection reflects the registered contract, not later changes to the
// arrays it was registered from.
debug(ae_unittest) unittest
{
	auto harness = new DbusServiceTestHarness;
	auto implementation = dbusServiceTestMutable();
	harness.registry.register(DbusObjectPath.parse("/a"), implementation);

	string introspect()
	{
		harness.dispatch("/a", "org.freedesktop.DBus.Introspectable", "Introspect");
		socketManager.loop();
		return harness.takeReturn("s").body.values[0].get!string;
	}
	auto before = introspect();
	assert(before.canFind(`<arg name="input" type="s" direction="in"/>`));
	assert(before.canFind(`<arg name="output" type="i" direction="out"/>`));
	assert(before.canFind(`<arg name="value" type="s"/>`));
	assert(before.canFind(`<property name="Level" type="i" access="read"/>`));

	dbusServiceTestMutate(implementation);
	assert(introspect() == before);
}

// The Properties interface of registered objects.
debug(ae_unittest) unittest
{
	auto harness = new DbusServiceTestHarness;
	auto object = new DbusServiceTestObject;
	auto path = DbusObjectPath.parse("/a");
	harness.registry.register(path, object.implementation);
	harness.registry.register(path, object.implementation("org.example.Other"));

	enum properties = "org.freedesktop.DBus.Properties";
	DbusVariant get(string interfaceName, string property)
	{
		harness.dispatch("/a", properties, "Get", DbusBody.from(interfaceName, property));
		socketManager.loop();
		return harness.takeReturn("v").body.values[0].get!DbusVariant;
	}
	string getError(string interfaceName, string property, string errorName)
	{
		harness.dispatch("/a", properties, "Get", DbusBody.from(interfaceName, property));
		socketManager.loop();
		return harness.takeError(errorName);
	}
	string setError(string interfaceName, string property, DbusVariant value,
		string errorName)
	{
		harness.dispatch("/a", properties, "Set",
			DbusBody.from(interfaceName, property, value));
		socketManager.loop();
		return harness.takeError(errorName);
	}
	DbusVariant[string] getAll(string interfaceName)
	{
		harness.dispatch("/a", properties, "GetAll", DbusBody.from(interfaceName));
		socketManager.loop();
		return harness.takeReturn("a{sv}").body.values[0].get!(DbusVariant[string]);
	}

	assert(get("org.example.Service", "Volume").get!double == 0.25);
	assert(get("org.example.Other", "Name").get!string == "other");
	// An empty interface argument takes the first interface that has it.
	assert(get("", "Name").get!string == "service");
	assert(get("", "Count").get!int == 3);

	assert(getError("org.example.Service", "Secret", "InvalidArgs") ==
		"Property 'Secret' is not readable");
	assert(getError("org.example.Service", "Count", "UnknownProperty") ==
		"No such property 'Count'");
	assert(getError("org.example.Missing", "Volume", "UnknownInterface") ==
		"No such interface 'org.example.Missing' at object path '/a'");
	getError("org.freedesktop.DBus.Peer", "Volume", "UnknownProperty");
	harness.dispatch("/a", properties, "Get", DbusBody.from("org.example.Service"));
	assert(harness.takeError("InvalidArgs") ==
		"Method 'Get' expects signature 'ss', got 's'");

	object.values["org.example.Service.Name"] = DbusVariant.of(1);
	assert(getError("org.example.Service", "Name", "Failed") ==
		"Property 'Name' returned type 'i' instead of 's'");
	object.values["org.example.Service.Name"] = DbusVariant.of("service");
	object.getFailure = new DbusError(DbusErrorName.parse("org.example.Error.Busy"), "busy");
	assert(getError("org.example.Service", "Name", "org.example.Error.Busy") == "busy");
	object.getFailure = null;

	harness.dispatch("/a", properties, "Set",
		DbusBody.from("org.example.Service", "Volume", DbusVariant.of(0.5)));
	socketManager.loop();
	harness.takeReturn("");
	assert(object.values["org.example.Service.Volume"].get!double == 0.5);
	harness.dispatch("/a", null, "Set",
		DbusBody.from("", "Secret", DbusVariant.of("hidden")));
	socketManager.loop();
	harness.takeReturn("");
	assert(object.values["org.example.Service.Secret"].get!string == "hidden");

	assert(setError("org.example.Service", "Name", DbusVariant.of("x"), "PropertyReadOnly") ==
		"Property 'Name' is read-only");
	assert(setError("org.example.Service", "Volume", DbusVariant.of("loud"), "InvalidArgs") ==
		"Property 'Volume' has type 'd', got 's'");
	setError("org.example.Service", "Missing", DbusVariant.of(1), "UnknownProperty");
	setError("org.example.Missing", "Volume", DbusVariant.of(1.0), "UnknownInterface");
	assert(object.values["org.example.Service.Volume"].get!double == 0.5);

	auto service = getAll("org.example.Service");
	assert(service.length == 2);
	assert(service["Volume"].get!double == 0.5);
	assert(service["Name"].get!string == "service");
	auto merged = getAll("");
	assert(merged.length == 3);
	assert(merged["Name"].get!string == "service");
	assert(merged["Count"].get!int == 3);
	assert(getAll("org.freedesktop.DBus.Peer").length == 0);
	harness.dispatch("/a", properties, "GetAll", DbusBody.from("org.example.Missing"));
	socketManager.loop();
	harness.takeError("UnknownInterface");
	object.values["org.example.Other.Count"] = DbusVariant.of("three");
	harness.dispatch("/a", properties, "GetAll", DbusBody.from(""));
	socketManager.loop();
	harness.takeError("Failed");

	harness.dispatch("/b", properties, "GetAll", DbusBody.from(""));
	harness.takeError("UnknownObject");
}

debug(ae_unittest) unittest
{
	import std.conv : to;
	import std.file : remove, tempDir, write;
	import std.path : buildPath;
	import std.process : thisProcessID;

	auto prefix = buildPath(tempDir, "ae-dbus-machine-id-" ~ to!string(thisProcessID));
	auto first = prefix ~ "-first", second = prefix ~ "-second", missing = prefix ~ "-missing";
	scope(exit) foreach (file; [first, second]) remove(file);
	enum idA = "0123456789abcdef0123456789abcdef", idB = "fedcba9876543210fedcba9876543210";
	write(first, idA ~ "\n");
	write(second, idB);

	assert(readDbusMachineId([first, second]) == idA);
	assert(readDbusMachineId([missing, second]) == idB);

	bool expectFailure(scope const(string)[] paths)
	{
		try
			readDbusMachineId(paths);
		catch (DbusException)
			return true;
		return false;
	}
	assert(expectFailure([missing]));
	assert(expectFailure(null));
	foreach (invalid; ["0123", idA ~ "0", "0123456789ABCDEF0123456789abcdef", ""])
	{
		write(first, invalid);
		assert(expectFailure([first, second]));
	}
}

// Through a connection: replies take the next serial, a call that expects
// no reply consumes none, and a reply settled after disconnection is
// dropped.
version(Posix)
debug(ae_unittest) unittest
{
	import ae.net.dbus.client : attachDbusConnection;
	import ae.net.dbus.testing;

	auto transport = new DbusTestConnection;
	auto connection = attachDbusConnection(transport);
	connection.ready.ignoreResult();
	dbusTestAuthenticate(transport);

	auto object = new DbusServiceTestObject;
	auto path = DbusObjectPath.parse("/org/example/a");
	connection.objects.register(path, object.implementation);

	transport.receive(dbusTestMethodCall(31, ":1.99", path, "org.example.Service",
		"Add", DbusBody.from(4, 5), DbusMessageFlag.noReplyExpected));
	transport.receive(dbusTestMethodCall(32, ":1.99", path, "org.example.Service",
		"Add", DbusBody.from(4, 5)));
	socketManager.loop();
	assert(object.calls == ["Add", "Add"]);
	assert(transport.sent.length == 5);
	auto reply = dbusTestSentMessage(transport, 4);
	assert(reply.messageType == DbusMessageType.methodReturn);
	assert(reply.serial == 2);
	assert(reply.headers.replySerial == 32);
	assert(reply.headers.destination.text == ":1.99");
	assert(reply.body.values[0].get!int == 9);

	auto pending = new Promise!DbusBody;
	object.results["Act"] = (const ref DbusMessage call) => pending;
	transport.receive(dbusTestMethodCall(33, ":1.99", path, "org.example.Service",
		"Act", DbusBody.from()));
	connection.disconnect();
	pending.fulfill(DbusBody.from());
	socketManager.loop();
	assert(transport.sent.length == 5);
}

// A return body larger than the protocol limit gets an error reply.
version(Posix)
debug(ae_unittest) unittest
{
	import ae.net.dbus.client : attachDbusConnection;
	import ae.net.dbus.testing;
	import ae.net.dbus.marshal : dbusMaxMessageBytes;

	auto transport = new DbusTestConnection;
	auto connection = attachDbusConnection(transport);
	connection.ready.ignoreResult();
	dbusTestAuthenticate(transport);
	auto object = new DbusServiceTestObject;
	auto path = DbusObjectPath.parse("/a");
	object.results["Act"] = (const ref DbusMessage call) =>
		resolve(DbusBody.from(new char[cast(size_t) dbusMaxMessageBytes].idup));
	auto implementation = object.implementation;
	implementation.description.methods[1].outArgs =
		[DbusArgumentDescription("result", DbusSignature.parse("s"))];
	connection.objects.register(path, implementation);
	transport.receive(dbusTestMethodCall(43, ":1.99", path,
		"org.example.Service", "Act", DbusBody.from()));
	socketManager.loop();
	assert(transport.sent.length == 5);
	auto reply = dbusTestSentMessage(transport, 4);
	assert(reply.messageType == DbusMessageType.error);
	assert(reply.headers.errorName == DbusErrorNames.failed);
	assert(reply.headers.replySerial == 43);
	connection.disconnect();
}

// Promotion drops a late result and does not answer incoming Peer calls.
version(Posix)
debug(ae_unittest) unittest
{
	import ae.net.asockets : IConnection;
	import ae.net.dbus.client : attachDbusConnection;
	import ae.net.dbus.testing;
	import ae.sys.data : Data;

	auto transport = new DbusTestConnection;
	auto connection = attachDbusConnection(transport);
	connection.ready.ignoreResult();
	dbusTestAuthenticate(transport);
	auto object = new DbusServiceTestObject;
	auto path = DbusObjectPath.parse("/a");
	auto pending = new Promise!DbusBody;
	object.results["Act"] = (const ref DbusMessage call) => pending;
	auto registration = connection.objects.register(path, object.implementation);
	transport.receive(dbusTestMethodCall(44, ":1.99", path,
		"org.example.Service", "Act", DbusBody.from()));
	registration.unregister();
	connection.promoteToMonitor(["type='signal'"],
		(IConnection, Data, DbusUniqueName) {}).ignoreResult();
	auto sentAtPromotion = transport.sent.length;
	pending.fulfill(DbusBody.from());
	transport.receive(dbusTestMethodCall(45, ":1.99", path,
		"org.freedesktop.DBus.Peer", "Ping", DbusBody.from()));
	socketManager.loop();
	assert(transport.sent.length == sentAtPromotion);
	connection.disconnect();
}
