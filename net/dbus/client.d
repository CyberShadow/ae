/**
 * Asynchronous byte-only D-Bus message-bus client.
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

module ae.net.dbus.client;

import ae.sys.data : Data;
import ae.utils.promise : Promise;

import ae.net.asockets : ConnectionState, DisconnectType, IConnection,
	disconnectable;
import ae.net.dbus.codec : DbusFrameDecoder;
import ae.net.dbus.common;
import ae.net.dbus.match : DbusSignalMatch;
import ae.net.dbus.marshal : encodeDbusMessage;
import ae.net.dbus.value : DbusBody, DbusValue, DbusValueKind;

debug(ae_unittest)
import ae.net.asockets : SocketServer, socketManager;
debug(ae_unittest)
import ae.net.dbus.marshal : decodeDbusMessage;
debug(ae_unittest)
import ae.net.dbus.value : dbusTestMalformedBody;
debug(ae_unittest)
import ae.utils.array : asBytes;
debug(ae_unittest)
import core.exception : AssertError;
debug(ae_unittest)
import ae.sys.timing : TimerTask, setTimeout;
debug(ae_unittest)
import core.time : seconds;
debug(ae_unittest)
import std.file : exists, remove;

version(Posix)
import ae.net.dbus.address : DbusUnixAddressCandidate, parseDbusAddress,
	selectSessionBusAddresses, selectSystemBusAddresses;
version(Posix)
	import ae.net.asockets : SocketConnection;
else
	debug(ae_unittest)
		import ae.net.asockets : SocketConnection;
version(Posix)
import ae.net.dbus.auth : DbusAuthenticationResult,
	DbusExternalAuthenticator;
version(Posix)
import object : Throwable;
version(Posix)
import std.conv : to;
version(Posix)
debug(ae_unittest)
import core.sys.posix.unistd : getpid, getuid;

/**
 * A complete outgoing method call.  The raw client always expects a reply;
 * only the two request flags represented by DbusCallOptions are emitted.
 */
struct DbusMethodCall
{
	DbusBusName destination;
	DbusObjectPath path;
	DbusInterfaceName interfaceName;
	DbusMemberName member;
	DbusBody body;
	DbusCallOptions options;
}

private enum DbusConnectionState
{
	connecting,
	authenticating,
	awaitingHello,
	ready,
	terminal,
}

private enum DbusAttemptOutcome
{
	active,
	internalFallback,
	terminal,
}

private enum DbusPendingKind
{
	hello,
	ordinary,
}

private struct DbusPendingCall
{
	DbusPendingKind kind;
	Promise!DbusMessage promise;
}

private enum DbusRulePhase
{
	waitingForOwner,
	waitingForRemote,
	active,
	terminal,
}

private enum DbusOwnerWatchPhase
{
	waitingForRemote,
	seeding,
	known,
	terminal,
}

private enum DbusRemoteMatchPhase
{
	adding,
	active,
	removing,
	failedRemoval,
	terminal,
}

private final class DbusRuleState
{
	string key;
	DbusSignalMatch match;
	ulong[] registrationIds;
	DbusRulePhase phase;
	DbusRemoteMatchLease remoteLease;
	DbusOwnerWatch ownerWatch;
}

private final class DbusOwnerWatch
{
	DbusBusName name;
	DbusSignalMatch match;
	DbusRuleState[] dependentRules;
	DbusOwnerWatchPhase phase;
	ulong operationGeneration;
	bool known;
	bool hasOwner;
	DbusUniqueName owner;
	DbusRemoteMatchLease remoteLease;
}

private final class DbusRemoteMatchLease
{
	DbusRemoteMatchState state;
	DbusRuleState rule;
	DbusOwnerWatch watch;
}

private final class DbusRemoteMatchState
{
	string key;
	DbusRemoteMatchPhase phase;
	ulong operationGeneration;
	DbusRemoteMatchLease[] leases;
	Promise!void[] removalPromises;
	Exception removalFailure;
}

class DbusSubscription
{
private:
	DbusConnection connection_;
	ulong registrationId_;
	bool active_;
	bool unsubscribeStarted_;

	this(DbusConnection connection, ulong registrationId)
	{
		connection_ = connection;
		registrationId_ = registrationId;
		active_ = true;
	}

public:
	@property bool active() const
	{
		return active_;
	}

	Promise!void unsubscribe()
	{
		assert(!unsubscribeStarted_);
		unsubscribeStarted_ = true;
		return connection_.unsubscribeRegistration(registrationId_, this);
	}
}

private final class DbusSignalRegistration
{
	ulong id;
	DbusRuleState rule;
	DbusSubscription subscription;
	void delegate(const ref DbusSignalMessage) handler;
	bool active;
	bool dispatchActive;
	bool hasExpectedBodySignature;
	DbusSignature expectedBodySignature;
	Promise!DbusSubscription subscribePromise;
}

version(Posix)
private final class DbusCandidateExhaustionContext : Exception
{
	immutable size_t candidateIndex;
	immutable size_t candidateCount;

	this(size_t candidateIndex, size_t candidateCount)
	{
		assert(candidateIndex < candidateCount);
		super("D-Bus candidate exhaustion: final candidate index " ~
			candidateIndex.to!string ~ " of " ~ candidateCount.to!string ~
			" (zero-based)");
		this.candidateIndex = candidateIndex;
		this.candidateCount = candidateCount;
	}
}

/**
 * Owns one D-Bus connection lifecycle from transport establishment through
 * terminal settlement.  It is intentionally the sole owner of its current
 * transport's callbacks.
 */
class DbusConnection
{
private:
	Promise!DbusUniqueName readyPromise_;
	bool readySettled_;
	bool readySucceeded_;
	DbusUniqueName uniqueName_;

	DbusConnectionState state_;
	DbusAttemptOutcome attemptOutcome_;
	ulong generation_;
	IConnection transport_;
	DbusFrameDecoder decoder_;
	DbusServerGuid serverGuid_;
	Exception terminalCause_;

	uint nextSerial_ = 1;
	DbusPendingCall[uint] pendingCalls_;

	ulong nextRegistrationId_ = 1;
	DbusRuleState[string] rules_;
	DbusOwnerWatch[string] ownerWatches_;
	DbusRemoteMatchState[string] remoteMatches_;
	DbusSignalRegistration[ulong] registrations_;
	ulong[] registrationOrder_;

	version(Posix)
	{
		DbusUnixAddressCandidate[] candidates_;
		size_t candidateIndex_;
		bool attachedTransport_;
		DbusExternalAuthenticator authenticator_;

		alias AttemptFactory = IConnection delegate(DbusUnixAddressCandidate candidate);
		alias AttemptStarter = void delegate(IConnection transport,
			DbusUnixAddressCandidate candidate);
		AttemptFactory attemptFactory_;
		AttemptStarter attemptStarter_;
	}

	this()
	{
		readyPromise_ = new Promise!DbusUniqueName;
		decoder_ = new DbusFrameDecoder;
		state_ = DbusConnectionState.connecting;
		attemptOutcome_ = DbusAttemptOutcome.active;
	}

	static DbusMethodCall standardBusCall(string member, DbusBody body = DbusBody.init)
	{
		DbusMethodCall result;
		result.destination = DbusBusName.parse("org.freedesktop.DBus");
		result.path = DbusObjectPath.parse("/org/freedesktop/DBus");
		result.interfaceName = DbusInterfaceName.parse("org.freedesktop.DBus");
		result.member = DbusMemberName.parse(member);
		result.body = DbusBody.fromValues(body.values);
		return result;
	}

	static DbusMessage makeMessage(ref DbusMethodCall request, uint serial)
	{
		if (!request.destination.text.length)
			throw new DbusValidationException("D-Bus method calls require a destination");
		if (!request.path.text.length)
			throw new DbusValidationException("D-Bus method calls require a path");
		if (!request.interfaceName.text.length)
			throw new DbusValidationException("D-Bus method calls require an interface");
		if (!request.member.text.length)
			throw new DbusValidationException("D-Bus method calls require a member");

		DbusMessage result;
		result.messageType = DbusMessageType.methodCall;
		result.serial = serial;
		if (request.options.noAutoStart)
			result.flags |= DbusMessageFlag.noAutoStart;
		if (request.options.allowInteractiveAuthorization)
			result.flags |= DbusMessageFlag.allowInteractiveAuthorization;
		result.headers.destination = request.destination;
		result.headers.path = request.path;
		result.headers.interfaceName = request.interfaceName;
		result.headers.member = request.member;
		result.body = request.body;
		return result;
	}

	void validateCall(ref DbusMethodCall request)
	{
		auto validationMessage = makeMessage(request, 1);
		encodeDbusMessage(validationMessage);
	}

	uint allocateSerial()
	{
		while (true)
		{
			auto result = nextSerial_;
			nextSerial_ = result + 1;
			if (result != 0 && !(result in pendingCalls_))
				return result;
		}
	}

	void sendOrdinaryCall(ref DbusMethodCall request,
		Promise!DbusMessage promise)
	{
		assert(state_ == DbusConnectionState.ready);
		auto serial = allocateSerial();
		auto message = makeMessage(request, serial);
		auto frame = encodeDbusMessage(message);
		pendingCalls_[serial] = DbusPendingCall(DbusPendingKind.ordinary, promise);
		transport_.send(frame);
	}

	DbusRemoteError remoteError(DbusMessage reply)
	{
		assert(reply.messageType == DbusMessageType.error);
		assert(reply.headers.errorName.text.length);
		string remoteMessage;
		auto values = reply.body.values;
		if (values.length && values[0].kind == DbusValueKind.string_)
			remoteMessage = values[0].get!string();
		return new DbusRemoteError(reply.headers.errorName, remoteMessage, reply);
	}

	DbusUniqueName requireUniqueNameReply(const ref DbusMessage reply)
	{
		auto values = reply.body.values;
		if (reply.body.signature.text != "s" || values.length != 1)
			throw new DbusTypeMismatchException("expected one D-Bus unique name string");
		try
			return DbusUniqueName.parse(values[0].get!string());
		catch (DbusException)
			throw new DbusTypeMismatchException("expected a valid D-Bus unique name");
	}

	bool requireBooleanReply(const ref DbusMessage reply)
	{
		auto values = reply.body.values;
		if (reply.body.signature.text != "b" || values.length != 1)
			throw new DbusTypeMismatchException("expected one D-Bus boolean");
		try
			return values[0].get!bool();
		catch (DbusException)
			throw new DbusTypeMismatchException("expected one D-Bus boolean");
	}

	void requireEmptyReply(const ref DbusMessage reply)
	{
		if (reply.body.signature.text != "" || reply.body.values.length != 0)
			throw new DbusTypeMismatchException("expected an empty D-Bus method return");
	}

	ulong allocateRegistrationId()
	{
		while (true)
		{
			auto result = nextRegistrationId_;
			nextRegistrationId_ = result + 1;
			if (result != 0 && !(result in registrations_))
				return result;
		}
	}

	static void removeRegistrationId(ref ulong[] ids, ulong id)
	{
		foreach (index, candidate; ids)
			if (candidate == id)
			{
				ids = ids[0 .. index] ~ ids[index + 1 .. $];
				return;
			}
		assert(false);
	}

	static void removeDependentRule(ref DbusRuleState[] rules, DbusRuleState rule)
	{
		foreach (index, candidate; rules)
			if (candidate is rule)
			{
				rules = rules[0 .. index] ~ rules[index + 1 .. $];
				return;
			}
		assert(false);
	}

	static void removeRemoteLease(ref DbusRemoteMatchLease[] leases,
		DbusRemoteMatchLease lease)
	{
		foreach (index, candidate; leases)
			if (candidate is lease)
			{
				leases = leases[0 .. index] ~ leases[index + 1 .. $];
				return;
			}
		assert(false);
	}

	bool isCurrentRule(DbusRuleState rule)
	{
		auto current = rule.key in rules_;
		return current !is null && *current is rule;
	}

	bool isCurrentOwnerWatch(DbusOwnerWatch watch)
	{
		auto current = watch.name.text in ownerWatches_;
		return current !is null && *current is watch;
	}

	bool isCurrentRemoteMatch(DbusRemoteMatchState remote)
	{
		auto current = remote.key in remoteMatches_;
		return current !is null && *current is remote;
	}

	static bool isRemoteMatchDispatchable(DbusRemoteMatchState remote)
	{
		return remote !is null &&
			(remote.phase == DbusRemoteMatchPhase.adding || remote.phase == DbusRemoteMatchPhase.active);
	}

	void rejectSubscribe(DbusSignalRegistration registration, Exception cause)
	{
		registration.active = false;
		registration.dispatchActive = false;
		registration.subscription.active_ = false;
		if (registration.subscribePromise !is null)
		{
			auto promise = registration.subscribePromise;
			registration.subscribePromise = null;
			promise.reject(cause);
		}
	}

	void fulfillSubscribe(DbusSignalRegistration registration)
	{
		if (registration.subscribePromise is null)
			return;
		auto promise = registration.subscribePromise;
		registration.subscribePromise = null;
		promise.fulfill(registration.subscription);
	}

	void removeRegistration(DbusSignalRegistration registration)
	{
		assert(registration.id in registrations_);
		registrations_.remove(registration.id);
		removeRegistrationId(registration.rule.registrationIds, registration.id);
		removeRegistrationId(registrationOrder_, registration.id);
	}

	void rejectRuleRegistrations(DbusRuleState rule, Exception cause)
	{
		auto registrationIds = rule.registrationIds.dup;
		foreach (id; registrationIds)
		{
			auto current = id in registrations_;
			if (current is null)
				continue;
			auto registration = *current;
			rejectSubscribe(registration, cause);
			removeRegistration(registration);
		}
	}

	static bool isOrdinaryWellKnownName(DbusBusName name)
	{
		return name.text.length && name.text[0] != ':' &&
			name.text != "org.freedesktop.DBus";
	}

	static bool isMatchRuleNotFound(Exception exception)
	{
		auto remote = cast(DbusRemoteError) exception;
		return remote !is null &&
			remote.errorName.text == "org.freedesktop.DBus.Error.MatchRuleNotFound";
	}

	static bool isNameHasNoOwner(Exception exception)
	{
		auto remote = cast(DbusRemoteError) exception;
		return remote !is null &&
			remote.errorName.text == "org.freedesktop.DBus.Error.NameHasNoOwner";
	}

	static bool matchesFields(const ref DbusSignalMatch match,
		const ref DbusSignalMessage signal, DbusBusName destination,
		scope const(DbusValue)[] values)
	{
		if (match.hasPath && signal.path.text != match.path.text)
			return false;
		if (match.hasInterface && signal.interfaceName.text != match.interfaceName.text)
			return false;
		if (match.hasMember && signal.member.text != match.member.text)
			return false;
		if (match.hasDestination && destination.text != match.destination.text)
			return false;

		foreach (index; 0 .. 64)
			if (match.hasArgument(index))
			{
				if (index >= values.length || values[index].kind != DbusValueKind.string_ ||
					values[index].get!string() != match.argument(index))
					return false;
			}
		return true;
	}

	bool matchesRule(DbusRuleState rule, const ref DbusSignalMessage signal,
		DbusBusName destination, scope const(DbusValue)[] values,
		DbusSignalRegistration registration)
	{
		if (!matchesFields(rule.match, signal, destination, values))
			return false;
		if (rule.match.hasSender)
		{
			auto requested = rule.match.sender;
			if (isOrdinaryWellKnownName(requested))
			{
				auto watch = rule.ownerWatch;
				if (watch is null || !watch.known || !watch.hasOwner ||
					watch.owner.text != signal.sender.text)
					return false;
			}
			else if (signal.sender.text != requested.text)
				return false;
		}
		return !registration.hasExpectedBodySignature ||
			signal.body.signature.text == registration.expectedBodySignature.text;
	}

	static DbusSignalMatch ownerWatchMatch(DbusBusName name)
	{
		return DbusSignalMatch.signal()
			.withSender(DbusBusName.parse("org.freedesktop.DBus"))
			.withInterface(DbusInterfaceName.parse("org.freedesktop.DBus"))
			.withMember(DbusMemberName.parse("NameOwnerChanged"))
			.withPath(DbusObjectPath.parse("/org/freedesktop/DBus"))
			.withArgument(0, name.text);
	}

	void releaseOwnerWatch(DbusRuleState rule)
	{
		auto watch = rule.ownerWatch;
		if (watch is null)
			return;
		rule.ownerWatch = null;
		removeDependentRule(watch.dependentRules, rule);
		if (!watch.dependentRules.length)
			releaseIdleOwnerWatch(watch);
	}

	void rejectRuleSetup(DbusRuleState rule, Exception cause)
	{
		if (!isCurrentRule(rule))
			return;
		rule.phase = DbusRulePhase.terminal;
		rules_.remove(rule.key);
		releaseOwnerWatch(rule);
		rejectRuleRegistrations(rule, cause);
	}

	void releaseIdleOwnerWatch(DbusOwnerWatch watch)
	{
		if (!isCurrentOwnerWatch(watch))
			return;
		watch.phase = DbusOwnerWatchPhase.terminal;
		watch.operationGeneration++;
		ownerWatches_.remove(watch.name.text);
		auto lease = watch.remoteLease;
		watch.remoteLease = null;
		releaseRemoteMatch(lease);
	}

	void failOwnerWatchRemote(DbusOwnerWatch watch, Exception cause)
	{
		if (!isCurrentOwnerWatch(watch))
			return;
		watch.phase = DbusOwnerWatchPhase.terminal;
		watch.operationGeneration++;
		ownerWatches_.remove(watch.name.text);
		watch.remoteLease = null;
		auto dependentRules = watch.dependentRules.dup;
		watch.dependentRules = null;
		foreach (rule; dependentRules)
			if (isCurrentRule(rule) && rule.ownerWatch is watch)
			{
				rule.ownerWatch = null;
				rejectRuleSetup(rule, cause);
			}
	}

	void failOwnerWatchSeed(DbusOwnerWatch watch, Exception cause)
	{
		if (!isCurrentOwnerWatch(watch))
			return;
		auto dependentRules = watch.dependentRules.dup;
		watch.dependentRules = null;
		foreach (rule; dependentRules)
			if (isCurrentRule(rule) && rule.ownerWatch is watch)
			{
				rule.ownerWatch = null;
				rule.phase = DbusRulePhase.terminal;
				rules_.remove(rule.key);
			}
		watch.phase = DbusOwnerWatchPhase.terminal;
		watch.operationGeneration++;
		ownerWatches_.remove(watch.name.text);
		auto lease = watch.remoteLease;
		watch.remoteLease = null;
		releaseRemoteMatch(lease);
		foreach (rule; dependentRules)
			rejectRuleRegistrations(rule, cause);
	}

	void activateOwnerWatchDependents(DbusOwnerWatch watch)
	{
		if (!isCurrentOwnerWatch(watch) || !watch.known ||
			watch.phase != DbusOwnerWatchPhase.known)
			return;
		auto dependentRules = watch.dependentRules.dup;
		foreach (rule; dependentRules)
			if (isCurrentRule(rule) && rule.ownerWatch is watch &&
				rule.phase == DbusRulePhase.waitingForOwner)
				startRuleRemote(rule);
	}

	void finishOwnerWatchSeed(DbusOwnerWatch watch, ulong operation,
		DbusUniqueName owner)
	{
		if (state_ == DbusConnectionState.terminal || !isCurrentOwnerWatch(watch) ||
			watch.phase != DbusOwnerWatchPhase.seeding ||
			watch.operationGeneration != operation)
			return;
		// processOwnerWatchSignal always advances phase to known in the
		// same step as observing a NameOwnerChanged signal, so a watch
		// still in the seeding phase cannot have observed one since this
		// seed started.
		assert(!watch.known);
		watch.known = true;
		watch.hasOwner = true;
		watch.owner = owner;
		watch.phase = DbusOwnerWatchPhase.known;
		if (!watch.dependentRules.length)
			releaseIdleOwnerWatch(watch);
		else
			activateOwnerWatchDependents(watch);
	}

	void finishOwnerWatchNoOwner(DbusOwnerWatch watch, ulong operation,
		Exception exception)
	{
		if (state_ == DbusConnectionState.terminal || !isCurrentOwnerWatch(watch) ||
			watch.phase != DbusOwnerWatchPhase.seeding ||
			watch.operationGeneration != operation)
			return;
		// processOwnerWatchSignal always advances phase to known in the
		// same step as observing a NameOwnerChanged signal, so a watch
		// still in the seeding phase cannot have observed one since this
		// seed started.
		assert(!watch.known);
		if (!isNameHasNoOwner(exception))
		{
			failOwnerWatchSeed(watch, exception);
			return;
		}
		watch.known = true;
		watch.hasOwner = false;
		watch.owner = DbusUniqueName.init;
		watch.phase = DbusOwnerWatchPhase.known;
		if (!watch.dependentRules.length)
			releaseIdleOwnerWatch(watch);
		else
			activateOwnerWatchDependents(watch);
	}

	void startOwnerWatchSeed(DbusOwnerWatch watch)
	{
		assert(isCurrentOwnerWatch(watch));
		assert(watch.phase == DbusOwnerWatchPhase.seeding);
		auto operation = ++watch.operationGeneration;
		auto raw = getNameOwner(watch.name);
		raw.then((DbusUniqueName owner) {
			finishOwnerWatchSeed(watch, operation, owner);
		}, (Exception exception) {
			finishOwnerWatchNoOwner(watch, operation, exception);
		}).ignoreResult();
	}

	void activateOwnerWatchRemote(DbusOwnerWatch watch)
	{
		if (state_ == DbusConnectionState.terminal || !isCurrentOwnerWatch(watch) ||
			watch.phase != DbusOwnerWatchPhase.waitingForRemote)
			return;
		watch.phase = DbusOwnerWatchPhase.seeding;
		startOwnerWatchSeed(watch);
	}

	void activateRemoteLease(DbusRemoteMatchLease lease)
	{
		assert(lease.state !is null);
		if (lease.rule !is null)
			activateRuleRemote(lease.rule);
		else
		{
			assert(lease.watch !is null);
			activateOwnerWatchRemote(lease.watch);
		}
	}

	void failRemoteLease(DbusRemoteMatchLease lease, Exception cause)
	{
		if (lease.rule !is null)
		{
			auto rule = lease.rule;
			assert(rule.remoteLease is lease);
			rule.remoteLease = null;
			rejectRuleSetup(rule, cause);
			return;
		}
		assert(lease.watch !is null);
		auto watch = lease.watch;
		assert(watch.remoteLease is lease);
		watch.remoteLease = null;
		failOwnerWatchRemote(watch, cause);
	}

	void fulfillRemoteRemovalPromises(DbusRemoteMatchState remote)
	{
		auto promises = remote.removalPromises.dup;
		remote.removalPromises = null;
		foreach (promise; promises)
			promise.fulfill();
	}

	void rejectRemoteRemovalPromises(DbusRemoteMatchState remote, Exception cause)
	{
		auto promises = remote.removalPromises.dup;
		remote.removalPromises = null;
		foreach (promise; promises)
			promise.reject(cause);
	}

	void failRemoteMatchSetup(DbusRemoteMatchState remote, Exception cause)
	{
		if (!isCurrentRemoteMatch(remote))
			return;
		remote.phase = DbusRemoteMatchPhase.terminal;
		remote.operationGeneration++;
		remoteMatches_.remove(remote.key);
		auto leases = remote.leases.dup;
		remote.leases = null;
		foreach (lease; leases)
			if (lease.state is remote)
			{
				lease.state = null;
				failRemoteLease(lease, cause);
			}
		rejectRemoteRemovalPromises(remote, cause);
	}

	void failRemoteMatchRemoval(DbusRemoteMatchState remote, Exception cause)
	{
		if (!isCurrentRemoteMatch(remote))
			return;
		remote.phase = DbusRemoteMatchPhase.failedRemoval;
		remote.operationGeneration++;
		remote.removalFailure = cause;
		auto leases = remote.leases.dup;
		remote.leases = null;
		foreach (lease; leases)
			if (lease.state is remote)
			{
				lease.state = null;
				failRemoteLease(lease, cause);
			}
		rejectRemoteRemovalPromises(remote, cause);
	}

	void startRemoteMatchAdd(DbusRemoteMatchState remote)
	{
		assert(isCurrentRemoteMatch(remote));
		assert(remote.phase == DbusRemoteMatchPhase.adding);
		auto operation = ++remote.operationGeneration;
		auto raw = call(standardBusCall("AddMatch", DbusBody.from(remote.key)));
		raw.then((DbusMessage reply) {
			if (state_ == DbusConnectionState.terminal || !isCurrentRemoteMatch(remote) ||
				remote.phase != DbusRemoteMatchPhase.adding ||
				remote.operationGeneration != operation)
				return;
			try
				requireEmptyReply(reply);
			catch (DbusTypeMismatchException exception)
			{
				failRemoteMatchSetup(remote, exception);
				return;
			}
			remote.phase = DbusRemoteMatchPhase.active;
			auto leases = remote.leases.dup;
			foreach (lease; leases)
				if (lease.state is remote)
					activateRemoteLease(lease);
			if (!remote.leases.length)
				startRemoteMatchRemoval(remote);
		}, (Exception exception) {
			if (state_ != DbusConnectionState.terminal && isCurrentRemoteMatch(remote) &&
				remote.phase == DbusRemoteMatchPhase.adding &&
				remote.operationGeneration == operation)
				failRemoteMatchSetup(remote, exception);
		}).ignoreResult();
	}

	void finishRemoteMatchRemoval(DbusRemoteMatchState remote, ulong operation)
	{
		if (state_ == DbusConnectionState.terminal || !isCurrentRemoteMatch(remote) ||
			remote.phase != DbusRemoteMatchPhase.removing ||
			remote.operationGeneration != operation)
			return;
		if (!remote.leases.length)
		{
			remote.phase = DbusRemoteMatchPhase.terminal;
			remote.operationGeneration++;
			remoteMatches_.remove(remote.key);
			fulfillRemoteRemovalPromises(remote);
			return;
		}
		remote.phase = DbusRemoteMatchPhase.adding;
		assert(isRemoteMatchDispatchable(remote));
		foreach (lease; remote.leases)
			if (lease.rule !is null)
				activateRuleDispatch(lease.rule);
		startRemoteMatchAdd(remote);
		fulfillRemoteRemovalPromises(remote);
	}

	void startRemoteMatchRemoval(DbusRemoteMatchState remote)
	{
		if (state_ == DbusConnectionState.terminal || !isCurrentRemoteMatch(remote) ||
			remote.leases.length || remote.phase == DbusRemoteMatchPhase.removing ||
			remote.phase == DbusRemoteMatchPhase.failedRemoval ||
			remote.phase == DbusRemoteMatchPhase.terminal)
			return;
		if (remote.phase == DbusRemoteMatchPhase.adding)
			return;
		assert(remote.phase == DbusRemoteMatchPhase.active);
		remote.phase = DbusRemoteMatchPhase.removing;
		auto operation = ++remote.operationGeneration;
		auto raw = call(standardBusCall("RemoveMatch", DbusBody.from(remote.key)));
		raw.then((DbusMessage reply) {
			if (state_ == DbusConnectionState.terminal || !isCurrentRemoteMatch(remote) ||
				remote.phase != DbusRemoteMatchPhase.removing ||
				remote.operationGeneration != operation)
				return;
			try
				requireEmptyReply(reply);
			catch (DbusTypeMismatchException exception)
			{
				failRemoteMatchRemoval(remote, exception);
				return;
			}
			finishRemoteMatchRemoval(remote, operation);
		}, (Exception exception) {
			if (state_ != DbusConnectionState.terminal && isCurrentRemoteMatch(remote) &&
				remote.phase == DbusRemoteMatchPhase.removing &&
				remote.operationGeneration == operation)
			{
				if (isMatchRuleNotFound(exception))
					finishRemoteMatchRemoval(remote, operation);
				else
					failRemoteMatchRemoval(remote, exception);
			}
		}).ignoreResult();
	}

	void acquireRemoteMatch(DbusRemoteMatchLease lease, string key)
	{
		auto current = key in remoteMatches_;
		DbusRemoteMatchState remote;
		if (current is null)
		{
			remote = new DbusRemoteMatchState;
			remote.key = key;
			remote.phase = DbusRemoteMatchPhase.adding;
			remoteMatches_[key] = remote;
		}
		else
			remote = *current;
		if (remote.phase == DbusRemoteMatchPhase.failedRemoval)
		{
			failRemoteLease(lease, remote.removalFailure);
			return;
		}
		assert(remote.phase != DbusRemoteMatchPhase.terminal);
		lease.state = remote;
		remote.leases ~= lease;
		if (current is null)
			startRemoteMatchAdd(remote);
		else if (remote.phase == DbusRemoteMatchPhase.active)
			activateRemoteLease(lease);
	}

	void releaseRemoteMatch(DbusRemoteMatchLease lease,
		Promise!void removalPromise = null)
	{
		assert(lease !is null);
		auto remote = lease.state;
		assert(remote !is null && isCurrentRemoteMatch(remote));
		removeRemoteLease(remote.leases, lease);
		lease.state = null;
		if (remote.leases.length)
		{
			if (removalPromise !is null)
				removalPromise.fulfill();
			return;
		}
		if (removalPromise !is null)
			remote.removalPromises ~= removalPromise;
		if (remote.phase == DbusRemoteMatchPhase.active)
			startRemoteMatchRemoval(remote);
		else if (remote.phase == DbusRemoteMatchPhase.adding ||
			remote.phase == DbusRemoteMatchPhase.removing)
			return;
		else
			assert(false);
	}

	DbusOwnerWatch acquireOwnerWatch(DbusRuleState rule)
	{
		assert(rule.match.hasSender);
		auto name = rule.match.sender;
		assert(isOrdinaryWellKnownName(name));
		auto current = name.text in ownerWatches_;
		DbusOwnerWatch watch;
		if (current is null)
		{
			watch = new DbusOwnerWatch;
			watch.name = name;
			watch.match = ownerWatchMatch(name);
			watch.phase = DbusOwnerWatchPhase.waitingForRemote;
			ownerWatches_[name.text] = watch;
		}
		else
			watch = *current;
		assert(watch.phase != DbusOwnerWatchPhase.terminal);
		watch.dependentRules ~= rule;
		rule.ownerWatch = watch;
		if (current is null)
		{
			auto lease = new DbusRemoteMatchLease;
			lease.watch = watch;
			watch.remoteLease = lease;
			acquireRemoteMatch(lease, watch.match.canonicalRule);
		}
		else if (watch.phase == DbusOwnerWatchPhase.known)
			activateOwnerWatchDependents(watch);
		return watch;
	}

	void activateRuleDispatch(DbusRuleState rule)
	{
		foreach (id; rule.registrationIds)
		{
			auto current = id in registrations_;
			assert(current !is null);
			(*current).dispatchActive = true;
		}
	}

	void activateRuleRemote(DbusRuleState rule)
	{
		if (state_ == DbusConnectionState.terminal || !isCurrentRule(rule) ||
			rule.phase != DbusRulePhase.waitingForRemote)
			return;
		activateRuleDispatch(rule);
		rule.phase = DbusRulePhase.active;
		auto registrationIds = rule.registrationIds.dup;
		foreach (id; registrationIds)
		{
			auto current = id in registrations_;
			assert(current !is null && (*current).active);
			fulfillSubscribe(*current);
		}
	}

	void startRuleRemote(DbusRuleState rule)
	{
		assert(isCurrentRule(rule));
		assert(rule.phase == DbusRulePhase.waitingForOwner);
		assert(rule.registrationIds.length);
		rule.phase = DbusRulePhase.waitingForRemote;
		auto lease = new DbusRemoteMatchLease;
		lease.rule = rule;
		rule.remoteLease = lease;
		acquireRemoteMatch(lease, rule.key);
		auto remote = lease.state;
		if (isRemoteMatchDispatchable(remote))
			activateRuleDispatch(rule);
	}

	void settleHello(DbusMessage reply)
	{
		assert(state_ == DbusConnectionState.awaitingHello);
		try
		{
			auto values = reply.body.values;
			if (reply.body.signature.text != "s" || values.length != 1)
				throw new DbusProtocolException("D-Bus Hello returned the wrong body shape");
			try
				uniqueName_ = DbusUniqueName.parse(values[0].get!string());
			catch (DbusException)
				throw new DbusProtocolException("D-Bus Hello returned an invalid unique name");
		}
		catch (DbusProtocolException exception)
		{
			failProtocol(exception);
			return;
		}

		readySucceeded_ = true;
		readySettled_ = true;
		state_ = DbusConnectionState.ready;
		readyPromise_.fulfill(uniqueName_);
	}

	void settleReply(DbusMessage reply)
	{
		auto pending = reply.headers.replySerial in pendingCalls_;
		if (pending is null)
			return;
		auto call = *pending;
		pendingCalls_.remove(reply.headers.replySerial);

		if (call.kind == DbusPendingKind.hello)
		{
				if (reply.messageType == DbusMessageType.methodReturn)
					settleHello(reply);
				else
				{
					auto cause = remoteError(reply);
					version(Posix)
						failCandidate(cause);
					else
						enterTerminal(cause, cause.msg, DisconnectType.error, false);
				}
			return;
		}

		if (reply.messageType == DbusMessageType.methodReturn)
			call.promise.fulfill(reply);
		else
			call.promise.reject(remoteError(reply));
	}

	void sendUnknownObject(const ref DbusMessage call)
	{
		if (call.flags & DbusMessageFlag.noReplyExpected)
			return;
		if (!call.headers.sender.text.length)
			throw new DbusProtocolException("incoming D-Bus method calls require SENDER for an error reply");

		DbusMessage reply;
		reply.messageType = DbusMessageType.error;
		reply.serial = allocateSerial();
		reply.headers.errorName = DbusErrorName.parse("org.freedesktop.DBus.Error.UnknownObject");
		reply.headers.replySerial = call.serial;
		reply.headers.destination = call.headers.sender;
		reply.body = DbusBody.from();
		transport_.send(encodeDbusMessage(reply));
	}

	void processOwnerWatchSignal(DbusOwnerWatch watch,
		const ref DbusSignalMessage signal, DbusBusName destination,
		scope const(DbusValue)[] values)
	{
		if (!isCurrentOwnerWatch(watch) ||
			(watch.phase != DbusOwnerWatchPhase.seeding &&
			watch.phase != DbusOwnerWatchPhase.known) ||
			!matchesFields(watch.match, signal, destination, values) ||
			signal.sender.text != watch.match.sender.text)
			return;
		if (signal.body.signature.text != "sss" || values.length != 3 ||
			values[0].kind != DbusValueKind.string_ ||
			values[1].kind != DbusValueKind.string_ ||
			values[2].kind != DbusValueKind.string_)
			return;
		auto changedName = values[0].get!string();
		auto oldOwner = values[1].get!string();
		auto newOwner = values[2].get!string();
		if (changedName != watch.name.text)
			return;
		try
		{
			if (oldOwner.length)
				DbusUniqueName.parse(oldOwner);
			if (newOwner.length)
				DbusUniqueName.parse(newOwner);
		}
		catch (DbusException)
			return;

		watch.known = true;
		watch.hasOwner = newOwner.length != 0;
		watch.owner = watch.hasOwner ? DbusUniqueName.parse(newOwner) : DbusUniqueName.init;
		watch.phase = DbusOwnerWatchPhase.known;
		activateOwnerWatchDependents(watch);
	}

	void routeIncomingSignal(const ref DbusMessage message)
	{
		DbusSignalMessage signal;
		signal.path = message.headers.path;
		signal.interfaceName = message.headers.interfaceName;
		signal.member = message.headers.member;
		signal.sender = message.headers.sender;
		auto values = message.body.values;
		signal.body = DbusBody.fromValues(values);
		auto destination = message.headers.destination;

		DbusOwnerWatch[] watches;
		foreach (watch; ownerWatches_)
			watches ~= watch;
		foreach (watch; watches)
			processOwnerWatchSignal(watch, signal, destination, values);

		auto registrationIds = registrationOrder_.dup;
		foreach (id; registrationIds)
		{
			auto current = id in registrations_;
			if (current is null)
				continue;
			auto registration = *current;
			if (!registration.active || !registration.dispatchActive ||
				!matchesRule(registration.rule, signal, destination, values, registration))
				continue;
			registration.handler(signal);
		}
	}

	void routeIncomingMessage(DbusMessage message)
	{
		if (state_ == DbusConnectionState.awaitingHello &&
			message.headers.replySerial != 0)
		{
			auto pending = message.headers.replySerial in pendingCalls_;
			if (pending !is null && (*pending).kind == DbusPendingKind.hello &&
				message.messageType != DbusMessageType.methodReturn &&
				message.messageType != DbusMessageType.error)
			{
				failProtocol(new DbusProtocolException(
					"D-Bus Hello received a correlated non-reply message"));
				return;
			}
		}

		switch (message.messageType)
		{
		case DbusMessageType.methodReturn:
		case DbusMessageType.error:
			settleReply(message);
			return;

		case DbusMessageType.methodCall:
			if (state_ == DbusConnectionState.ready)
				sendUnknownObject(message);
			return;

		case DbusMessageType.signal:
			if (state_ == DbusConnectionState.ready)
				routeIncomingSignal(message);
			return;

		default:
			return;
		}
	}

	void rejectPending(Exception cause)
	{
		DbusPendingCall[] pending;
		foreach (entry; pendingCalls_)
			pending ~= entry;
		pendingCalls_ = null;
		foreach (entry; pending)
			if (entry.kind == DbusPendingKind.ordinary)
				entry.promise.reject(cause);
	}

	void rejectSignalState(Exception cause)
	{
		foreach (registration; registrations_)
		{
			registration.active = false;
			registration.dispatchActive = false;
			registration.subscription.active_ = false;
		}
		foreach (rule; rules_)
			rule.phase = DbusRulePhase.terminal;
		foreach (watch; ownerWatches_)
		{
			watch.phase = DbusOwnerWatchPhase.terminal;
			watch.operationGeneration++;
		}
		foreach (remote; remoteMatches_)
		{
			remote.phase = DbusRemoteMatchPhase.terminal;
			remote.operationGeneration++;
		}

		foreach (registration; registrations_)
			if (registration.subscribePromise !is null)
			{
				auto promise = registration.subscribePromise;
				registration.subscribePromise = null;
				promise.reject(cause);
			}
		foreach (remote; remoteMatches_)
			rejectRemoteRemovalPromises(remote, cause);

		registrations_ = null;
		registrationOrder_ = null;
		rules_ = null;
		ownerWatches_ = null;
		remoteMatches_ = null;
	}

	void enterTerminal(Exception cause, string disconnectReason,
		DisconnectType disconnectType, bool closeTransport)
	{
		assert(state_ != DbusConnectionState.terminal);
		terminalCause_ = cause;
		state_ = DbusConnectionState.terminal;
		attemptOutcome_ = DbusAttemptOutcome.terminal;
		generation_++;
		auto oldTransport = transport_;
		transport_ = null;
		if (oldTransport !is null)
		{
			oldTransport.handleConnect = null;
			oldTransport.handleReadData = null;
			oldTransport.handleDisconnect = null;
			oldTransport.handleBufferFlushed = null;
		}

		if (!readySettled_)
		{
			readySettled_ = true;
			readyPromise_.reject(cause);
		}
		rejectSignalState(cause);
		rejectPending(cause);
		decoder_.reset();
		serverGuid_ = DbusServerGuid.init;
		version(Posix)
		{
			authenticator_ = null;
			candidates_ = null;
			attemptFactory_ = null;
			attemptStarter_ = null;
		}

		if (closeTransport && oldTransport !is null && disconnectable(oldTransport.state))
			oldTransport.disconnect(disconnectReason, disconnectType);
	}

	void failProtocol(DbusProtocolException cause)
	{
		if (state_ == DbusConnectionState.ready)
			enterTerminal(cause, cause.msg, DisconnectType.error, true);
		else
			version(Posix)
				failCandidate(cause);
			else
				enterTerminal(cause, cause.msg, DisconnectType.error, false);
	}

	version(Posix)
	{
		bool isCurrentAttempt(ulong generation, IConnection transport)
		{
			return state_ != DbusConnectionState.terminal &&
				attemptOutcome_ == DbusAttemptOutcome.active &&
				generation_ == generation && transport_ is transport;
		}

		void clearAttemptState()
		{
			foreach (entry; pendingCalls_)
				assert(entry.kind == DbusPendingKind.hello);
			pendingCalls_ = null;
			decoder_.reset();
			authenticator_ = null;
			serverGuid_ = DbusServerGuid.init;
		}

		void detachAttemptTransport()
		{
			if (transport_ is null)
				return;
			transport_.handleConnect = null;
			transport_.handleReadData = null;
			transport_.handleDisconnect = null;
			transport_.handleBufferFlushed = null;
			transport_ = null;
		}

		void continueAfterFailedAttempt(Exception cause)
		{
			assert(!attachedTransport_);
			assert(candidateIndex_ < candidates_.length);
			auto failedIndex = candidateIndex_;
			auto candidateCount = candidates_.length;
			clearAttemptState();
			detachAttemptTransport();
			candidateIndex_ = failedIndex + 1;
			if (candidateIndex_ == candidateCount)
			{
				auto context = new DbusCandidateExhaustionContext(failedIndex,
					candidateCount);
				auto root = Throwable.chainTogether(cause, context);
				assert(root is cause);
				enterTerminal(cause, cause.msg, DisconnectType.error, false);
				return;
			}
			startCurrentCandidate();
		}

		void failCandidate(Exception cause)
		{
			assert(state_ == DbusConnectionState.connecting ||
				state_ == DbusConnectionState.authenticating ||
				state_ == DbusConnectionState.awaitingHello);
			if (attachedTransport_)
			{
				enterTerminal(cause, cause.msg, DisconnectType.error, true);
				return;
			}

			assert(attemptOutcome_ == DbusAttemptOutcome.active);
			attemptOutcome_ = DbusAttemptOutcome.internalFallback;
			auto oldTransport = transport_;
			if (oldTransport !is null && disconnectable(oldTransport.state))
				oldTransport.disconnect(cause.msg, DisconnectType.error);
			continueAfterFailedAttempt(cause);
		}

		void onTransportDisconnect(ulong generation, IConnection transport,
			string reason, DisconnectType type)
		{
			if (!isCurrentAttempt(generation, transport))
				return;
			if (attemptOutcome_ == DbusAttemptOutcome.internalFallback)
				return;

			auto cause = new DbusDisconnectedException(reason, type);
			if (state_ == DbusConnectionState.ready || attachedTransport_)
			{
				enterTerminal(cause, reason, type, false);
				return;
			}
			continueAfterFailedAttempt(cause);
		}

		void receiveBinary(ulong generation, IConnection transport, Data data)
		{
			try
			{
				decoder_.feed(data, (DbusMessage message) {
					if (!isCurrentAttempt(generation, transport))
						return false;
					routeIncomingMessage(message);
					return isCurrentAttempt(generation, transport);
				});
			}
			catch (DbusProtocolException exception)
			{
				if (isCurrentAttempt(generation, transport))
					failProtocol(exception);
			}
		}

		void completeAuthentication(ulong generation, IConnection transport,
			DbusAuthenticationResult result)
		{
			if (!isCurrentAttempt(generation, transport) ||
				state_ != DbusConnectionState.authenticating)
				return;
			assert(result.complete);
			serverGuid_ = result.serverGuid;
			authenticator_ = null;
			decoder_.reset();
			state_ = DbusConnectionState.awaitingHello;

			DbusMessage hello;
			hello.messageType = DbusMessageType.methodCall;
			hello.serial = allocateSerial();
			hello.headers.destination = DbusBusName.parse("org.freedesktop.DBus");
			hello.headers.path = DbusObjectPath.parse("/org/freedesktop/DBus");
			hello.headers.interfaceName = DbusInterfaceName.parse("org.freedesktop.DBus");
			hello.headers.member = DbusMemberName.parse("Hello");
			hello.body = DbusBody.from();
			auto frame = encodeDbusMessage(hello);
			pendingCalls_[hello.serial] = DbusPendingCall(DbusPendingKind.hello, null);
			transport.send(frame);

			if (result.binarySuffix.length && isCurrentAttempt(generation, transport))
				receiveBinary(generation, transport, result.binarySuffix);
		}

		void onTransportData(ulong generation, IConnection transport, Data data)
		{
			if (!isCurrentAttempt(generation, transport))
				return;
			try
			{
				if (state_ == DbusConnectionState.authenticating)
				{
					auto result = authenticator_.feed(data);
					if (result.complete)
						completeAuthentication(generation, transport, result);
					return;
				}
				assert(state_ == DbusConnectionState.awaitingHello ||
					state_ == DbusConnectionState.ready);
				receiveBinary(generation, transport, data);
			}
			catch (DbusAuthenticationException exception)
			{
				if (isCurrentAttempt(generation, transport))
					failCandidate(exception);
			}
		}

		void beginAuthentication(ulong generation, IConnection transport)
		{
			if (!isCurrentAttempt(generation, transport))
				return;
			assert(state_ == DbusConnectionState.connecting);
			state_ = DbusConnectionState.authenticating;
			DbusServerGuid expectedGuid;
			if (!attachedTransport_ && candidates_[candidateIndex_].hasExpectedGuid)
				expectedGuid = candidates_[candidateIndex_].expectedGuid;
			authenticator_ = new DbusExternalAuthenticator(expectedGuid);
			try
			{
				authenticator_.start((Data data) {
					if (isCurrentAttempt(generation, transport) &&
						state_ == DbusConnectionState.authenticating)
						transport.send(data);
				});
			}
			catch (DbusAuthenticationException exception)
			{
				if (isCurrentAttempt(generation, transport))
					failCandidate(exception);
			}
		}

		void installAttemptHandlers(IConnection transport, ulong generation)
		{
			transport.handleConnect = {
				if (isCurrentAttempt(generation, transport))
					beginAuthentication(generation, transport);
			};
			transport.handleReadData = (Data data) {
				onTransportData(generation, transport, data);
			};
			transport.handleDisconnect = (string reason, DisconnectType type) {
				onTransportDisconnect(generation, transport, reason, type);
			};
			transport.handleBufferFlushed = {
				if (!isCurrentAttempt(generation, transport))
					return;
			};
		}

		void startCurrentCandidate()
		{
			assert(candidateIndex_ < candidates_.length);
			state_ = DbusConnectionState.connecting;
			attemptOutcome_ = DbusAttemptOutcome.active;
			auto attemptGeneration = ++generation_;
			clearAttemptState();
			auto candidate = candidates_[candidateIndex_];
			IConnection attemptTransport;
			try
			{
				attemptTransport = attemptFactory_(candidate);
				assert(attemptTransport !is null);
				assert(attemptTransport.state == ConnectionState.disconnected);
				transport_ = attemptTransport;
				installAttemptHandlers(attemptTransport, attemptGeneration);
				attemptStarter_(attemptTransport, candidate);
			}
			catch (Exception exception)
			{
				if (isCurrentAttempt(attemptGeneration, attemptTransport))
					failCandidate(exception);
			}
		}

		this(DbusUnixAddressCandidate[] candidates, AttemptFactory attemptFactory,
			AttemptStarter attemptStarter)
		{
			this();
			assert(candidates.length);
			assert(attemptFactory !is null);
			assert(attemptStarter !is null);
			candidates_ = candidates.dup;
			attemptFactory_ = attemptFactory;
			attemptStarter_ = attemptStarter;
			startCurrentCandidate();
		}

		this(IConnection transport)
		{
			this();
			assert(transport !is null);
			assert(transport.state == ConnectionState.connected);
			attachedTransport_ = true;
			generation_++;
			transport_ = transport;
			installAttemptHandlers(transport, generation_);
			beginAuthentication(generation_, transport);
		}
	}

	Promise!DbusSubscription subscribeImpl(DbusSignalMatch match,
		void delegate(const ref DbusSignalMessage) handler,
		bool hasExpectedBodySignature, DbusSignature expectedBodySignature)
	{
		if (handler is null)
			throw new DbusValidationException("D-Bus signal subscriptions require a handler");
		auto key = match.canonicalRule;
		auto result = new Promise!DbusSubscription;
		if (state_ == DbusConnectionState.terminal)
		{
			result.reject(terminalCause_);
			return result;
		}

		auto current = key in rules_;
		DbusRuleState rule;
		if (current is null)
		{
			rule = new DbusRuleState;
			rule.key = key;
			rule.match = match;
			rule.phase = DbusRulePhase.waitingForOwner;
			rules_[key] = rule;
		}
		else
			rule = *current;

		auto registration = new DbusSignalRegistration;
		registration.id = allocateRegistrationId();
		registration.rule = rule;
		registration.subscription = new DbusSubscription(this, registration.id);
		registration.handler = handler;
		registration.active = true;
		registration.hasExpectedBodySignature = hasExpectedBodySignature;
		registration.expectedBodySignature = expectedBodySignature;
		registration.subscribePromise = result;
		registrations_[registration.id] = registration;
		registrationOrder_ ~= registration.id;
		rule.registrationIds ~= registration.id;

		if (current is null)
		{
			if (match.hasSender && isOrdinaryWellKnownName(match.sender))
				acquireOwnerWatch(rule);
			else
				startRuleRemote(rule);
		}
		else if (rule.phase == DbusRulePhase.active)
		{
			registration.dispatchActive = true;
			fulfillSubscribe(registration);
		}
		else if (rule.phase == DbusRulePhase.waitingForRemote)
		{
			auto remote = rule.remoteLease.state;
			if (isRemoteMatchDispatchable(remote))
				registration.dispatchActive = true;
		}
		else
			assert(rule.phase == DbusRulePhase.waitingForOwner);

		return result;
	}

	Promise!void unsubscribeRegistration(ulong id, DbusSubscription subscription)
	{
		auto result = new Promise!void;
		if (state_ == DbusConnectionState.terminal)
		{
			subscription.active_ = false;
			result.reject(terminalCause_);
			return result;
		}
		auto current = id in registrations_;
		assert(current !is null && (*current).subscription is subscription);
		auto registration = *current;
		assert(registration.active);
		registration.active = false;
		registration.dispatchActive = false;
		subscription.active_ = false;
		auto rule = registration.rule;
		removeRegistration(registration);
		if (rule.registrationIds.length)
		{
			result.fulfill();
			return result;
		}

		assert(rule.phase == DbusRulePhase.active);
		rule.phase = DbusRulePhase.terminal;
		rules_.remove(rule.key);
		auto lease = rule.remoteLease;
		rule.remoteLease = null;
		releaseRemoteMatch(lease, result);
		result.then({
			releaseOwnerWatch(rule);
		}, (Exception) {
			releaseOwnerWatch(rule);
		}).ignoreResult();
		return result;
	}

public:
	@property Promise!DbusUniqueName ready()
	{
		return readyPromise_;
	}

	@property DbusUniqueName uniqueName()
	{
		assert(readySucceeded_);
		return uniqueName_;
	}

	Promise!DbusSubscription subscribe(DbusSignalMatch match,
		void delegate(const ref DbusSignalMessage) handler)
	{
		return subscribeImpl(match, handler, false, DbusSignature.init);
	}

	package(ae.net.dbus) Promise!DbusSubscription subscribe(DbusSignalMatch match,
		DbusSignature expectedBodySignature,
		void delegate(const ref DbusSignalMessage) handler)
	{
		return subscribeImpl(match, handler, true,
			DbusSignature.parse(expectedBodySignature.text));
	}

	Promise!DbusMessage call(DbusMethodCall request)
	{
		validateCall(request);
		auto result = new Promise!DbusMessage;
		if (state_ == DbusConnectionState.terminal)
		{
			assert(terminalCause_ !is null);
			result.reject(terminalCause_);
			return result;
		}
		if (state_ == DbusConnectionState.ready)
		{
			sendOrdinaryCall(request, result);
			return result;
		}

		readyPromise_.then((DbusUniqueName) {
			if (state_ == DbusConnectionState.ready)
				sendOrdinaryCall(request, result);
			else
			{
				assert(state_ == DbusConnectionState.terminal);
				result.reject(terminalCause_);
			}
		}, (Exception exception) {
			result.reject(exception);
		}).ignoreResult();
		return result;
	}

	Promise!DbusUniqueName getNameOwner(DbusBusName name)
	{
		if (!name.text.length)
			throw new DbusValidationException("D-Bus name-owner lookup requires a bus name");
		auto raw = call(standardBusCall("GetNameOwner", DbusBody.from(name.text)));
		auto result = new Promise!DbusUniqueName;
		raw.then((DbusMessage reply) {
			try
				result.fulfill(requireUniqueNameReply(reply));
			catch (DbusTypeMismatchException exception)
				result.reject(exception);
		}, (Exception exception) {
			result.reject(exception);
		}).ignoreResult();
		return result;
	}

	Promise!bool nameHasOwner(DbusBusName name)
	{
		if (!name.text.length)
			throw new DbusValidationException("D-Bus name-owner lookup requires a bus name");
		auto raw = call(standardBusCall("NameHasOwner", DbusBody.from(name.text)));
		auto result = new Promise!bool;
		raw.then((DbusMessage reply) {
			try
				result.fulfill(requireBooleanReply(reply));
			catch (DbusTypeMismatchException exception)
				result.reject(exception);
		}, (Exception exception) {
			result.reject(exception);
		}).ignoreResult();
		return result;
	}

	void disconnect(string reason = IConnection.defaultDisconnectReason)
	{
		assert(state_ != DbusConnectionState.terminal);
		auto cause = new DbusDisconnectedException(reason, DisconnectType.requested);
		enterTerminal(cause, reason, DisconnectType.requested, true);
	}
}

version(Posix)
{
	debug(ae_unittest)
	private void delegate(SocketConnection) dbusClientTestSocketObserver;

	private IConnection createDbusSocket(DbusUnixAddressCandidate candidate)
	{
		auto transport = new SocketConnection;
		debug(ae_unittest)
		if (dbusClientTestSocketObserver !is null)
			dbusClientTestSocketObserver(transport);
		return transport;
	}

	private void startDbusSocket(IConnection transport,
		DbusUnixAddressCandidate candidate)
	{
		(cast(SocketConnection) transport).connect([candidate.toAddressInfo]);
	}

	DbusConnection connectDbusAddress(string address)
	{
		return new DbusConnection(parseDbusAddress(address),
			(candidate) { return createDbusSocket(candidate); },
			(transport, candidate) { startDbusSocket(transport, candidate); });
	}

	DbusConnection connectSessionBus()
	{
		return new DbusConnection(selectSessionBusAddresses(),
			(candidate) { return createDbusSocket(candidate); },
			(transport, candidate) { startDbusSocket(transport, candidate); });
	}

	DbusConnection connectSystemBus()
	{
		return new DbusConnection(selectSystemBusAddresses(),
			(candidate) { return createDbusSocket(candidate); },
			(transport, candidate) { startDbusSocket(transport, candidate); });
	}

	DbusConnection attachDbusConnection(IConnection transport)
	{
		return new DbusConnection(transport);
	}
}

version(Posix)
{
debug(ae_unittest)
private enum dbusClientTestServerGuid = "0123456789abcdef0123456789abcdef";

debug(ae_unittest)
private final class DbusClientTestConnection : IConnection
{
	ConnectionState state_ = ConnectionState.disconnected;
	Data[] sent;
	size_t[] sendDataCounts;
	string disconnectReason;
	DisconnectType disconnectType;
	size_t disconnectCount;
	bool disconnectSynchronously;
	void delegate(Data data) onSend;

	ConnectHandler connectHandler;
	ReadDataHandler readDataHandler;
	DisconnectHandler disconnectHandler;
	BufferFlushedHandler bufferFlushedHandler;

	@property ConnectionState state()
	{
		return state_;
	}

	void send(scope Data[] data, int priority = DEFAULT_PRIORITY)
	{
		assert(state_ == ConnectionState.connected);
		sendDataCounts ~= data.length;
		foreach (datum; data)
			sent ~= datum.dup;
		if (onSend)
			onSend(data.length ? data[0] : Data.init);
	}
	alias send = IConnection.send;

	void disconnect(string reason = defaultDisconnectReason,
		DisconnectType type = DisconnectType.requested)
	{
		assert(state_ == ConnectionState.connected);
		disconnectCount++;
		disconnectReason = reason;
		disconnectType = type;
		state_ = ConnectionState.disconnected;
		if (disconnectSynchronously && disconnectHandler !is null)
			disconnectHandler(reason, type);
	}

	@property void handleConnect(ConnectHandler value)
	{
		connectHandler = value;
	}

	@property void handleReadData(ReadDataHandler value)
	{
		readDataHandler = value;
	}

	@property void handleDisconnect(DisconnectHandler value)
	{
		disconnectHandler = value;
	}

	@property void handleBufferFlushed(BufferFlushedHandler value)
	{
		bufferFlushedHandler = value;
	}

	void connect()
	{
		assert(state_ == ConnectionState.disconnected);
		assert(connectHandler !is null);
		state_ = ConnectionState.connected;
		connectHandler();
	}

	void receive(Data data)
	{
		assert(readDataHandler !is null);
		readDataHandler(data);
	}

	void peerDisconnect(string reason, DisconnectType type)
	{
		assert(disconnectHandler !is null);
		state_ = ConnectionState.disconnected;
		disconnectHandler(reason, type);
	}
}

debug(ae_unittest)
private final class DbusClientTestAttemptScript
{
	DbusClientTestConnection[] transports;
	DbusUnixAddressCandidate[] createdCandidates;
	DbusUnixAddressCandidate[] startedCandidates;
	DbusServerGuid[] expectedGuids;
	size_t starts;
	bool handlersInstalledBeforeStart;

	IConnection create(DbusUnixAddressCandidate candidate)
	{
		createdCandidates ~= candidate;
		if (candidate.hasExpectedGuid)
			expectedGuids ~= candidate.expectedGuid;
		auto transport = new DbusClientTestConnection;
		transports ~= transport;
		return transport;
	}

	void start(IConnection transport, DbusUnixAddressCandidate candidate)
	{
		startedCandidates ~= candidate;
		auto scripted = cast(DbusClientTestConnection) transport;
		assert(scripted.state == ConnectionState.disconnected);
		assert(scripted.connectHandler !is null);
		assert(scripted.readDataHandler !is null);
		assert(scripted.disconnectHandler !is null);
		assert(scripted.bufferFlushedHandler !is null);
		handlersInstalledBeforeStart = true;
		starts++;
	}
}

debug(ae_unittest)
private DbusUnixAddressCandidate[] dbusClientTestCandidates(size_t count = 1)
{
	auto result = parseDbusAddress("unix:path=/tmp/ae-dbus-client-test");
	while (result.length < count)
		result ~= result[0];
	return result;
}

debug(ae_unittest)
private DbusConnection dbusClientTestConnect(DbusClientTestAttemptScript script,
	size_t candidateCount = 1)
{
	auto client = new DbusConnection(dbusClientTestCandidates(candidateCount),
		(candidate) { return script.create(candidate); },
		(transport, candidate) { script.start(transport, candidate); });
	client.ready.ignoreResult();
	return client;
}

debug(ae_unittest)
private string dbusClientTestExternalIdentity()
{
	enum hexadecimal = "0123456789abcdef";
	char[] result;
	foreach (ubyte octet; cast(const(ubyte)[]) to!string(getuid()))
	{
		result ~= hexadecimal[octet >> 4];
		result ~= hexadecimal[octet & 0x0f];
	}
	return result.idup;
}

debug(ae_unittest)
private size_t dbusClientTestSocketSerial;

debug(ae_unittest)
private string dbusClientTestSocketPath()
{
	return "/tmp/ae-dbus-client-" ~ to!string(getpid()) ~ "-" ~
		to!string(dbusClientTestSocketSerial++);
}

debug(ae_unittest)
private void dbusClientTestAuthenticate(DbusClientTestConnection transport,
	uint expectedHelloSerial = 1, string serverGuid = dbusClientTestServerGuid)
{
	transport.connect();
	assert(transport.sent.length == 2);
	assert(transport.sent[0].toGC == [cast(ubyte) 0]);
	assert(transport.sent[1].toGC == ("AUTH EXTERNAL " ~
		dbusClientTestExternalIdentity() ~ "\r\n").asBytes);

	transport.receive(Data(("OK " ~ serverGuid ~ "\r\n").asBytes));
	assert(transport.sent.length == 4);
	assert(transport.sent[2].toGC == "BEGIN\r\n".asBytes);

	auto hello = decodeDbusMessage(transport.sent[3].toGC);
	assert(hello.messageType == DbusMessageType.methodCall);
	assert(hello.serial == expectedHelloSerial);
	assert(hello.headers.destination.text == "org.freedesktop.DBus");
	assert(hello.headers.path.text == "/org/freedesktop/DBus");
	assert(hello.headers.interfaceName.text == "org.freedesktop.DBus");
	assert(hello.headers.member.text == "Hello");
	assert(hello.body.signature.text == "");
}

debug(ae_unittest)
private Data dbusClientTestMethodReturn(uint replySerial, DbusBody body)
{
	DbusMessage message;
	message.messageType = DbusMessageType.methodReturn;
	message.serial = 100;
	message.headers.replySerial = replySerial;
	message.body = body;
	return encodeDbusMessage(message);
}

debug(ae_unittest)
private Data dbusClientTestError(uint replySerial, string errorName,
	string errorMessage)
{
	DbusMessage message;
	message.messageType = DbusMessageType.error;
	message.serial = 101;
	message.headers.errorName = DbusErrorName.parse(errorName);
	message.headers.replySerial = replySerial;
	message.body = DbusBody.from(errorMessage);
	return encodeDbusMessage(message);
}

debug(ae_unittest)
private Data dbusClientTestSignal(string sender, string destination,
	DbusBody body, string member = "Changed")
{
	DbusMessage message;
	message.messageType = DbusMessageType.signal;
	message.serial = 102;
	message.headers.path = DbusObjectPath.parse("/org/example/Object");
	message.headers.interfaceName = DbusInterfaceName.parse("org.example.Interface");
	message.headers.member = DbusMemberName.parse(member);
	if (sender.length)
		message.headers.sender = DbusBusName.parse(sender);
	if (destination.length)
		message.headers.destination = DbusBusName.parse(destination);
	message.body = body;
	return encodeDbusMessage(message);
}

debug(ae_unittest)
private Data dbusClientTestOwnerChanged(string name, string oldOwner,
	string newOwner)
{
	DbusMessage message;
	message.messageType = DbusMessageType.signal;
	message.serial = 103;
	message.headers.path = DbusObjectPath.parse("/org/freedesktop/DBus");
	message.headers.interfaceName = DbusInterfaceName.parse("org.freedesktop.DBus");
	message.headers.member = DbusMemberName.parse("NameOwnerChanged");
	message.headers.sender = DbusBusName.parse("org.freedesktop.DBus");
	message.body = DbusBody.from(name, oldOwner, newOwner);
	return encodeDbusMessage(message);
}

debug(ae_unittest)
private DbusMessage dbusClientTestSentMessage(DbusClientTestConnection transport,
	size_t index)
{
	return decodeDbusMessage(transport.sent[index].toGC);
}

debug(ae_unittest)
private uint dbusClientTestMatchSerial(DbusClientTestConnection transport,
	size_t index, string member)
{
	auto request = dbusClientTestSentMessage(transport, index);
	assert(request.messageType == DbusMessageType.methodCall);
	assert(request.headers.destination.text == "org.freedesktop.DBus");
	assert(request.headers.path.text == "/org/freedesktop/DBus");
	assert(request.headers.interfaceName.text == "org.freedesktop.DBus");
	assert(request.headers.member.text == member);
	assert(request.body.signature.text == "s");
	return request.serial;
}

debug(ae_unittest)
private bool dbusClientTestIsMatchCall(DbusMessage message, string member,
	string rule)
{
	return message.messageType == DbusMessageType.methodCall &&
		message.headers.member.text == member &&
		message.body.signature.text == "s" && message.body.values.length == 1 &&
		message.body.values[0].get!string() == rule;
}

debug(ae_unittest)
private size_t dbusClientTestMatchCallIndex(DbusClientTestConnection transport,
	string member, string rule)
{
	foreach (index; 4 .. transport.sent.length)
		if (dbusClientTestIsMatchCall(dbusClientTestSentMessage(transport, index),
			member, rule))
			return index;
	assert(false);
}

debug(ae_unittest)
private size_t dbusClientTestMatchCallCount(DbusClientTestConnection transport,
	string member, string rule)
{
	size_t result;
	foreach (index; 4 .. transport.sent.length)
		if (dbusClientTestIsMatchCall(dbusClientTestSentMessage(transport, index),
			member, rule))
			result++;
	return result;
}

debug(ae_unittest)
private DbusMethodCall dbusClientTestCall(string member)
{
	DbusMethodCall result;
	result.destination = DbusBusName.parse("org.example.Service");
	result.path = DbusObjectPath.parse("/org/example/Test");
	result.interfaceName = DbusInterfaceName.parse("org.example.Test");
	result.member = DbusMemberName.parse(member);
	result.body = DbusBody.from();
	return result;
}

debug(ae_unittest)
private void dbusClientTestReady(DbusClientTestConnection transport,
	string uniqueName = ":1.42", uint helloSerial = 1)
{
	transport.receive(dbusClientTestMethodReturn(helloSerial, DbusBody.from(uniqueName)));
}

debug(ae_unittest)
private DbusCandidateExhaustionContext dbusClientTestExhaustionContext(
	Throwable cause)
{
	while (cause !is null)
	{
		auto context = cast(DbusCandidateExhaustionContext) cause;
		if (context !is null)
			return context;
		cause = cause.next;
	}
	return null;
}

debug(ae_unittest)
private Data dbusClientTestInvalidFixedHeader()
{
	ubyte[16] fixedHeader;
	fixedHeader[0] = cast(ubyte) 'x';
	fixedHeader[1] = DbusMessageType.methodReturn;
	fixedHeader[3] = 1;
	fixedHeader[8] = 1;
	return Data(fixedHeader[].dup);
}

debug(ae_unittest)
private Data dbusClientTestUnixFdsFrame()
{
	ubyte[] frame = [
		cast(ubyte) 'l', 2, 0, 1, 0, 0, 0, 0,
		1, 0, 0, 0, 16, 0, 0, 0,
		5, 1, 'u', 0, 1, 0, 0, 0,
		9, 1, 'u', 0, 1, 0, 0, 0,
	];
	return Data(frame);
}

debug(ae_unittest)
private struct DbusClientTestCallbacks
{
	IConnection.ConnectHandler connect;
	IConnection.ReadDataHandler readData;
	IConnection.DisconnectHandler disconnect;
	IConnection.BufferFlushedHandler bufferFlushed;
}

debug(ae_unittest)
private DbusClientTestCallbacks dbusClientTestCaptureCallbacks(
	DbusClientTestConnection transport)
{
	DbusClientTestCallbacks result;
	result.connect = transport.connectHandler;
	result.readData = transport.readDataHandler;
	result.disconnect = transport.disconnectHandler;
	result.bufferFlushed = transport.bufferFlushedHandler;
	assert(result.connect !is null);
	assert(result.readData !is null);
	assert(result.disconnect !is null);
	assert(result.bufferFlushed !is null);
	return result;
}

debug(ae_unittest)
private void dbusClientTestInvokeCallbacks(DbusClientTestCallbacks callbacks)
{
	callbacks.connect();
	callbacks.readData(Data([cast(ubyte) 0xff]));
	callbacks.disconnect("late callback", DisconnectType.error);
	callbacks.bufferFlushed();
}

debug(ae_unittest) unittest
{
	auto script = new DbusClientTestAttemptScript;
	auto client = dbusClientTestConnect(script, 2);
	assert(script.handlersInstalledBeforeStart);
	assert(script.starts == 1);

	auto first = script.transports[0];
	auto staleCallbacks = dbusClientTestCaptureCallbacks(first);
	first.peerDisconnect("first attempt failed", DisconnectType.error);

	assert(script.starts == 2);
	assert(first.connectHandler is null);
	assert(first.readDataHandler is null);
	assert(first.disconnectHandler is null);
	assert(first.bufferFlushedHandler is null);
	auto second = script.transports[1];
	dbusClientTestInvokeCallbacks(staleCallbacks);
	assert(script.starts == 2);
	assert(second.sent.length == 0);
	assert(second.state == ConnectionState.disconnected);
}

debug(ae_unittest) unittest
{
	auto script = new DbusClientTestAttemptScript;
	auto client = dbusClientTestConnect(script, 2);
	auto eagerReady = client.ready;
	Exception earlyError;
	eagerReady.then((DbusUniqueName) {
		assert(false);
	}, (Exception exception) {
		earlyError = exception;
	}).ignoreResult();

	script.transports[0].peerDisconnect("first candidate failed", DisconnectType.error);
	assert(script.starts == 2);
	auto finalTransport = script.transports[1];
	dbusClientTestAuthenticate(finalTransport);
	finalTransport.disconnectSynchronously = true;
	auto protocol = new DbusProtocolException("final candidate protocol failure");
	auto existing = new Exception("pre-existing candidate detail");
	auto root = Throwable.chainTogether(protocol, existing);
	assert(root is protocol);
	client.failCandidate(protocol);
	assert(finalTransport.disconnectCount == 1);
	assert(finalTransport.disconnectType == DisconnectType.error);
	assert(script.starts == 2);
	assert(client.terminalCause_ is protocol);

	socketManager.loop();
	assert(earlyError is protocol);
	auto context = dbusClientTestExhaustionContext(protocol);
	assert(context !is null);
	assert(protocol.next is existing);
	assert(existing.next is context);
	assert(context.next is null);
	assert(context.candidateIndex == 1);
	assert(context.candidateCount == 2);
	assert(context.msg == "D-Bus candidate exhaustion: final candidate index 1 of 2 (zero-based)");

	auto lateReady = client.ready;
	assert(lateReady is eagerReady);
	Exception lateError;
	lateReady.then((DbusUniqueName) {
		assert(false);
	}, (Exception exception) {
		lateError = exception;
	}).ignoreResult();
	socketManager.loop();
	assert(lateError is protocol);
}

debug(ae_unittest) unittest
{
	auto script = new DbusClientTestAttemptScript;
	auto client = dbusClientTestConnect(script, 2);
	Exception readyError;
	bool readyFulfilled;
	client.ready.then((DbusUniqueName) {
		readyFulfilled = true;
	}, (Exception exception) {
		readyError = exception;
	}).ignoreResult();

	script.transports[0].peerDisconnect("release first candidate failed",
		DisconnectType.error);
	script.transports[1].peerDisconnect("release final candidate failed",
		DisconnectType.graceful);
	socketManager.loop();

	if (readyFulfilled)
		throw new Exception("release candidate exhaustion fulfilled readiness");
	if (readyError is null)
		throw new Exception("release candidate exhaustion did not reject readiness");

	bool foundContext;
	for (Throwable cause = readyError; cause !is null; cause = cause.next)
	{
		if (cause.msg == "D-Bus candidate exhaustion: final candidate index 1 of 2 (zero-based)")
		{
			foundContext = true;
			break;
		}
	}
	if (!foundContext)
		throw new Exception("release candidate exhaustion omitted candidate context");
}

debug(ae_unittest) unittest
{
	auto script = new DbusClientTestAttemptScript;
	auto client = dbusClientTestConnect(script, 2);
	auto eagerReady = client.ready;
	Exception earlyError;
	eagerReady.then((DbusUniqueName) {
		assert(false);
	}, (Exception exception) {
		earlyError = exception;
	}).ignoreResult();

	script.transports[0].peerDisconnect("first transport close", DisconnectType.error);
	assert(script.starts == 2);
	script.transports[1].peerDisconnect("final graceful close", DisconnectType.graceful);
	assert(script.starts == 2);
	socketManager.loop();
	auto disconnected = cast(DbusDisconnectedException) earlyError;
	assert(disconnected !is null);
	assert(disconnected is client.terminalCause_);
	assert(disconnected.reason == "final graceful close");
	assert(disconnected.disconnectType == DisconnectType.graceful);
	auto context = dbusClientTestExhaustionContext(disconnected);
	assert(context !is null);
	assert(context.candidateIndex == 1);
	assert(context.candidateCount == 2);

	auto lateReady = client.ready;
	assert(lateReady is eagerReady);
	Exception lateError;
	lateReady.then((DbusUniqueName) {
		assert(false);
	}, (Exception exception) {
		lateError = exception;
	}).ignoreResult();
	socketManager.loop();
	assert(lateError is disconnected);
}

debug(ae_unittest) unittest
{
	auto candidates = parseDbusAddress(
		"unix:path=/tmp/ae-dbus-starter-one;unix:path=/tmp/ae-dbus-starter-two");
	auto script = new DbusClientTestAttemptScript;
	auto client = new DbusConnection(candidates,
		(candidate) { return script.create(candidate); },
		(transport, candidate) {
			script.start(transport, candidate);
			if (script.starts == 1)
			{
				auto first = cast(DbusClientTestConnection) transport;
				first.connect();
				first.disconnectSynchronously = true;
				first.disconnect("starter advanced synchronously", DisconnectType.error);
				throw new Exception("starter threw after synchronous advance");
			}
		});
	client.ready.ignoreResult();

	assert(script.starts == 2);
	assert(script.transports.length == 2);
	auto first = script.transports[0];
	auto second = script.transports[1];
	assert(client.candidateIndex_ == 1);
	assert(client.transport_ is second);
	assert(client.state_ == DbusConnectionState.connecting);
	assert(client.attemptOutcome_ == DbusAttemptOutcome.active);
	assert(client.terminalCause_ is null);
	assert(!client.readySettled_);
	assert(first.connectHandler is null);
	assert(first.readDataHandler is null);
	assert(first.disconnectHandler is null);
	assert(first.bufferFlushedHandler is null);
	assert(second.connectHandler !is null);
	assert(second.readDataHandler !is null);
	assert(second.disconnectHandler !is null);
	assert(second.bufferFlushedHandler !is null);

	bool ready;
	client.ready.then((DbusUniqueName name) {
		assert(name.text == ":1.73");
		ready = true;
	}, (Exception) {
		assert(false);
	}).ignoreResult();
	dbusClientTestAuthenticate(second);
	dbusClientTestReady(second, ":1.73");
	socketManager.loop();
	assert(ready);
	assert(client.state_ == DbusConnectionState.ready);
	assert(script.starts == 2);
}

debug(ae_unittest) unittest
{
	immutable string[] guids = [
		"00000000000000000000000000000001",
		"00000000000000000000000000000002",
		"00000000000000000000000000000003",
		"00000000000000000000000000000004",
		"00000000000000000000000000000005",
	];
	auto candidates = parseDbusAddress(
		"unix:path=/tmp/ae-dbus-client-one,guid=" ~ guids[0] ~ ";" ~
		"unix:path=/tmp/ae-dbus-client-two,guid=" ~ guids[1] ~ ";" ~
		"unix:path=/tmp/ae-dbus-client-three,guid=" ~ guids[2] ~ ";" ~
		"unix:path=/tmp/ae-dbus-client-four,guid=" ~ guids[3] ~ ";" ~
		"unix:path=/tmp/ae-dbus-client-five,guid=" ~ guids[4]);
	auto script = new DbusClientTestAttemptScript;
	auto client = new DbusConnection(candidates,
		(candidate) { return script.create(candidate); },
		(transport, candidate) { script.start(transport, candidate); });
	assert(script.starts == 1);

	bool ready;
	client.ready.then((DbusUniqueName) { ready = true; }, (Exception) {
		assert(false);
	}).ignoreResult();

	script.transports[0].peerDisconnect("refused", DisconnectType.error);
	assert(script.starts == 2);

	auto authenticationFailure = script.transports[1];
	authenticationFailure.disconnectSynchronously = true;
	authenticationFailure.connect();
	authenticationFailure.receive(Data("REJECTED EXTERNAL\r\n".asBytes));
	assert(authenticationFailure.disconnectCount == 1);
	assert(script.starts == 3);

	auto guidFailure = script.transports[2];
	guidFailure.disconnectSynchronously = true;
	guidFailure.connect();
	guidFailure.receive(Data(
		"OK fedcba98765432100123456789abcdef\r\n".asBytes));
	assert(guidFailure.disconnectCount == 1);
	assert(script.starts == 4);

	auto helloFailure = script.transports[3];
	helloFailure.disconnectSynchronously = true;
	dbusClientTestAuthenticate(helloFailure, 1, guids[3]);
	helloFailure.receive(dbusClientTestError(1,
		"org.freedesktop.DBus.Error.Failed", "Hello rejected"));
	assert(helloFailure.disconnectCount == 1);
	assert(script.starts == 5);

	auto success = script.transports[4];
	dbusClientTestAuthenticate(success, 2, guids[4]);
	dbusClientTestReady(success, ":1.55", 2);
	socketManager.loop();
	assert(ready);
	assert(client.uniqueName.text == ":1.55");
	assert(client.decoder_.bufferedLength == 0);
	assert(script.createdCandidates.length == 5);
	assert(script.startedCandidates.length == 5);
	assert(script.expectedGuids.length == 5);
	foreach (index; 0 .. guids.length)
	{
		assert(script.createdCandidates[index].expectedGuid.text == guids[index]);
		assert(script.startedCandidates[index].expectedGuid.text == guids[index]);
		assert(script.expectedGuids[index].text == guids[index]);
		foreach (later; index + 1 .. script.transports.length)
			assert(script.transports[index] !is script.transports[later]);
	}
}

debug(ae_unittest) unittest
{
	auto script = new DbusClientTestAttemptScript;
	auto client = dbusClientTestConnect(script);
	auto transport = script.transports[0];
	dbusClientTestAuthenticate(transport);
}

debug(ae_unittest) unittest
{
	auto helloReply = dbusClientTestMethodReturn(1, DbusBody.from(":1.88"));
	foreach (split; 0 .. helloReply.length + 1)
	{
		auto script = new DbusClientTestAttemptScript;
		auto client = dbusClientTestConnect(script);
		auto transport = script.transports[0];
		bool ready;
		client.ready.then((DbusUniqueName name) {
			assert(name.text == ":1.88");
			assert(client.uniqueName.text == ":1.88");
			ready = true;
		}, (Exception) {
			assert(false);
		}).ignoreResult();

		transport.connect();
		ubyte[] first = ("OK " ~ dbusClientTestServerGuid ~ "\r\n").asBytes.dup;
		first ~= helloReply.toGC[0 .. split];
		transport.receive(Data(first));
		assert(transport.sent.length == 4);
		if (split < helloReply.length)
			transport.receive(helloReply[split .. $]);
		socketManager.loop();
		assert(ready);
	}

	{
		auto script = new DbusClientTestAttemptScript;
		auto client = dbusClientTestConnect(script);
		auto transport = script.transports[0];
		bool ready;
		client.ready.then((DbusUniqueName name) {
			assert(name.text == ":1.88");
			ready = true;
		}, (Exception) {
			assert(false);
		}).ignoreResult();
		transport.connect();
		auto suffix = helloReply.toGC ~
			dbusClientTestMethodReturn(999, DbusBody.from("unmatched suffix")).toGC;
		transport.receive(Data(("OK " ~ dbusClientTestServerGuid ~ "\r\n").asBytes ~ suffix));
		socketManager.loop();
		assert(ready);
		assert(client.state_ == DbusConnectionState.ready);
		assert(transport.sent.length == 4);
	}
}

debug(ae_unittest) unittest
{
	auto script = new DbusClientTestAttemptScript;
	auto client = dbusClientTestConnect(script);
	auto transport = script.transports[0];
	transport.connect();

	auto pending = client.call(dbusClientTestCall("Deferred"));
	DbusMessage pendingReply;
	Exception pendingError;
	pending.then((DbusMessage reply) {
		pendingReply = reply;
	}, (Exception exception) {
		pendingError = exception;
	}).ignoreResult();
	assert(transport.sent.length == 2);

	transport.receive(Data(("OK " ~ dbusClientTestServerGuid ~ "\r\n").asBytes));
	assert(transport.sent.length == 4);
	dbusClientTestReady(transport, ":1.17");
	assert(client.uniqueName.text == ":1.17");
	assert(transport.sent.length == 4);

	socketManager.loop();
	assert(transport.sent.length == 5);
	auto request = decodeDbusMessage(transport.sent[4].toGC);
	assert(request.messageType == DbusMessageType.methodCall);
	assert(request.serial == 2);
	assert(request.headers.member.text == "Deferred");

	transport.receive(dbusClientTestMethodReturn(request.serial,
		DbusBody.from("completed")));
	socketManager.loop();
	assert(pendingError is null);
	assert(pendingReply.serial == 100);
	assert(pendingReply.body.values[0].get!string() == "completed");
}

debug(ae_unittest) unittest
{
	auto script = new DbusClientTestAttemptScript;
	auto client = dbusClientTestConnect(script);
	auto transport = script.transports[0];
	dbusClientTestAuthenticate(transport);

	bool ready;
	Exception readyError;
	client.ready.then((DbusUniqueName) {
		ready = true;
	}, (Exception exception) {
		readyError = exception;
	}).ignoreResult();
	transport.receive(dbusClientTestError(1,
		"org.freedesktop.DBus.Error.Failed", "Hello failed"));
	assert(transport.disconnectCount == 1);
	assert(transport.disconnectReason == "Hello failed");
	assert(transport.disconnectType == DisconnectType.error);

	socketManager.loop();
	assert(!ready);
	auto remote = cast(DbusRemoteError) readyError;
	assert(remote !is null);
	assert(remote.errorName.text == "org.freedesktop.DBus.Error.Failed");
	assert(remote.remoteMessage == "Hello failed");
	assert(remote.reply.headers.replySerial == 1);

	auto terminalCall = client.call(dbusClientTestCall("AfterHelloError"));
	Exception terminalCallError;
	terminalCall.then((DbusMessage) {
		assert(false);
	}, (Exception exception) {
		terminalCallError = exception;
	}).ignoreResult();
	socketManager.loop();
	assert(terminalCallError is readyError);
}

debug(ae_unittest) unittest
{
	DbusBody[] malformedBodies = [
		DbusBody.from(true),
		DbusBody.from(":1.5", ":1.6"),
		DbusBody.from("org.example.NotUnique"),
	];
	foreach (body; malformedBodies)
	{
		auto script = new DbusClientTestAttemptScript;
		auto client = dbusClientTestConnect(script);
		auto transport = script.transports[0];
		dbusClientTestAuthenticate(transport);
		transport.disconnectSynchronously = true;
		Exception readyError;
		client.ready.then((DbusUniqueName) {
			assert(false);
		}, (Exception exception) {
			readyError = exception;
		}).ignoreResult();
		transport.receive(dbusClientTestMethodReturn(1, body));
		socketManager.loop();
		assert(cast(DbusProtocolException) readyError !is null);
		assert(readyError is client.terminalCause_);
		assert(transport.disconnectCount == 1);
		assert(transport.disconnectType == DisconnectType.error);
	}

	{
		auto script = new DbusClientTestAttemptScript;
		auto client = dbusClientTestConnect(script);
		auto transport = script.transports[0];
		dbusClientTestAuthenticate(transport);

		DbusMessage unmatchedCall;
		unmatchedCall.messageType = DbusMessageType.methodCall;
		unmatchedCall.serial = 200;
		unmatchedCall.headers.path = DbusObjectPath.parse("/org/example/PreReady");
		unmatchedCall.headers.member = DbusMemberName.parse("Ignored");
		unmatchedCall.body = DbusBody.from();
		assert(encodeDbusMessage(unmatchedCall).length);
		client.routeIncomingMessage(unmatchedCall);

		DbusMessage unmatchedSignal;
		unmatchedSignal.messageType = DbusMessageType.signal;
		unmatchedSignal.serial = 201;
		unmatchedSignal.headers.path = DbusObjectPath.parse("/org/example/PreReady");
		unmatchedSignal.headers.interfaceName = DbusInterfaceName.parse("org.example.PreReady");
		unmatchedSignal.headers.member = DbusMemberName.parse("Ignored");
		unmatchedSignal.body = DbusBody.from();
		assert(encodeDbusMessage(unmatchedSignal).length);
		client.routeIncomingMessage(unmatchedSignal);
		assert(client.state_ == DbusConnectionState.awaitingHello);
		assert(transport.sent.length == 4);

		DbusMessage wrongKind = unmatchedCall;
		wrongKind.serial = 202;
		wrongKind.headers.replySerial = 1;
		assert(encodeDbusMessage(wrongKind).length);
		Exception readyError;
		client.ready.then((DbusUniqueName) {
			assert(false);
		}, (Exception exception) {
			readyError = exception;
		}).ignoreResult();
		client.routeIncomingMessage(wrongKind);
		socketManager.loop();
		assert(cast(DbusProtocolException) readyError !is null);
		assert(readyError is client.terminalCause_);
		assert(transport.disconnectCount == 1);
	}

	{
		auto script = new DbusClientTestAttemptScript;
		auto client = dbusClientTestConnect(script);
		auto transport = script.transports[0];
		dbusClientTestAuthenticate(transport);
		Exception readyError;
		client.ready.then((DbusUniqueName) {
			assert(false);
		}, (Exception exception) {
			readyError = exception;
		}).ignoreResult();
		transport.peerDisconnect("closed while awaiting Hello", DisconnectType.graceful);
		socketManager.loop();
		auto disconnected = cast(DbusDisconnectedException) readyError;
		assert(disconnected !is null);
		assert(disconnected.reason == "closed while awaiting Hello");
		assert(disconnected.disconnectType == DisconnectType.graceful);
	}
}

debug(ae_unittest) unittest
{
	auto script = new DbusClientTestAttemptScript;
	auto client = dbusClientTestConnect(script);
	auto transport = script.transports[0];
	dbusClientTestAuthenticate(transport);
	dbusClientTestReady(transport);

	auto first = client.call(dbusClientTestCall("First"));
	auto second = client.call(dbusClientTestCall("Second"));
	assert(transport.sent.length == 6);
	auto firstRequest = decodeDbusMessage(transport.sent[4].toGC);
	auto secondRequest = decodeDbusMessage(transport.sent[5].toGC);
	assert(firstRequest.serial == 2);
	assert(secondRequest.serial == 3);

	DbusMessage firstReply;
	DbusMessage secondReply;
	Exception firstError;
	Exception secondError;
	first.then((DbusMessage reply) {
		assert(!(firstRequest.serial in client.pendingCalls_));
		firstReply = reply;
	}, (Exception exception) {
		firstError = exception;
	}).ignoreResult();
	second.then((DbusMessage reply) {
		assert(!(secondRequest.serial in client.pendingCalls_));
		secondReply = reply;
	}, (Exception exception) {
		secondError = exception;
	}).ignoreResult();
	transport.receive(dbusClientTestMethodReturn(secondRequest.serial,
		DbusBody.from("second reply")));
	transport.receive(dbusClientTestMethodReturn(firstRequest.serial,
		DbusBody.from("first reply")));
	socketManager.loop();
	assert(firstError is null);
	assert(secondError is null);
	assert(firstReply.body.values[0].get!string() == "first reply");
	assert(secondReply.body.values[0].get!string() == "second reply");

	auto rejected = client.call(dbusClientTestCall("Rejected"));
	auto rejectedRequest = decodeDbusMessage(transport.sent[6].toGC);
	assert(rejectedRequest.serial == 4);
	Exception rejectedError;
	rejected.then((DbusMessage) {
		assert(false);
	}, (Exception exception) {
		assert(!(rejectedRequest.serial in client.pendingCalls_));
		rejectedError = exception;
	}).ignoreResult();
	transport.receive(dbusClientTestError(rejectedRequest.serial,
		"org.example.Error.Denied", "access denied"));
	socketManager.loop();
	auto remote = cast(DbusRemoteError) rejectedError;
	assert(remote !is null);
	assert(remote.errorName.text == "org.example.Error.Denied");
	assert(remote.remoteMessage == "access denied");
	assert(remote.reply.headers.replySerial == rejectedRequest.serial);
}

debug(ae_unittest) unittest
{
	auto script = new DbusClientTestAttemptScript;
	auto client = dbusClientTestConnect(script);
	auto transport = script.transports[0];
	dbusClientTestAuthenticate(transport);
	dbusClientTestReady(transport);
	auto first = client.call(dbusClientTestCall("EmptyReply"));
	auto second = client.call(dbusClientTestCall("MultiReply"));
	auto firstRequest = decodeDbusMessage(transport.sent[4].toGC);
	auto secondRequest = decodeDbusMessage(transport.sent[5].toGC);
	string[] order;
	DbusMessage emptyReply;
	DbusMessage multiReply;
	first.then((DbusMessage reply) {
		assert(!(firstRequest.serial in client.pendingCalls_));
		order ~= "empty";
		emptyReply = reply;
	}, (Exception) {
		assert(false);
	}).ignoreResult();
	second.then((DbusMessage reply) {
		assert(!(secondRequest.serial in client.pendingCalls_));
		order ~= "multi";
		multiReply = reply;
	}, (Exception) {
		assert(false);
	}).ignoreResult();
	transport.receive(dbusClientTestMethodReturn(secondRequest.serial,
		DbusBody.from("second", cast(uint) 7)) ~
		dbusClientTestMethodReturn(firstRequest.serial, DbusBody.from()));
	socketManager.loop();
	assert(order == ["multi", "empty"]);
	assert(emptyReply.body.signature.text == "");
	assert(emptyReply.body.values.length == 0);
	assert(multiReply.body.signature.text == "su");
	assert(multiReply.body.values[0].get!string() == "second");
	assert(multiReply.body.values[1].get!uint() == 7);
	assert(client.pendingCalls_.length == 0);
}

debug(ae_unittest) unittest
{
	auto script = new DbusClientTestAttemptScript;
	auto client = dbusClientTestConnect(script, 2);
	auto transport = script.transports[0];
	dbusClientTestAuthenticate(transport);
	bool ready;
	client.ready.then((DbusUniqueName name) {
		assert(name.text == ":1.200");
		assert(client.uniqueName.text == ":1.200");
		ready = true;
	}, (Exception) {
		assert(false);
	}).ignoreResult();
	transport.disconnectSynchronously = true;
	transport.receive(dbusClientTestMethodReturn(1, DbusBody.from(":1.200")) ~
		dbusClientTestInvalidFixedHeader());
	socketManager.loop();
	assert(ready);
	auto protocol = cast(DbusProtocolException) client.terminalCause_;
	assert(protocol !is null);
	assert(transport.disconnectCount == 1);
	assert(transport.disconnectType == DisconnectType.error);
	assert(script.starts == 1);
	assert(client.state_ == DbusConnectionState.terminal);
}

debug(ae_unittest) unittest
{
	auto script = new DbusClientTestAttemptScript;
	auto client = dbusClientTestConnect(script);
	auto transport = script.transports[0];
	dbusClientTestAuthenticate(transport);
	dbusClientTestReady(transport);
	auto call = client.call(dbusClientTestCall("ReplyBeforeInvalid"));
	auto request = decodeDbusMessage(transport.sent[4].toGC);
	DbusMessage reply;
	Exception callError;
	call.then((DbusMessage message) {
		assert(!(request.serial in client.pendingCalls_));
		reply = message;
	}, (Exception exception) {
		callError = exception;
	}).ignoreResult();
	transport.disconnectSynchronously = true;
	transport.receive(dbusClientTestMethodReturn(request.serial,
		DbusBody.from("settled before terminal")) ~ dbusClientTestInvalidFixedHeader());
	socketManager.loop();
	assert(callError is null);
	assert(reply.body.values[0].get!string() == "settled before terminal");
	assert(client.pendingCalls_.length == 0);
	assert(cast(DbusProtocolException) client.terminalCause_ !is null);
	assert(transport.disconnectCount == 1);
}

debug(ae_unittest) unittest
{
	auto script = new DbusClientTestAttemptScript;
	auto client = dbusClientTestConnect(script);
	auto transport = script.transports[0];
	dbusClientTestAuthenticate(transport);
	dbusClientTestReady(transport);

	client.nextSerial_ = 0;
	auto first = client.call(dbusClientTestCall("LiveOne"));
	auto firstRequest = decodeDbusMessage(transport.sent[4].toGC);
	assert(firstRequest.serial == 1);
	bool registeredBeforeSend;
	transport.onSend = (Data frame) {
		auto message = decodeDbusMessage(frame.toGC);
		if (message.headers.member.text == "LiveTwo")
		{
			assert(message.serial == 2);
			assert(2 in client.pendingCalls_);
			assert(transport.sendDataCounts[$ - 1] == 1);
			registeredBeforeSend = true;
		}
	};
	auto secondCall = dbusClientTestCall("LiveTwo");
	secondCall.options.noAutoStart = true;
	secondCall.options.allowInteractiveAuthorization = true;
	auto second = client.call(secondCall);
	assert(registeredBeforeSend);
	auto secondRequest = decodeDbusMessage(transport.sent[5].toGC);
	assert(secondRequest.serial == 2);
	assert(secondRequest.flags == cast(ubyte) (DbusMessageFlag.noAutoStart |
		DbusMessageFlag.allowInteractiveAuthorization));
	assert(!(secondRequest.flags & DbusMessageFlag.noReplyExpected));

	client.nextSerial_ = uint.max;
	auto atMaximum = client.call(dbusClientTestCall("AtMaximum"));
	auto maximumRequest = decodeDbusMessage(transport.sent[6].toGC);
	assert(maximumRequest.serial == uint.max);
	auto afterWrap = client.call(dbusClientTestCall("AfterZeroAndLiveCollisions"));
	auto wrappedRequest = decodeDbusMessage(transport.sent[7].toGC);
	assert(wrappedRequest.serial == 3);
	assert(wrappedRequest.serial != 0);

	assert(transport.sent.length == 8);
	assert(client.pendingCalls_.length == 4);
	assert(client.pendingCalls_[1].promise is first);
	assert(client.pendingCalls_[2].promise is second);
	assert(client.pendingCalls_[uint.max].promise is atMaximum);
	assert(client.pendingCalls_[3].promise is afterWrap);
	first.ignoreResult();
	second.ignoreResult();
	atMaximum.ignoreResult();
	afterWrap.ignoreResult();
}

debug(ae_unittest) unittest
{
	auto script = new DbusClientTestAttemptScript;
	auto client = dbusClientTestConnect(script);
	auto transport = script.transports[0];
	dbusClientTestAuthenticate(transport);
	dbusClientTestReady(transport);

	auto request = dbusClientTestCall("ValidAfterValidation");
	auto sentCount = transport.sent.length;
	auto nextSerial = client.nextSerial_;
	auto pendingCount = client.pendingCalls_.length;
	void assertUnchanged()
	{
		assert(transport.sent.length == sentCount);
		assert(client.nextSerial_ == nextSerial);
		assert(client.pendingCalls_.length == pendingCount);
		assert(transport.disconnectCount == 0);
	}
	void expectValidation(DbusMethodCall invalid)
	{
		bool caught;
		try
			client.call(invalid);
		catch (DbusValidationException)
			caught = true;
		assert(caught);
		assertUnchanged();
	}

	auto missingDestination = request;
	missingDestination.destination = DbusBusName.init;
	expectValidation(missingDestination);
	auto missingPath = request;
	missingPath.path = DbusObjectPath.init;
	expectValidation(missingPath);
	auto missingInterface = request;
	missingInterface.interfaceName = DbusInterfaceName.init;
	expectValidation(missingInterface);
	auto missingMember = request;
	missingMember.member = DbusMemberName.init;
	expectValidation(missingMember);

	DbusValue[] mismatchedValues = [DbusValue.of!string("not a uint32")];
	auto mismatched = request;
	mismatched.body = dbusTestMalformedBody(DbusSignature.parse("u"),
		mismatchedValues);
	expectValidation(mismatched);

	DbusValue[] unsupportedValues;
	auto unsupported = request;
	unsupported.body = dbusTestMalformedBody(DbusSignature.parse("h"),
		unsupportedValues);
	bool unsupportedCaught;
	try
		client.call(unsupported);
	catch (DbusUnsupportedException)
		unsupportedCaught = true;
	assert(unsupportedCaught);
	assertUnchanged();

	DbusMessage validReply;
	Exception validError;
	auto valid = client.call(request);
	valid.then((DbusMessage reply) {
		validReply = reply;
	}, (Exception exception) {
		validError = exception;
	}).ignoreResult();
	assert(transport.sent.length == sentCount + 1);
	auto validRequest = decodeDbusMessage(transport.sent[$ - 1].toGC);
	assert(validRequest.serial == nextSerial);
	assert(validRequest.serial in client.pendingCalls_);
	transport.receive(dbusClientTestMethodReturn(validRequest.serial,
		DbusBody.from("valid reply")));
	socketManager.loop();
	assert(validError is null);
	assert(validReply.body.values[0].get!string() == "valid reply");
	assert(client.pendingCalls_.length == 0);
	assert(client.state_ == DbusConnectionState.ready);
}

debug(ae_unittest) unittest
{
	auto script = new DbusClientTestAttemptScript;
	auto client = dbusClientTestConnect(script);
	auto transport = script.transports[0];
	dbusClientTestAuthenticate(transport);
	dbusClientTestReady(transport);
	auto name = DbusBusName.parse("org.example.Service");

	auto owner = client.getNameOwner(name);
	bool ownerReady;
	owner.then((DbusUniqueName value) {
		assert(value.text == ":1.75");
		ownerReady = true;
	}, (Exception) {
		assert(false);
	}).ignoreResult();
	auto ownerRequest = decodeDbusMessage(transport.sent[4].toGC);
	assert(ownerRequest.headers.member.text == "GetNameOwner");
	assert(ownerRequest.body.signature.text == "s");
	assert(ownerRequest.body.values[0].get!string() == name.text);
	transport.receive(dbusClientTestMethodReturn(ownerRequest.serial,
		DbusBody.from(":1.75")));
	socketManager.loop();
	assert(ownerReady);

	auto hasOwner = client.nameHasOwner(name);
	bool hasOwnerResult;
	hasOwner.then((bool value) {
		hasOwnerResult = value;
	}, (Exception) {
		assert(false);
	}).ignoreResult();
	auto hasOwnerRequest = decodeDbusMessage(transport.sent[5].toGC);
	assert(hasOwnerRequest.headers.member.text == "NameHasOwner");
	assert(hasOwnerRequest.body.signature.text == "s");
	transport.receive(dbusClientTestMethodReturn(hasOwnerRequest.serial,
		DbusBody.from(true)));
	socketManager.loop();
	assert(hasOwnerResult);

	auto wrongOwner = client.getNameOwner(name);
	Exception wrongOwnerError;
	wrongOwner.then((DbusUniqueName) {
		assert(false);
	}, (Exception exception) {
		wrongOwnerError = exception;
	}).ignoreResult();
	auto wrongOwnerRequest = decodeDbusMessage(transport.sent[6].toGC);
	transport.receive(dbusClientTestMethodReturn(wrongOwnerRequest.serial,
		DbusBody.from(true)));
	socketManager.loop();
	assert(cast(DbusTypeMismatchException) wrongOwnerError !is null);

	auto wrongBoolean = client.nameHasOwner(name);
	Exception wrongBooleanError;
	wrongBoolean.then((bool) {
		assert(false);
	}, (Exception exception) {
		wrongBooleanError = exception;
	}).ignoreResult();
	auto wrongBooleanRequest = decodeDbusMessage(transport.sent[7].toGC);
	transport.receive(dbusClientTestMethodReturn(wrongBooleanRequest.serial,
		DbusBody.from("not a boolean")));
	socketManager.loop();
	assert(cast(DbusTypeMismatchException) wrongBooleanError !is null);

	auto ownerArity = client.getNameOwner(name);
	Exception ownerArityError;
	ownerArity.then((DbusUniqueName) {
		assert(false);
	}, (Exception exception) {
		ownerArityError = exception;
	}).ignoreResult();
	auto ownerArityRequest = decodeDbusMessage(transport.sent[$ - 1].toGC);
	transport.receive(dbusClientTestMethodReturn(ownerArityRequest.serial,
		DbusBody.from(":1.10", ":1.11")));
	socketManager.loop();
	assert(cast(DbusTypeMismatchException) ownerArityError !is null);

	auto ownerValue = client.getNameOwner(name);
	Exception ownerValueError;
	ownerValue.then((DbusUniqueName) {
		assert(false);
	}, (Exception exception) {
		ownerValueError = exception;
	}).ignoreResult();
	auto ownerValueRequest = decodeDbusMessage(transport.sent[$ - 1].toGC);
	transport.receive(dbusClientTestMethodReturn(ownerValueRequest.serial,
		DbusBody.from("org.example.NotUnique")));
	socketManager.loop();
	assert(cast(DbusTypeMismatchException) ownerValueError !is null);

	auto booleanArity = client.nameHasOwner(name);
	Exception booleanArityError;
	booleanArity.then((bool) {
		assert(false);
	}, (Exception exception) {
		booleanArityError = exception;
	}).ignoreResult();
	auto booleanArityRequest = decodeDbusMessage(transport.sent[$ - 1].toGC);
	transport.receive(dbusClientTestMethodReturn(booleanArityRequest.serial,
		DbusBody.from(true, false)));
	socketManager.loop();
	assert(cast(DbusTypeMismatchException) booleanArityError !is null);

	auto malformedBoolean = client.nameHasOwner(name);
	Exception malformedBooleanError;
	malformedBoolean.then((bool) {
		assert(false);
	}, (Exception exception) {
		malformedBooleanError = exception;
	}).ignoreResult();
	auto malformedBooleanRequest = decodeDbusMessage(transport.sent[$ - 1].toGC);
	DbusValue[] malformedBooleanValues = [DbusValue.of!string("not a boolean")];
	DbusMessage malformedBooleanReply;
	malformedBooleanReply.messageType = DbusMessageType.methodReturn;
	malformedBooleanReply.serial = 300;
	malformedBooleanReply.headers.replySerial = malformedBooleanRequest.serial;
	malformedBooleanReply.body = dbusTestMalformedBody(DbusSignature.parse("b"),
		malformedBooleanValues);
	client.routeIncomingMessage(malformedBooleanReply);
	socketManager.loop();
	assert(cast(DbusTypeMismatchException) malformedBooleanError !is null);

	auto remoteOwner = client.getNameOwner(name);
	Exception remoteOwnerError;
	remoteOwner.then((DbusUniqueName) {
		assert(false);
	}, (Exception exception) {
		remoteOwnerError = exception;
	}).ignoreResult();
	auto remoteOwnerRequest = decodeDbusMessage(transport.sent[$ - 1].toGC);
	transport.receive(dbusClientTestError(remoteOwnerRequest.serial,
		"org.example.Error.Owner", "owner failed"));
	socketManager.loop();
	auto remoteOwnerCause = cast(DbusRemoteError) remoteOwnerError;
	assert(remoteOwnerCause !is null);
	assert(remoteOwnerCause.errorName.text == "org.example.Error.Owner");
	assert(remoteOwnerCause.remoteMessage == "owner failed");
	assert(remoteOwnerCause.reply.headers.replySerial == remoteOwnerRequest.serial);

	auto emptyRemoteHasOwner = client.nameHasOwner(name);
	Exception emptyRemoteHasOwnerError;
	emptyRemoteHasOwner.then((bool) {
		assert(false);
	}, (Exception exception) {
		emptyRemoteHasOwnerError = exception;
	}).ignoreResult();
	auto emptyRemoteHasOwnerRequest = decodeDbusMessage(transport.sent[$ - 1].toGC);
	DbusMessage emptyRemoteHasOwnerReply;
	emptyRemoteHasOwnerReply.messageType = DbusMessageType.error;
	emptyRemoteHasOwnerReply.serial = 301;
	emptyRemoteHasOwnerReply.headers.errorName =
		DbusErrorName.parse("org.example.Error.EmptyOwner");
	emptyRemoteHasOwnerReply.headers.replySerial =
		emptyRemoteHasOwnerRequest.serial;
	emptyRemoteHasOwnerReply.body = DbusBody.from();
	transport.receive(encodeDbusMessage(emptyRemoteHasOwnerReply));
	socketManager.loop();
	auto emptyRemoteHasOwnerCause =
		cast(DbusRemoteError) emptyRemoteHasOwnerError;
	assert(emptyRemoteHasOwnerCause !is null);
	assert(emptyRemoteHasOwnerError is emptyRemoteHasOwnerCause);
	assert(emptyRemoteHasOwnerCause.errorName.text ==
		"org.example.Error.EmptyOwner");
	assert(emptyRemoteHasOwnerCause.remoteMessage is null);
	assert(emptyRemoteHasOwnerCause.reply.messageType == DbusMessageType.error);
	assert(emptyRemoteHasOwnerCause.reply.serial == 301);
	assert(emptyRemoteHasOwnerCause.reply.headers.replySerial ==
		emptyRemoteHasOwnerRequest.serial);
	assert(emptyRemoteHasOwnerCause.reply.body.signature.text == "");
	assert(emptyRemoteHasOwnerCause.reply.body.values.length == 0);
	assert(client.state_ == DbusConnectionState.ready);

	auto stillUsable = client.nameHasOwner(name);
	bool stillUsableResult;
	stillUsable.then((bool value) {
		stillUsableResult = value;
	}, (Exception) {
		assert(false);
	}).ignoreResult();
	auto stillUsableRequest = decodeDbusMessage(transport.sent[$ - 1].toGC);
	transport.receive(dbusClientTestMethodReturn(stillUsableRequest.serial,
		DbusBody.from(true)));
	socketManager.loop();
	assert(stillUsableResult);
}

debug(ae_unittest) unittest
{
	auto script = new DbusClientTestAttemptScript;
	auto client = dbusClientTestConnect(script);
	auto transport = script.transports[0];
	dbusClientTestAuthenticate(transport);
	dbusClientTestReady(transport);

	transport.receive(dbusClientTestMethodReturn(999, DbusBody.from("unmatched")));
	assert(transport.sent.length == 4);

	DbusMessage signal;
	signal.messageType = DbusMessageType.signal;
	signal.serial = 200;
	signal.headers.path = DbusObjectPath.parse("/org/example/Signal");
	signal.headers.interfaceName = DbusInterfaceName.parse("org.example.Signal");
	signal.headers.member = DbusMemberName.parse("Changed");
	signal.body = DbusBody.from("ignored");
	transport.receive(encodeDbusMessage(signal));
	assert(transport.sent.length == 4);

	DbusMessage unknown;
	unknown.messageType = 42;
	unknown.serial = 201;
	unknown.body = DbusBody.from();
	transport.receive(encodeDbusMessage(unknown));
	assert(transport.sent.length == 4);
	assert(client.state_ == DbusConnectionState.ready);

	auto remote = client.call(dbusClientTestCall("NonStringRemoteMessage"));
	Exception remoteError;
	remote.then((DbusMessage) {
		assert(false);
	}, (Exception exception) {
		remoteError = exception;
	}).ignoreResult();
	auto remoteRequest = decodeDbusMessage(transport.sent[4].toGC);
	DbusMessage error;
	error.messageType = DbusMessageType.error;
	error.serial = 202;
	error.headers.errorName = DbusErrorName.parse("org.example.Error.NotString");
	error.headers.replySerial = remoteRequest.serial;
	error.body = DbusBody.from(cast(uint) 7);
	transport.receive(encodeDbusMessage(error));
	socketManager.loop();
	auto typed = cast(DbusRemoteError) remoteError;
	assert(typed !is null);
	assert(typed.remoteMessage is null);
	assert(typed.reply.body.signature.text == "u");
	assert(client.state_ == DbusConnectionState.ready);
}

debug(ae_unittest) unittest
{
	auto script = new DbusClientTestAttemptScript;
	auto client = dbusClientTestConnect(script);
	auto transport = script.transports[0];
	dbusClientTestAuthenticate(transport);
	dbusClientTestReady(transport);

	DbusMessage incoming;
	incoming.messageType = DbusMessageType.methodCall;
	incoming.serial = 77;
	incoming.headers.path = DbusObjectPath.parse("/org/example/Unknown");
	incoming.headers.interfaceName = DbusInterfaceName.parse("org.example.Unknown");
	incoming.headers.member = DbusMemberName.parse("Call");
	incoming.headers.sender = DbusBusName.parse(":1.99");
	incoming.body = DbusBody.from();
	transport.receive(encodeDbusMessage(incoming));
	assert(transport.sent.length == 5);
	auto reply = decodeDbusMessage(transport.sent[4].toGC);
	assert(reply.messageType == DbusMessageType.error);
	assert(reply.serial == 2);
	assert(reply.headers.errorName.text ==
		"org.freedesktop.DBus.Error.UnknownObject");
	assert(reply.headers.replySerial == 77);
	assert(reply.headers.destination.text == ":1.99");
	assert(reply.body.signature.text == "");

	incoming.serial = 78;
	incoming.flags = DbusMessageFlag.noReplyExpected;
	auto sentCount = transport.sent.length;
	auto nextSerial = client.nextSerial_;
	auto pendingCount = client.pendingCalls_.length;
	transport.receive(encodeDbusMessage(incoming));
	assert(transport.sent.length == sentCount);
	assert(client.nextSerial_ == nextSerial);
	assert(client.pendingCalls_.length == pendingCount);
	auto nextCall = client.call(dbusClientTestCall("AfterNoReplyExpected"));
	assert(decodeDbusMessage(transport.sent[$ - 1].toGC).serial == nextSerial);
	nextCall.ignoreResult();
}

debug(ae_unittest) unittest
{
	auto script = new DbusClientTestAttemptScript;
	auto client = dbusClientTestConnect(script);
	auto transport = script.transports[0];
	dbusClientTestAuthenticate(transport);
	dbusClientTestReady(transport);

	auto pending = client.call(dbusClientTestCall("Pending"));
	Exception pendingError;
	pending.then((DbusMessage) {
		assert(false);
	}, (Exception exception) {
		pendingError = exception;
	}).ignoreResult();
	client.disconnect("client requested close");
	assert(transport.disconnectCount == 1);
	assert(transport.disconnectReason == "client requested close");
	assert(transport.disconnectType == DisconnectType.requested);

	auto afterDisconnect = client.call(dbusClientTestCall("AfterDisconnect"));
	Exception afterDisconnectError;
	afterDisconnect.then((DbusMessage) {
		assert(false);
	}, (Exception exception) {
		afterDisconnectError = exception;
	}).ignoreResult();
	socketManager.loop();
	auto cause = cast(DbusDisconnectedException) pendingError;
	assert(cause !is null);
	assert(cause.reason == "client requested close");
	assert(cause.disconnectType == DisconnectType.requested);
	assert(afterDisconnectError is pendingError);
}

debug(ae_unittest) unittest
{
	foreach (phase; 0 .. 3)
	{
		auto script = new DbusClientTestAttemptScript;
		auto client = dbusClientTestConnect(script, 2);
		auto transport = script.transports[0];
		if (phase >= 1)
			transport.connect();
		if (phase >= 2)
			transport.receive(Data(("OK " ~ dbusClientTestServerGuid ~ "\r\n").asBytes));

		Exception readyError;
		client.ready.then((DbusUniqueName) {
			assert(false);
		}, (Exception exception) {
			readyError = exception;
		}).ignoreResult();
		client.disconnect("explicit pre-ready disconnect");
		assert(script.starts == 1);
		assert(client.state_ == DbusConnectionState.terminal);
		if (phase == 0)
			assert(transport.disconnectCount == 0);
		else
		{
			assert(transport.disconnectCount == 1);
			assert(transport.disconnectType == DisconnectType.requested);
		}
		socketManager.loop();
		auto disconnected = cast(DbusDisconnectedException) readyError;
		assert(disconnected !is null);
		assert(disconnected.reason == "explicit pre-ready disconnect");
	}

	auto invalid = new DbusClientTestConnection;
	bool caught;
	try
		new DbusConnection(invalid);
	catch (AssertError)
		caught = true;
	assert(caught);
	assert(invalid.connectHandler is null);
	assert(invalid.readDataHandler is null);
	assert(invalid.disconnectHandler is null);
	assert(invalid.bufferFlushedHandler is null);

	auto attached = new DbusClientTestConnection;
	attached.state_ = ConnectionState.connected;
	auto attachedClient = new DbusConnection(attached);
	attachedClient.ready.ignoreResult();
	assert(attached.sent.length == 2);
	assert(attached.sent[0].toGC == [cast(ubyte) 0]);
	assert(attached.sent[1].toGC == ("AUTH EXTERNAL " ~
		dbusClientTestExternalIdentity() ~ "\r\n").asBytes);
	attachedClient.disconnect();
}

debug(ae_unittest) unittest
{
	Data[] invalidInputs = [dbusClientTestInvalidFixedHeader(),
		dbusClientTestUnixFdsFrame()];
	foreach (readyPhase; [false, true])
	foreach (input; invalidInputs)
	{
		auto script = new DbusClientTestAttemptScript;
		auto client = dbusClientTestConnect(script);
		auto transport = script.transports[0];
		dbusClientTestAuthenticate(transport);
		transport.disconnectSynchronously = true;
		bool readySucceeded;
		Exception readyError;
		client.ready.then((DbusUniqueName) {
			readySucceeded = true;
		}, (Exception exception) {
			readyError = exception;
		}).ignoreResult();

		Exception[] pendingErrors;
		size_t rejections;
		if (readyPhase)
		{
			dbusClientTestReady(transport);
			foreach (member; ["ProtocolOne", "ProtocolTwo", "ProtocolThree"])
			{
				auto call = client.call(dbusClientTestCall(member));
				call.then((DbusMessage) {
					assert(false);
				}, (Exception exception) {
					pendingErrors ~= exception;
					rejections++;
				}).ignoreResult();
			}
			assert(client.pendingCalls_.length == 3);
		}
		else
		{
			auto queued = client.call(dbusClientTestCall("QueuedBeforeProtocolFailure"));
			queued.then((DbusMessage) {
				assert(false);
			}, (Exception exception) {
				pendingErrors ~= exception;
				rejections++;
			}).ignoreResult();
		}

		transport.receive(input);
		socketManager.loop();
		auto protocol = cast(DbusProtocolException) client.terminalCause_;
		assert(protocol !is null);
		assert(transport.disconnectCount == 1);
		assert(transport.disconnectType == DisconnectType.error);
		assert(client.pendingCalls_.length == 0);
		assert(client.decoder_.bufferedLength == 0);
		assert(client.decoder_.expectedFrameLength == 0);
		assert(client.authenticator_ is null);
		assert(client.serverGuid_.text.length == 0);
		assert(client.candidates_.length == 0);
		assert(transport.connectHandler is null);
		assert(transport.readDataHandler is null);
		assert(transport.disconnectHandler is null);
		assert(transport.bufferFlushedHandler is null);
		assert(rejections == (readyPhase ? 3 : 1));
		foreach (error; pendingErrors)
			assert(error is protocol);
		if (readyPhase)
		{
			assert(readySucceeded);
			assert(readyError is null);
		}
		else
		{
			assert(!readySucceeded);
			assert(readyError is protocol);
		}
	}
}

debug(ae_unittest) unittest
{
	auto script = new DbusClientTestAttemptScript;
	auto client = dbusClientTestConnect(script, 2);
	auto transport = script.transports[0];
	dbusClientTestAuthenticate(transport);
	dbusClientTestReady(transport);
	auto staleCallbacks = dbusClientTestCaptureCallbacks(transport);
	Promise!DbusMessage[] pending;
	Exception[] pendingErrors;
	size_t rejections;
	foreach (member; ["InterruptedOne", "InterruptedTwo", "InterruptedThree"])
	{
		auto call = client.call(dbusClientTestCall(member));
		pending ~= call;
		call.then((DbusMessage) {
			assert(false);
		}, (Exception exception) {
			pendingErrors ~= exception;
			rejections++;
		}).ignoreResult();
	}
	assert(client.pendingCalls_.length == 3);
	auto sentCount = transport.sent.length;
	auto nextSerial = client.nextSerial_;
	auto starts = script.starts;
	transport.peerDisconnect("peer closed", DisconnectType.graceful);
	socketManager.loop();
	assert(script.starts == 1);
	assert(rejections == 3);
	assert(pendingErrors.length == 3);
	auto disconnected = cast(DbusDisconnectedException) pendingErrors[0];
	assert(disconnected !is null);
	assert(disconnected.reason == "peer closed");
	assert(disconnected.disconnectType == DisconnectType.graceful);
	foreach (error; pendingErrors)
		assert(error is disconnected);
	assert(disconnected is client.terminalCause_);
	assert(client.pendingCalls_.length == 0);
	assert(client.decoder_.bufferedLength == 0);
	assert(transport.connectHandler is null);
	assert(transport.readDataHandler is null);
	assert(transport.disconnectHandler is null);
	assert(transport.bufferFlushedHandler is null);
	dbusClientTestInvokeCallbacks(staleCallbacks);
	socketManager.loop();
	assert(client.terminalCause_ is disconnected);
	assert(client.state_ == DbusConnectionState.terminal);
	assert(client.pendingCalls_.length == 0);
	assert(rejections == 3);
	assert(transport.sent.length == sentCount);
	assert(client.nextSerial_ == nextSerial);
	assert(script.starts == starts);
}

debug(ae_unittest) unittest
{
	auto refusedPath = dbusClientTestSocketPath();
	auto serverPath = dbusClientTestSocketPath();
	if (exists(refusedPath))
		remove(refusedPath);
	if (exists(serverPath))
		remove(serverPath);
	scope(exit)
	{
		if (exists(refusedPath))
			remove(refusedPath);
		if (exists(serverPath))
			remove(serverPath);
	}

	auto server = new SocketServer;
	SocketConnection accepted;
	ubyte[] authInput;
	bool authenticated;
	bool began;
	bool sawHello;
	auto decoder = new DbusFrameDecoder;
	bool timedOut;
	TimerTask timeout;
	DbusConnection client;
	SocketConnection[] constructed;

	void cleanup()
	{
		if (timeout.isWaiting())
			timeout.cancel();
		if (client !is null && client.state_ != DbusConnectionState.terminal)
			client.disconnect("D-Bus client fallback unittest cleanup");
		if (accepted !is null && disconnectable(accepted.state))
			accepted.disconnect("D-Bus client fallback unittest cleanup");
		if (server.isListening)
			server.close();
	}

	scope(exit) cleanup();
	dbusClientTestSocketObserver = (SocketConnection transport) {
		constructed ~= transport;
	};
	scope(exit) dbusClientTestSocketObserver = null;
	server.handleAccept = (SocketConnection incoming) {
		assert(accepted is null);
		accepted = incoming;
		incoming.handleReadData = (Data data) {
			authInput ~= data.toGC;
			if (!authenticated)
			{
				size_t lineEnd = size_t.max;
				foreach (index; 1 .. authInput.length)
					if (authInput[index - 1] == '\r' && authInput[index] == '\n')
					{
						lineEnd = index + 1;
						break;
					}
				if (lineEnd == size_t.max)
					return;
				assert(authInput[0] == 0);
				assert(cast(string) authInput[1 .. lineEnd] ==
					"AUTH EXTERNAL " ~ dbusClientTestExternalIdentity() ~ "\r\n");
				authInput = authInput[lineEnd .. $];
				authenticated = true;
				incoming.send(Data(("OK " ~ dbusClientTestServerGuid ~ "\r\n").asBytes));
			}
			if (!began)
			{
				if (authInput.length < 7)
					return;
				assert(authInput[0 .. 7] == "BEGIN\r\n".asBytes);
				authInput = authInput[7 .. $];
				began = true;
			}
			if (!authInput.length)
				return;
			auto messages = decoder.feed(Data(authInput));
			authInput = null;
			foreach (message; messages)
			{
				assert(!sawHello);
				assert(message.messageType == DbusMessageType.methodCall);
				assert(message.serial == 1);
				assert(message.headers.member.text == "Hello");
				sawHello = true;
				DbusMessage reply;
				reply.messageType = DbusMessageType.methodReturn;
				reply.serial = 1;
				reply.headers.replySerial = message.serial;
				reply.body = DbusBody.from(":1.900");
				incoming.send(encodeDbusMessage(reply));
			}
		};
	};
	auto serverCandidate = parseDbusAddress("unix:path=" ~ serverPath)[0];
	server.listen([serverCandidate.toAddressInfo]);

	bool ready;
	Exception readyError;
	client = connectDbusAddress("unix:path=" ~ refusedPath ~ ";unix:path=" ~ serverPath);
	client.ready.then((DbusUniqueName name) {
		assert(name.text == ":1.900");
		assert(constructed.length == 2);
		assert(constructed[0] !is constructed[1]);
		assert(constructed[0].state == ConnectionState.disconnected);
		assert(constructed[1].state == ConnectionState.connected);
		ready = true;
		timeout.cancel();
		client.disconnect("D-Bus client fallback unittest complete");
		server.close();
	}, (Exception exception) {
		readyError = exception;
		timeout.cancel();
		cleanup();
	}).ignoreResult();
	timeout = setTimeout({
		timedOut = true;
		cleanup();
	}, 5.seconds);
	socketManager.loop();

	assert(!timedOut, "D-Bus client production fallback timed out");
	assert(ready);
	assert(readyError is null);
	assert(authenticated);
	assert(began);
	assert(sawHello);
	assert(constructed.length == 2);
}

debug(ae_unittest) unittest
{
	auto script = new DbusClientTestAttemptScript;
	auto client = dbusClientTestConnect(script);
	auto transport = script.transports[0];
	dbusClientTestAuthenticate(transport);
	dbusClientTestReady(transport);

	auto match = DbusSignalMatch.signal()
		.withPath(DbusObjectPath.parse("/org/example/Object"))
		.withInterface(DbusInterfaceName.parse("org.example.Interface"))
		.withMember(DbusMemberName.parse("Changed"));
	size_t firstCalls;
	size_t secondCalls;
	DbusSubscription firstSubscription;
	DbusSubscription secondSubscription;
	bool firstReady;
	bool secondReady;
	auto first = client.subscribe(match, (const ref DbusSignalMessage signal) {
		firstCalls++;
	});
	first.then((DbusSubscription subscription) {
		firstSubscription = subscription;
		firstReady = true;
	}, (Exception) {
		assert(false);
	}).ignoreResult();
	auto second = client.subscribe(match, (const ref DbusSignalMessage signal) {
		secondCalls++;
	});
	second.then((DbusSubscription subscription) {
		secondSubscription = subscription;
		secondReady = true;
	}, (Exception) {
		assert(false);
	}).ignoreResult();

	assert(transport.sent.length == 5);
	auto add = dbusClientTestSentMessage(transport, 4);
	assert(add.headers.member.text == "AddMatch");
	assert(add.body.values[0].get!string() == match.canonicalRule);
	transport.receive(dbusClientTestMethodReturn(add.serial, DbusBody.from()));
	assert(!firstReady);
	assert(!secondReady);
	transport.receive(dbusClientTestSignal(":1.7", "", DbusBody.from("before ready")));
	assert(firstCalls == 1);
	assert(secondCalls == 1);
	socketManager.loop();
	assert(firstReady);
	assert(secondReady);

	bool firstUnsubscribed;
	auto firstUnsubscribe = firstSubscription.unsubscribe();
	firstUnsubscribe.then({
		firstUnsubscribed = true;
	}, (Exception) {
		assert(false);
	}).ignoreResult();
	assert(!firstSubscription.active);
	assert(secondSubscription.active);
	assert(transport.sent.length == 5);
	socketManager.loop();
	assert(firstUnsubscribed);
	transport.receive(dbusClientTestSignal(":1.7", "", DbusBody.from("after first removal")));
	assert(firstCalls == 1);
	assert(secondCalls == 2);

	bool secondUnsubscribed;
	auto secondUnsubscribe = secondSubscription.unsubscribe();
	secondUnsubscribe.then({
		secondUnsubscribed = true;
	}, (Exception) {
		assert(false);
	}).ignoreResult();
	assert(!secondSubscription.active);
	assert(transport.sent.length == 6);
	auto remove = dbusClientTestSentMessage(transport, 5);
	assert(remove.headers.member.text == "RemoveMatch");
	assert(remove.body.values[0].get!string() == match.canonicalRule);
	transport.receive(dbusClientTestError(remove.serial,
		"org.freedesktop.DBus.Error.MatchRuleNotFound", "already absent"));
	socketManager.loop();
	assert(secondUnsubscribed);
	assert(client.rules_.length == 0);

	bool caught;
	try
		secondSubscription.unsubscribe();
	catch (AssertError)
		caught = true;
	assert(caught);
}

debug(ae_unittest) unittest
{
	auto match = DbusSignalMatch.signal()
		.withInterface(DbusInterfaceName.parse("org.example.Interface"))
		.withMember(DbusMemberName.parse("Changed"));

	{
		auto script = new DbusClientTestAttemptScript;
		auto client = dbusClientTestConnect(script);
		auto transport = script.transports[0];
		dbusClientTestAuthenticate(transport);
		dbusClientTestReady(transport);
		Exception firstError;
		Exception secondError;
		client.subscribe(match, (const ref DbusSignalMessage signal) {})
			.then((DbusSubscription) {
				assert(false);
			}, (Exception exception) {
				firstError = exception;
			}).ignoreResult();
		client.subscribe(match, (const ref DbusSignalMessage signal) {})
			.then((DbusSubscription) {
				assert(false);
			}, (Exception exception) {
				secondError = exception;
			}).ignoreResult();
		assert(transport.sent.length == 5);
		auto add = dbusClientTestSentMessage(transport, 4);
		transport.receive(dbusClientTestError(add.serial, "org.example.AddFailure", "rejected"));
		socketManager.loop();
		assert(firstError !is null);
		assert(secondError is firstError);
		assert(client.registrations_.length == 0);
		assert(client.rules_.length == 0);
	}

	{
		auto script = new DbusClientTestAttemptScript;
		auto client = dbusClientTestConnect(script);
		auto transport = script.transports[0];
		dbusClientTestAuthenticate(transport);
		dbusClientTestReady(transport);
		DbusSubscription firstSubscription;
		client.subscribe(match, (const ref DbusSignalMessage signal) {})
			.then((DbusSubscription subscription) {
				firstSubscription = subscription;
			}, (Exception) {
				assert(false);
			}).ignoreResult();
		auto firstAdd = dbusClientTestSentMessage(transport, 4);
		transport.receive(dbusClientTestMethodReturn(firstAdd.serial, DbusBody.from()));
		socketManager.loop();
		assert(firstSubscription !is null);

		bool firstRemoved;
		firstSubscription.unsubscribe().then({
			firstRemoved = true;
		}, (Exception) {
			assert(false);
		}).ignoreResult();
		auto firstRemove = dbusClientTestSentMessage(transport, 5);
		DbusSubscription queuedSubscription;
		client.subscribe(match, (const ref DbusSignalMessage signal) {})
			.then((DbusSubscription subscription) {
				queuedSubscription = subscription;
			}, (Exception) {
				assert(false);
			}).ignoreResult();
		assert(transport.sent.length == 6);
		transport.receive(dbusClientTestMethodReturn(firstRemove.serial, DbusBody.from()));
		socketManager.loop();
		assert(firstRemoved);
		assert(transport.sent.length == 7);
		auto secondAdd = dbusClientTestSentMessage(transport, 6);
		assert(secondAdd.headers.member.text == "AddMatch");
		assert(secondAdd.body.values[0].get!string() == match.canonicalRule);
		transport.receive(dbusClientTestMethodReturn(secondAdd.serial, DbusBody.from()));
		socketManager.loop();
		assert(queuedSubscription !is null);
	}

	{
		auto script = new DbusClientTestAttemptScript;
		auto client = dbusClientTestConnect(script);
		auto transport = script.transports[0];
		dbusClientTestAuthenticate(transport);
		dbusClientTestReady(transport);
		DbusSubscription subscription;
		client.subscribe(match, (const ref DbusSignalMessage signal) {})
			.then((DbusSubscription value) {
				subscription = value;
			}, (Exception) {
				assert(false);
			}).ignoreResult();
		auto add = dbusClientTestSentMessage(transport, 4);
		assert(add.headers.member.text == "AddMatch");
		transport.receive(dbusClientTestMethodReturn(add.serial, DbusBody.from()));
		socketManager.loop();
		assert(subscription !is null);

		Exception removalError;
		subscription.unsubscribe().then({
			assert(false);
		}, (Exception exception) {
			removalError = exception;
		}).ignoreResult();
		auto remove = dbusClientTestSentMessage(transport, 5);
		assert(remove.headers.member.text == "RemoveMatch");
		Exception queuedError;
		client.subscribe(match, (const ref DbusSignalMessage signal) {})
			.then((DbusSubscription) {
				assert(false);
			}, (Exception exception) {
				queuedError = exception;
			}).ignoreResult();
		assert(transport.sent.length == 6);
		transport.receive(dbusClientTestError(remove.serial,
			"org.example.RemoveFailure", "ambiguous"));
		socketManager.loop();
		assert(removalError !is null);
		auto remote = cast(DbusRemoteError) removalError;
		assert(remote !is null);
		assert(remote.errorName.text == "org.example.RemoveFailure");
		assert(queuedError is removalError);
		assert(client.rules_.length == 0);
		assert(client.remoteMatches_.length == 1);
		auto tombstone = match.canonicalRule in client.remoteMatches_;
		assert(tombstone !is null);
		assert((*tombstone).phase == DbusRemoteMatchPhase.failedRemoval);
		assert((*tombstone).removalFailure is removalError);
		assert(client.registrations_.length == 0);

		Exception laterError;
		client.subscribe(match, (const ref DbusSignalMessage signal) {})
			.then((DbusSubscription) {
				assert(false);
			}, (Exception exception) {
				laterError = exception;
			}).ignoreResult();
		socketManager.loop();
		assert(laterError is removalError);
		assert(transport.sent.length == 6);

		client.disconnect("clear failed application removal");
		socketManager.loop();
		assert(client.rules_.length == 0);
		assert(client.remoteMatches_.length == 0);
	}
}

debug(ae_unittest) unittest
{
	auto script = new DbusClientTestAttemptScript;
	auto client = dbusClientTestConnect(script);
	auto transport = script.transports[0];
	dbusClientTestAuthenticate(transport);
	dbusClientTestReady(transport);

	auto base = DbusSignalMatch.signal()
		.withPath(DbusObjectPath.parse("/org/example/Object"))
		.withInterface(DbusInterfaceName.parse("org.example.Interface"))
		.withMember(DbusMemberName.parse("Changed"));
	auto unique = base.withSender(DbusBusName.parse(":1.7"));
	auto filtered = base.withDestination(DbusBusName.parse(":1.42"))
		.withArgument(0, "value");
	string[] calls;
	client.subscribe(base, (const ref DbusSignalMessage signal) {
		calls ~= "base";
	}).ignoreResult();
	client.subscribe(unique, (const ref DbusSignalMessage signal) {
		calls ~= "unique";
	}).ignoreResult();
	client.subscribe(filtered, DbusSignature.parse("s"),
		(const ref DbusSignalMessage signal) {
			calls ~= "filtered";
		}).ignoreResult();
	assert(transport.sent.length == 7);
	foreach (index; 4 .. 7)
	{
		auto add = dbusClientTestSentMessage(transport, index);
		assert(add.headers.member.text == "AddMatch");
		transport.receive(dbusClientTestMethodReturn(add.serial, DbusBody.from()));
	}
	socketManager.loop();

	transport.receive(dbusClientTestSignal(":1.7", ":1.42", DbusBody.from("value")));
	assert(calls == ["base", "unique", "filtered"]);
	calls = null;
	transport.receive(dbusClientTestSignal(":1.7", ":1.42", DbusBody.from("wrong")));
	assert(calls == ["base", "unique"]);
	calls = null;
	transport.receive(dbusClientTestSignal(":1.7", ":1.42", DbusBody.from(cast(uint) 7)));
	assert(calls == ["base", "unique"]);
	calls = null;
	transport.receive(dbusClientTestSignal(":1.8", ":1.42", DbusBody.from("value")));
	assert(calls == ["base", "filtered"]);
	calls = null;
	transport.receive(dbusClientTestSignal(":1.7", "", DbusBody.from("value")));
	assert(calls == ["base", "unique"]);
}

debug(ae_unittest) unittest
{
	auto script = new DbusClientTestAttemptScript;
	auto client = dbusClientTestConnect(script);
	auto transport = script.transports[0];
	dbusClientTestAuthenticate(transport);
	dbusClientTestReady(transport);
	auto match = DbusSignalMatch.signal()
		.withInterface(DbusInterfaceName.parse("org.example.Interface"))
		.withMember(DbusMemberName.parse("Reentrant"));
	DbusSubscription firstSubscription;
	DbusSubscription secondSubscription;
	DbusSubscription thirdSubscription;
	string[] calls;
	client.subscribe(match, (const ref DbusSignalMessage signal) {
		calls ~= "first";
		firstSubscription.unsubscribe().ignoreResult();
	}).then((DbusSubscription subscription) {
		firstSubscription = subscription;
	}, (Exception) {
		assert(false);
	}).ignoreResult();
	client.subscribe(match, (const ref DbusSignalMessage signal) {
		calls ~= "second";
		thirdSubscription.unsubscribe().ignoreResult();
	}).then((DbusSubscription subscription) {
		secondSubscription = subscription;
	}, (Exception) {
		assert(false);
	}).ignoreResult();
	client.subscribe(match, (const ref DbusSignalMessage signal) {
		calls ~= "third";
	}).then((DbusSubscription subscription) {
		thirdSubscription = subscription;
	}, (Exception) {
		assert(false);
	}).ignoreResult();
	auto add = dbusClientTestSentMessage(transport, 4);
	transport.receive(dbusClientTestMethodReturn(add.serial, DbusBody.from()));
	socketManager.loop();
	assert(firstSubscription !is null);
	assert(secondSubscription !is null);
	assert(thirdSubscription !is null);
	transport.receive(dbusClientTestSignal(":1.7", "", DbusBody.from(), "Reentrant"));
	assert(calls == ["first", "second"]);
	assert(!firstSubscription.active);
	assert(secondSubscription.active);
	assert(!thirdSubscription.active);
}

debug(ae_unittest) unittest
{
	auto script = new DbusClientTestAttemptScript;
	auto client = dbusClientTestConnect(script);
	auto transport = script.transports[0];
	dbusClientTestAuthenticate(transport);
	dbusClientTestReady(transport);
	auto service = DbusBusName.parse("org.example.Service");
	auto firstMatch = DbusSignalMatch.signal()
		.withSender(service)
		.withPath(DbusObjectPath.parse("/org/example/Object"))
		.withInterface(DbusInterfaceName.parse("org.example.Interface"))
		.withMember(DbusMemberName.parse("Changed"));
	auto secondMatch = firstMatch.withMember(DbusMemberName.parse("Other"));
	size_t firstCalls;
	size_t secondCalls;
	DbusSubscription firstSubscription;
	DbusSubscription secondSubscription;
	client.subscribe(firstMatch, (const ref DbusSignalMessage signal) {
		firstCalls++;
	}).then((DbusSubscription subscription) {
		firstSubscription = subscription;
	}, (Exception) {
		assert(false);
	}).ignoreResult();
	client.subscribe(secondMatch, (const ref DbusSignalMessage signal) {
		secondCalls++;
	}).then((DbusSubscription subscription) {
		secondSubscription = subscription;
	}, (Exception) {
		assert(false);
	}).ignoreResult();

	assert(transport.sent.length == 5);
	auto watchAdd = dbusClientTestSentMessage(transport, 4);
	assert(watchAdd.headers.member.text == "AddMatch");
	auto watchRule = DbusSignalMatch.signal()
		.withSender(DbusBusName.parse("org.freedesktop.DBus"))
		.withInterface(DbusInterfaceName.parse("org.freedesktop.DBus"))
		.withMember(DbusMemberName.parse("NameOwnerChanged"))
		.withPath(DbusObjectPath.parse("/org/freedesktop/DBus"))
		.withArgument(0, service.text).canonicalRule;
	assert(watchAdd.body.values[0].get!string() == watchRule);
	transport.receive(dbusClientTestMethodReturn(watchAdd.serial, DbusBody.from()));
	socketManager.loop();
	assert(transport.sent.length == 6);
	auto seed = dbusClientTestSentMessage(transport, 5);
	assert(seed.headers.member.text == "GetNameOwner");
	assert(seed.body.values[0].get!string() == service.text);

	transport.receive(dbusClientTestOwnerChanged(service.text, "", ":1.99"));
	assert(transport.sent.length == 8);
	auto firstAdd = dbusClientTestSentMessage(transport, 6);
	auto secondAdd = dbusClientTestSentMessage(transport, 7);
	assert(firstAdd.headers.member.text == "AddMatch");
	assert(secondAdd.headers.member.text == "AddMatch");
	transport.receive(dbusClientTestMethodReturn(seed.serial, DbusBody.from(":1.77")));
	socketManager.loop();
	auto watch = client.ownerWatches_[service.text];
	assert(watch.known);
	assert(watch.hasOwner);
	assert(watch.owner.text == ":1.99");
	transport.receive(dbusClientTestMethodReturn(firstAdd.serial, DbusBody.from()));
	transport.receive(dbusClientTestMethodReturn(secondAdd.serial, DbusBody.from()));
	socketManager.loop();
	assert(firstSubscription !is null);
	assert(secondSubscription !is null);

	transport.receive(dbusClientTestSignal(":1.99", "", DbusBody.from()));
	transport.receive(dbusClientTestSignal(":1.99", "", DbusBody.from(), "Other"));
	assert(firstCalls == 1);
	assert(secondCalls == 1);
	transport.receive(dbusClientTestOwnerChanged(service.text, ":1.99", ":1.100"));
	transport.receive(dbusClientTestSignal(":1.99", "", DbusBody.from()));
	transport.receive(dbusClientTestSignal(":1.100", "", DbusBody.from()));
	assert(firstCalls == 2);

	firstSubscription.unsubscribe().ignoreResult();
	auto firstRemove = dbusClientTestSentMessage(transport, 8);
	assert(firstRemove.headers.member.text == "RemoveMatch");
	transport.receive(dbusClientTestMethodReturn(firstRemove.serial, DbusBody.from()));
	socketManager.loop();
	secondSubscription.unsubscribe().ignoreResult();
	auto secondRemove = dbusClientTestSentMessage(transport, 9);
	assert(secondRemove.headers.member.text == "RemoveMatch");
	transport.receive(dbusClientTestMethodReturn(secondRemove.serial, DbusBody.from()));
	socketManager.loop();
	assert(transport.sent.length == 11);
	auto watchRemove = dbusClientTestSentMessage(transport, 10);
	assert(watchRemove.headers.member.text == "RemoveMatch");

	DbusSubscription restartedSubscription;
	client.subscribe(firstMatch, (const ref DbusSignalMessage signal) {
		firstCalls++;
	}).then((DbusSubscription subscription) {
		restartedSubscription = subscription;
	}, (Exception) {
		assert(false);
	}).ignoreResult();
	assert(transport.sent.length == 11);
	transport.receive(dbusClientTestMethodReturn(watchRemove.serial, DbusBody.from()));
	socketManager.loop();
	assert(transport.sent.length == 12);
	auto restartedWatchAdd = dbusClientTestSentMessage(transport, 11);
	assert(restartedWatchAdd.headers.member.text == "AddMatch");
	transport.receive(dbusClientTestMethodReturn(restartedWatchAdd.serial, DbusBody.from()));
	socketManager.loop();
	assert(transport.sent.length == 13);
	auto restartedSeed = dbusClientTestSentMessage(transport, 12);
	assert(restartedSeed.headers.member.text == "GetNameOwner");
	transport.receive(dbusClientTestMethodReturn(restartedSeed.serial, DbusBody.from(":1.100")));
	socketManager.loop();
	assert(transport.sent.length == 14);
	auto restartedAdd = dbusClientTestSentMessage(transport, 13);
	assert(restartedAdd.headers.member.text == "AddMatch");
	transport.receive(dbusClientTestMethodReturn(restartedAdd.serial, DbusBody.from()));
	socketManager.loop();
	assert(restartedSubscription !is null);
}

debug(ae_unittest) unittest
{
	{
		auto script = new DbusClientTestAttemptScript;
		auto client = dbusClientTestConnect(script);
		auto transport = script.transports[0];
		dbusClientTestAuthenticate(transport);
		dbusClientTestReady(transport);
		auto service = DbusBusName.parse("org.example.InternalWatchFirstService");
		auto serviceMatch = DbusSignalMatch.signal()
			.withSender(service)
			.withPath(DbusObjectPath.parse("/org/example/Object"))
			.withInterface(DbusInterfaceName.parse("org.example.Interface"))
			.withMember(DbusMemberName.parse("Changed"));
		auto watchMatch = DbusSignalMatch.signal()
			.withSender(DbusBusName.parse("org.freedesktop.DBus"))
			.withInterface(DbusInterfaceName.parse("org.freedesktop.DBus"))
			.withMember(DbusMemberName.parse("NameOwnerChanged"))
			.withPath(DbusObjectPath.parse("/org/freedesktop/DBus"))
			.withArgument(0, service.text);
		auto watchRule = watchMatch.canonicalRule;
		DbusSubscription serviceSubscription;
		DbusSubscription publicSubscription;
		client.subscribe(serviceMatch, (const ref DbusSignalMessage signal) {})
			.then((DbusSubscription value) {
				serviceSubscription = value;
			}, (Exception) {
				assert(false);
			}).ignoreResult();
		auto watchAdd = dbusClientTestSentMessage(transport, 4);
		assert(watchAdd.headers.member.text == "AddMatch");
		assert(watchAdd.body.values[0].get!string() == watchRule);

		client.subscribe(watchMatch, (const ref DbusSignalMessage signal) {})
			.then((DbusSubscription value) {
				publicSubscription = value;
			}, (Exception) {
				assert(false);
			}).ignoreResult();
		assert(transport.sent.length == 5);
		assert(dbusClientTestMatchCallCount(transport, "AddMatch", watchRule) == 1);
		transport.receive(dbusClientTestMethodReturn(watchAdd.serial, DbusBody.from()));
		socketManager.loop();
		assert(publicSubscription !is null);
		assert(transport.sent.length == 6);
		auto seed = dbusClientTestSentMessage(transport, 5);
		assert(seed.headers.member.text == "GetNameOwner");
		transport.receive(dbusClientTestMethodReturn(seed.serial, DbusBody.from(":1.201")));
		socketManager.loop();
		assert(transport.sent.length == 7);
		auto serviceAdd = dbusClientTestSentMessage(transport, 6);
		assert(serviceAdd.headers.member.text == "AddMatch");
		assert(serviceAdd.body.values[0].get!string() == serviceMatch.canonicalRule);
		assert(dbusClientTestMatchCallCount(transport, "AddMatch", watchRule) == 1);
		transport.receive(dbusClientTestMethodReturn(serviceAdd.serial, DbusBody.from()));
		socketManager.loop();
		assert(serviceSubscription !is null);

		bool publicUnsubscribed;
		publicSubscription.unsubscribe().then({
			publicUnsubscribed = true;
		}, (Exception) {
			assert(false);
		}).ignoreResult();
		assert(transport.sent.length == 7);
		assert(dbusClientTestMatchCallCount(transport, "RemoveMatch", watchRule) == 0);
		socketManager.loop();
		assert(publicUnsubscribed);

		bool serviceUnsubscribed;
		serviceSubscription.unsubscribe().then({
			serviceUnsubscribed = true;
		}, (Exception) {
			assert(false);
		}).ignoreResult();
		assert(dbusClientTestMatchCallCount(transport, "RemoveMatch",
			serviceMatch.canonicalRule) == 1);
		auto serviceRemove = dbusClientTestSentMessage(transport,
			dbusClientTestMatchCallIndex(transport, "RemoveMatch", serviceMatch.canonicalRule));
		transport.receive(dbusClientTestMethodReturn(serviceRemove.serial, DbusBody.from()));
		socketManager.loop();
		assert(serviceUnsubscribed);
		assert(dbusClientTestMatchCallCount(transport, "RemoveMatch", watchRule) == 1);
		auto watchRemove = dbusClientTestSentMessage(transport,
			dbusClientTestMatchCallIndex(transport, "RemoveMatch", watchRule));
		transport.receive(dbusClientTestMethodReturn(watchRemove.serial, DbusBody.from()));
		socketManager.loop();
		assert(client.remoteMatches_.length == 0);
	}

	{
		auto script = new DbusClientTestAttemptScript;
		auto client = dbusClientTestConnect(script);
		auto transport = script.transports[0];
		dbusClientTestAuthenticate(transport);
		dbusClientTestReady(transport);
		auto service = DbusBusName.parse("org.example.PublicWatchFirstService");
		auto serviceMatch = DbusSignalMatch.signal()
			.withSender(service)
			.withPath(DbusObjectPath.parse("/org/example/Object"))
			.withInterface(DbusInterfaceName.parse("org.example.Interface"))
			.withMember(DbusMemberName.parse("Changed"));
		auto watchMatch = DbusSignalMatch.signal()
			.withSender(DbusBusName.parse("org.freedesktop.DBus"))
			.withInterface(DbusInterfaceName.parse("org.freedesktop.DBus"))
			.withMember(DbusMemberName.parse("NameOwnerChanged"))
			.withPath(DbusObjectPath.parse("/org/freedesktop/DBus"))
			.withArgument(0, service.text);
		auto watchRule = watchMatch.canonicalRule;
		DbusSubscription serviceSubscription;
		DbusSubscription publicSubscription;
		client.subscribe(watchMatch, (const ref DbusSignalMessage signal) {})
			.then((DbusSubscription value) {
				publicSubscription = value;
			}, (Exception) {
				assert(false);
			}).ignoreResult();
		auto watchAdd = dbusClientTestSentMessage(transport, 4);
		assert(watchAdd.headers.member.text == "AddMatch");
		assert(watchAdd.body.values[0].get!string() == watchRule);

		client.subscribe(serviceMatch, (const ref DbusSignalMessage signal) {})
			.then((DbusSubscription value) {
				serviceSubscription = value;
			}, (Exception) {
				assert(false);
			}).ignoreResult();
		assert(transport.sent.length == 5);
		assert(dbusClientTestMatchCallCount(transport, "AddMatch", watchRule) == 1);
		transport.receive(dbusClientTestMethodReturn(watchAdd.serial, DbusBody.from()));
		socketManager.loop();
		assert(publicSubscription !is null);
		assert(transport.sent.length == 6);
		auto seed = dbusClientTestSentMessage(transport, 5);
		assert(seed.headers.member.text == "GetNameOwner");
		transport.receive(dbusClientTestMethodReturn(seed.serial, DbusBody.from(":1.202")));
		socketManager.loop();
		assert(transport.sent.length == 7);
		auto serviceAdd = dbusClientTestSentMessage(transport, 6);
		assert(serviceAdd.headers.member.text == "AddMatch");
		assert(serviceAdd.body.values[0].get!string() == serviceMatch.canonicalRule);
		assert(dbusClientTestMatchCallCount(transport, "AddMatch", watchRule) == 1);
		transport.receive(dbusClientTestMethodReturn(serviceAdd.serial, DbusBody.from()));
		socketManager.loop();
		assert(serviceSubscription !is null);

		bool serviceUnsubscribed;
		serviceSubscription.unsubscribe().then({
			serviceUnsubscribed = true;
		}, (Exception) {
			assert(false);
		}).ignoreResult();
		assert(dbusClientTestMatchCallCount(transport, "RemoveMatch", watchRule) == 0);
		assert(dbusClientTestMatchCallCount(transport, "RemoveMatch",
			serviceMatch.canonicalRule) == 1);
		auto serviceRemove = dbusClientTestSentMessage(transport,
			dbusClientTestMatchCallIndex(transport, "RemoveMatch", serviceMatch.canonicalRule));
		transport.receive(dbusClientTestMethodReturn(serviceRemove.serial, DbusBody.from()));
		socketManager.loop();
		assert(serviceUnsubscribed);
		assert(dbusClientTestMatchCallCount(transport, "RemoveMatch", watchRule) == 0);

		bool publicUnsubscribed;
		publicSubscription.unsubscribe().then({
			publicUnsubscribed = true;
		}, (Exception) {
			assert(false);
		}).ignoreResult();
		assert(dbusClientTestMatchCallCount(transport, "RemoveMatch", watchRule) == 1);
		auto watchRemove = dbusClientTestSentMessage(transport,
			dbusClientTestMatchCallIndex(transport, "RemoveMatch", watchRule));
		transport.receive(dbusClientTestMethodReturn(watchRemove.serial, DbusBody.from()));
		socketManager.loop();
		assert(publicUnsubscribed);
		assert(client.remoteMatches_.length == 0);
	}
}

debug(ae_unittest) unittest
{
	auto script = new DbusClientTestAttemptScript;
	auto client = dbusClientTestConnect(script);
	auto transport = script.transports[0];
	dbusClientTestAuthenticate(transport);
	dbusClientTestReady(transport);
	auto service = DbusBusName.parse("org.example.FailedWatchRemovalService");
	auto match = DbusSignalMatch.signal()
		.withSender(service)
		.withPath(DbusObjectPath.parse("/org/example/Object"))
		.withInterface(DbusInterfaceName.parse("org.example.Interface"))
		.withMember(DbusMemberName.parse("Changed"));
	auto queuedMatch = match.withMember(DbusMemberName.parse("Queued"));
	auto laterMatch = match.withMember(DbusMemberName.parse("Later"));
	DbusSubscription subscription;
	client.subscribe(match, (const ref DbusSignalMessage signal) {})
		.then((DbusSubscription value) {
			subscription = value;
		}, (Exception) {
			assert(false);
		}).ignoreResult();
	auto watchAdd = dbusClientTestSentMessage(transport, 4);
	assert(watchAdd.headers.member.text == "AddMatch");
	transport.receive(dbusClientTestMethodReturn(watchAdd.serial, DbusBody.from()));
	socketManager.loop();
	auto seed = dbusClientTestSentMessage(transport, 5);
	assert(seed.headers.member.text == "GetNameOwner");
	transport.receive(dbusClientTestMethodReturn(seed.serial, DbusBody.from(":1.130")));
	socketManager.loop();
	auto add = dbusClientTestSentMessage(transport, 6);
	assert(add.headers.member.text == "AddMatch");
	transport.receive(dbusClientTestMethodReturn(add.serial, DbusBody.from()));
	socketManager.loop();
	assert(subscription !is null);

	bool unsubscribed;
	subscription.unsubscribe().then({
		unsubscribed = true;
	}, (Exception) {
		assert(false);
	}).ignoreResult();
	auto remove = dbusClientTestSentMessage(transport, 7);
	assert(remove.headers.member.text == "RemoveMatch");
	transport.receive(dbusClientTestMethodReturn(remove.serial, DbusBody.from()));
	socketManager.loop();
	assert(unsubscribed);
	assert(transport.sent.length == 9);
	auto watchRemove = dbusClientTestSentMessage(transport, 8);
	assert(watchRemove.headers.member.text == "RemoveMatch");

	Exception queuedError;
	client.subscribe(queuedMatch, (const ref DbusSignalMessage signal) {})
		.then((DbusSubscription) {
			assert(false);
		}, (Exception exception) {
			queuedError = exception;
		}).ignoreResult();
	assert(transport.sent.length == 9);
	transport.receive(dbusClientTestError(watchRemove.serial,
		"org.example.WatchRemovalFailure", "ambiguous"));
	socketManager.loop();
	assert(queuedError !is null);
	auto remote = cast(DbusRemoteError) queuedError;
	assert(remote !is null);
	assert(remote.errorName.text == "org.example.WatchRemovalFailure");

	Exception sameError;
	Exception laterError;
	client.subscribe(queuedMatch, (const ref DbusSignalMessage signal) {})
		.then((DbusSubscription) {
			assert(false);
		}, (Exception exception) {
			sameError = exception;
		}).ignoreResult();
	client.subscribe(laterMatch, (const ref DbusSignalMessage signal) {})
		.then((DbusSubscription) {
			assert(false);
		}, (Exception exception) {
			laterError = exception;
		}).ignoreResult();
	socketManager.loop();
	assert(sameError is queuedError);
	assert(laterError is queuedError);
	assert(transport.sent.length == 9);

	client.disconnect("clear failed owner-watch removal");
	socketManager.loop();
	assert(client.ownerWatches_.length == 0);
	assert(client.remoteMatches_.length == 0);
}

debug(ae_unittest) unittest
{
	auto script = new DbusClientTestAttemptScript;
	auto client = dbusClientTestConnect(script);
	auto transport = script.transports[0];
	dbusClientTestAuthenticate(transport);
	dbusClientTestReady(transport);
	auto service = DbusBusName.parse("org.example.WatchTombstonePublicService");
	auto serviceMatch = DbusSignalMatch.signal()
		.withSender(service)
		.withPath(DbusObjectPath.parse("/org/example/Object"))
		.withInterface(DbusInterfaceName.parse("org.example.Interface"))
		.withMember(DbusMemberName.parse("Changed"));
	auto watchMatch = DbusSignalMatch.signal()
		.withSender(DbusBusName.parse("org.freedesktop.DBus"))
		.withInterface(DbusInterfaceName.parse("org.freedesktop.DBus"))
		.withMember(DbusMemberName.parse("NameOwnerChanged"))
		.withPath(DbusObjectPath.parse("/org/freedesktop/DBus"))
		.withArgument(0, service.text);
	auto watchRule = watchMatch.canonicalRule;
	DbusSubscription serviceSubscription;
	client.subscribe(serviceMatch, (const ref DbusSignalMessage signal) {})
		.then((DbusSubscription value) {
			serviceSubscription = value;
		}, (Exception) {
			assert(false);
		}).ignoreResult();
	auto watchAdd = dbusClientTestSentMessage(transport, 4);
	assert(watchAdd.headers.member.text == "AddMatch");
	assert(watchAdd.body.values[0].get!string() == watchRule);
	transport.receive(dbusClientTestMethodReturn(watchAdd.serial, DbusBody.from()));
	socketManager.loop();
	auto seed = dbusClientTestSentMessage(transport, 5);
	assert(seed.headers.member.text == "GetNameOwner");
	transport.receive(dbusClientTestMethodReturn(seed.serial, DbusBody.from(":1.203")));
	socketManager.loop();
	auto serviceAdd = dbusClientTestSentMessage(transport, 6);
	assert(serviceAdd.headers.member.text == "AddMatch");
	assert(serviceAdd.body.values[0].get!string() == serviceMatch.canonicalRule);
	transport.receive(dbusClientTestMethodReturn(serviceAdd.serial, DbusBody.from()));
	socketManager.loop();
	assert(serviceSubscription !is null);

	bool serviceUnsubscribed;
	serviceSubscription.unsubscribe().then({
		serviceUnsubscribed = true;
	}, (Exception) {
		assert(false);
	}).ignoreResult();
	assert(dbusClientTestMatchCallCount(transport, "RemoveMatch",
		serviceMatch.canonicalRule) == 1);
	auto serviceRemove = dbusClientTestSentMessage(transport,
		dbusClientTestMatchCallIndex(transport, "RemoveMatch", serviceMatch.canonicalRule));
	transport.receive(dbusClientTestMethodReturn(serviceRemove.serial, DbusBody.from()));
	socketManager.loop();
	assert(serviceUnsubscribed);
	assert(dbusClientTestMatchCallCount(transport, "RemoveMatch", watchRule) == 1);
	auto watchRemove = dbusClientTestSentMessage(transport,
		dbusClientTestMatchCallIndex(transport, "RemoveMatch", watchRule));
	transport.receive(dbusClientTestError(watchRemove.serial,
		"org.example.WatchRemovalFailure", "ambiguous"));
	socketManager.loop();
	auto remote = watchRule in client.remoteMatches_;
	assert(remote !is null);
	assert((*remote).phase == DbusRemoteMatchPhase.failedRemoval);
	auto watchRemovalFailure = (*remote).removalFailure;
	auto remoteError = cast(DbusRemoteError) watchRemovalFailure;
	assert(remoteError !is null);
	assert(remoteError.errorName.text == "org.example.WatchRemovalFailure");

	Exception publicError;
	auto sentCount = transport.sent.length;
	client.subscribe(watchMatch, (const ref DbusSignalMessage signal) {})
		.then((DbusSubscription) {
			assert(false);
		}, (Exception exception) {
			publicError = exception;
		}).ignoreResult();
	socketManager.loop();
	assert(publicError is watchRemovalFailure);
	assert(transport.sent.length == sentCount);

	client.disconnect("clear failed owner-watch removal");
	socketManager.loop();
	assert(client.rules_.length == 0);
	assert(client.ownerWatches_.length == 0);
	assert(client.remoteMatches_.length == 0);
}

debug(ae_unittest) unittest
{
	auto script = new DbusClientTestAttemptScript;
	auto client = dbusClientTestConnect(script);
	auto transport = script.transports[0];
	dbusClientTestAuthenticate(transport);
	dbusClientTestReady(transport);
	auto service = DbusBusName.parse("org.example.PublicTombstoneWatchService");
	auto serviceMatch = DbusSignalMatch.signal()
		.withSender(service)
		.withPath(DbusObjectPath.parse("/org/example/Object"))
		.withInterface(DbusInterfaceName.parse("org.example.Interface"))
		.withMember(DbusMemberName.parse("Changed"));
	auto watchMatch = DbusSignalMatch.signal()
		.withSender(DbusBusName.parse("org.freedesktop.DBus"))
		.withInterface(DbusInterfaceName.parse("org.freedesktop.DBus"))
		.withMember(DbusMemberName.parse("NameOwnerChanged"))
		.withPath(DbusObjectPath.parse("/org/freedesktop/DBus"))
		.withArgument(0, service.text);
	auto watchRule = watchMatch.canonicalRule;
	DbusSubscription publicSubscription;
	client.subscribe(watchMatch, (const ref DbusSignalMessage signal) {})
		.then((DbusSubscription value) {
			publicSubscription = value;
		}, (Exception) {
			assert(false);
		}).ignoreResult();
	auto watchAdd = dbusClientTestSentMessage(transport, 4);
	assert(watchAdd.headers.member.text == "AddMatch");
	assert(watchAdd.body.values[0].get!string() == watchRule);
	transport.receive(dbusClientTestMethodReturn(watchAdd.serial, DbusBody.from()));
	socketManager.loop();
	assert(publicSubscription !is null);

	Exception watchRemovalFailure;
	publicSubscription.unsubscribe().then({
		assert(false);
	}, (Exception exception) {
		watchRemovalFailure = exception;
	}).ignoreResult();
	assert(transport.sent.length == 6);
	auto watchRemove = dbusClientTestSentMessage(transport, 5);
	assert(watchRemove.headers.member.text == "RemoveMatch");
	assert(watchRemove.body.values[0].get!string() == watchRule);
	transport.receive(dbusClientTestError(watchRemove.serial,
		"org.example.PublicWatchRemovalFailure", "ambiguous"));
	socketManager.loop();
	assert(watchRemovalFailure !is null);
	auto remoteError = cast(DbusRemoteError) watchRemovalFailure;
	assert(remoteError !is null);
	assert(remoteError.errorName.text == "org.example.PublicWatchRemovalFailure");

	Exception serviceError;
	client.subscribe(serviceMatch, (const ref DbusSignalMessage signal) {})
		.then((DbusSubscription) {
			assert(false);
		}, (Exception exception) {
			serviceError = exception;
		}).ignoreResult();
	socketManager.loop();
	assert(serviceError is watchRemovalFailure);
	assert(transport.sent.length == 6);
}

// A subscription with sender='org.freedesktop.DBus' takes the exact-equality
// bus-driver sender path in matchesRule directly, without an OwnerWatch, so
// a signal actually sent by the bus driver must reach its handler.
debug(ae_unittest) unittest
{
	auto script = new DbusClientTestAttemptScript;
	auto client = dbusClientTestConnect(script);
	auto transport = script.transports[0];
	dbusClientTestAuthenticate(transport);
	dbusClientTestReady(transport);

	auto match = DbusSignalMatch.signal()
		.withSender(DbusBusName.parse("org.freedesktop.DBus"))
		.withInterface(DbusInterfaceName.parse("org.freedesktop.DBus"))
		.withMember(DbusMemberName.parse("NameOwnerChanged"));
	size_t calls;
	DbusSubscription subscription;
	client.subscribe(match, (const ref DbusSignalMessage signal) {
		assert(signal.sender.text == "org.freedesktop.DBus");
		calls++;
	}).then((DbusSubscription value) {
		subscription = value;
	}, (Exception) {
		assert(false);
	}).ignoreResult();

	assert(transport.sent.length == 5);
	auto add = dbusClientTestSentMessage(transport, 4);
	assert(add.headers.member.text == "AddMatch");
	assert(client.ownerWatches_.length == 0);
	transport.receive(dbusClientTestMethodReturn(add.serial, DbusBody.from()));
	socketManager.loop();
	assert(subscription !is null);
	assert(client.ownerWatches_.length == 0);

	transport.receive(dbusClientTestOwnerChanged("org.example.SomeService", "", ":1.55"));
	assert(calls == 1);
}

debug(ae_unittest) unittest
{
	auto script = new DbusClientTestAttemptScript;
	auto client = dbusClientTestConnect(script);
	auto transport = script.transports[0];
	dbusClientTestAuthenticate(transport);
	dbusClientTestReady(transport);
	auto service = DbusBusName.parse("org.example.AbsentService");
	auto match = DbusSignalMatch.signal()
		.withSender(service)
		.withPath(DbusObjectPath.parse("/org/example/Object"))
		.withInterface(DbusInterfaceName.parse("org.example.Interface"))
		.withMember(DbusMemberName.parse("Changed"));
	size_t calls;
	client.subscribe(match, (const ref DbusSignalMessage signal) {
		calls++;
	}).ignoreResult();
	auto watchAdd = dbusClientTestSentMessage(transport, 4);
	transport.receive(dbusClientTestMethodReturn(watchAdd.serial, DbusBody.from()));
	socketManager.loop();
	auto seed = dbusClientTestSentMessage(transport, 5);
	transport.receive(dbusClientTestError(seed.serial,
		"org.freedesktop.DBus.Error.NameHasNoOwner", "absent"));
	socketManager.loop();
	auto appAdd = dbusClientTestSentMessage(transport, 6);
	transport.receive(dbusClientTestMethodReturn(appAdd.serial, DbusBody.from()));
	socketManager.loop();
	transport.receive(dbusClientTestSignal(":1.101", "", DbusBody.from()));
	assert(calls == 0);
	transport.receive(dbusClientTestOwnerChanged(service.text, "", ":1.101"));
	transport.receive(dbusClientTestSignal(":1.101", "", DbusBody.from()));
	assert(calls == 1);
}

debug(ae_unittest) unittest
{
	auto script = new DbusClientTestAttemptScript;
	auto client = dbusClientTestConnect(script);
	auto transport = script.transports[0];
	dbusClientTestAuthenticate(transport);
	dbusClientTestReady(transport);
	auto service = DbusBusName.parse("org.example.SeedRemoteFailureService");
	auto firstMatch = DbusSignalMatch.signal()
		.withSender(service)
		.withPath(DbusObjectPath.parse("/org/example/Object"))
		.withInterface(DbusInterfaceName.parse("org.example.Interface"))
		.withMember(DbusMemberName.parse("Changed"));
	auto secondMatch = firstMatch.withMember(DbusMemberName.parse("Other"));
	Exception firstError;
	Exception secondError;
	client.subscribe(firstMatch, (const ref DbusSignalMessage signal) {})
		.then((DbusSubscription) {
			assert(false);
		}, (Exception exception) {
			firstError = exception;
		}).ignoreResult();
	client.subscribe(secondMatch, (const ref DbusSignalMessage signal) {})
		.then((DbusSubscription) {
			assert(false);
		}, (Exception exception) {
			secondError = exception;
		}).ignoreResult();
	auto watchAdd = dbusClientTestSentMessage(transport, 4);
	assert(watchAdd.headers.member.text == "AddMatch");
	transport.receive(dbusClientTestMethodReturn(watchAdd.serial, DbusBody.from()));
	socketManager.loop();
	auto seed = dbusClientTestSentMessage(transport, 5);
	assert(seed.headers.member.text == "GetNameOwner");
	transport.receive(dbusClientTestError(seed.serial,
		"org.example.GetNameOwnerFailure", "rejected"));
	socketManager.loop();
	assert(firstError !is null);
	auto remote = cast(DbusRemoteError) firstError;
	assert(remote !is null);
	assert(remote.errorName.text == "org.example.GetNameOwnerFailure");
	assert(secondError is firstError);
	assert(transport.sent.length == 7);
	auto watchRemove = dbusClientTestSentMessage(transport, 6);
	assert(watchRemove.headers.member.text == "RemoveMatch");
	assert(watchRemove.body.values[0].get!string() ==
		watchAdd.body.values[0].get!string());

	DbusSubscription retrySubscription;
	client.subscribe(firstMatch, (const ref DbusSignalMessage signal) {})
		.then((DbusSubscription value) {
			retrySubscription = value;
		}, (Exception) {
			assert(false);
		}).ignoreResult();
	assert(transport.sent.length == 7);
	transport.receive(dbusClientTestError(watchRemove.serial,
		"org.freedesktop.DBus.Error.MatchRuleNotFound", "already absent"));
	socketManager.loop();
	assert(transport.sent.length == 8);
	auto retryWatchAdd = dbusClientTestSentMessage(transport, 7);
	assert(retryWatchAdd.headers.member.text == "AddMatch");
	assert(retryWatchAdd.body.values[0].get!string() ==
		watchAdd.body.values[0].get!string());
	transport.receive(dbusClientTestMethodReturn(retryWatchAdd.serial, DbusBody.from()));
	socketManager.loop();
	assert(transport.sent.length == 9);
	auto retrySeed = dbusClientTestSentMessage(transport, 8);
	assert(retrySeed.headers.member.text == "GetNameOwner");
	transport.receive(dbusClientTestMethodReturn(retrySeed.serial, DbusBody.from(":1.131")));
	socketManager.loop();
	assert(transport.sent.length == 10);
	auto retryAdd = dbusClientTestSentMessage(transport, 9);
	assert(retryAdd.headers.member.text == "AddMatch");
	assert(retryAdd.body.values[0].get!string() == firstMatch.canonicalRule);
	transport.receive(dbusClientTestMethodReturn(retryAdd.serial, DbusBody.from()));
	socketManager.loop();
	assert(retrySubscription !is null);
}

debug(ae_unittest) unittest
{
	auto script = new DbusClientTestAttemptScript;
	auto client = dbusClientTestConnect(script);
	auto transport = script.transports[0];
	dbusClientTestAuthenticate(transport);
	dbusClientTestReady(transport);
	auto service = DbusBusName.parse("org.example.SeedMalformedFailureService");
	auto firstMatch = DbusSignalMatch.signal()
		.withSender(service)
		.withPath(DbusObjectPath.parse("/org/example/Object"))
		.withInterface(DbusInterfaceName.parse("org.example.Interface"))
		.withMember(DbusMemberName.parse("Changed"));
	auto secondMatch = firstMatch.withMember(DbusMemberName.parse("Other"));
	Exception firstError;
	Exception secondError;
	client.subscribe(firstMatch, (const ref DbusSignalMessage signal) {})
		.then((DbusSubscription) {
			assert(false);
		}, (Exception exception) {
			firstError = exception;
		}).ignoreResult();
	client.subscribe(secondMatch, (const ref DbusSignalMessage signal) {})
		.then((DbusSubscription) {
			assert(false);
		}, (Exception exception) {
			secondError = exception;
		}).ignoreResult();
	auto watchAdd = dbusClientTestSentMessage(transport, 4);
	assert(watchAdd.headers.member.text == "AddMatch");
	transport.receive(dbusClientTestMethodReturn(watchAdd.serial, DbusBody.from()));
	socketManager.loop();
	auto seed = dbusClientTestSentMessage(transport, 5);
	assert(seed.headers.member.text == "GetNameOwner");
	transport.receive(dbusClientTestMethodReturn(seed.serial,
		DbusBody.from(cast(uint) 1)));
	socketManager.loop();
	assert(firstError !is null);
	assert(cast(DbusTypeMismatchException) firstError !is null);
	assert(secondError is firstError);
	assert(transport.sent.length == 7);
	auto watchRemove = dbusClientTestSentMessage(transport, 6);
	assert(watchRemove.headers.member.text == "RemoveMatch");
	assert(watchRemove.body.values[0].get!string() ==
		watchAdd.body.values[0].get!string());

	DbusSubscription retrySubscription;
	client.subscribe(firstMatch, (const ref DbusSignalMessage signal) {})
		.then((DbusSubscription value) {
			retrySubscription = value;
		}, (Exception) {
			assert(false);
		}).ignoreResult();
	assert(transport.sent.length == 7);
	transport.receive(dbusClientTestMethodReturn(watchRemove.serial, DbusBody.from()));
	socketManager.loop();
	assert(transport.sent.length == 8);
	auto retryWatchAdd = dbusClientTestSentMessage(transport, 7);
	assert(retryWatchAdd.headers.member.text == "AddMatch");
	assert(retryWatchAdd.body.values[0].get!string() ==
		watchAdd.body.values[0].get!string());
	transport.receive(dbusClientTestMethodReturn(retryWatchAdd.serial, DbusBody.from()));
	socketManager.loop();
	assert(transport.sent.length == 9);
	auto retrySeed = dbusClientTestSentMessage(transport, 8);
	assert(retrySeed.headers.member.text == "GetNameOwner");
	transport.receive(dbusClientTestMethodReturn(retrySeed.serial, DbusBody.from(":1.132")));
	socketManager.loop();
	assert(transport.sent.length == 10);
	auto retryAdd = dbusClientTestSentMessage(transport, 9);
	assert(retryAdd.headers.member.text == "AddMatch");
	assert(retryAdd.body.values[0].get!string() == firstMatch.canonicalRule);
	transport.receive(dbusClientTestMethodReturn(retryAdd.serial, DbusBody.from()));
	socketManager.loop();
	assert(retrySubscription !is null);
}

debug(ae_unittest) unittest
{
	auto script = new DbusClientTestAttemptScript;
	auto client = dbusClientTestConnect(script);
	auto transport = script.transports[0];
	dbusClientTestAuthenticate(transport);
	dbusClientTestReady(transport);
	auto service = DbusBusName.parse("org.example.SeedCleanupFailureService");
	auto firstMatch = DbusSignalMatch.signal()
		.withSender(service)
		.withPath(DbusObjectPath.parse("/org/example/Object"))
		.withInterface(DbusInterfaceName.parse("org.example.Interface"))
		.withMember(DbusMemberName.parse("Changed"));
	auto queuedMatch = firstMatch.withMember(DbusMemberName.parse("Queued"));
	auto laterMatch = firstMatch.withMember(DbusMemberName.parse("Later"));
	Exception seedError;
	client.subscribe(firstMatch, (const ref DbusSignalMessage signal) {})
		.then((DbusSubscription) {
			assert(false);
		}, (Exception exception) {
			seedError = exception;
		}).ignoreResult();
	auto watchAdd = dbusClientTestSentMessage(transport, 4);
	assert(watchAdd.headers.member.text == "AddMatch");
	transport.receive(dbusClientTestMethodReturn(watchAdd.serial, DbusBody.from()));
	socketManager.loop();
	auto seed = dbusClientTestSentMessage(transport, 5);
	assert(seed.headers.member.text == "GetNameOwner");
	transport.receive(dbusClientTestError(seed.serial,
		"org.example.GetNameOwnerFailure", "rejected"));
	socketManager.loop();
	assert(seedError !is null);
	assert(transport.sent.length == 7);
	auto watchRemove = dbusClientTestSentMessage(transport, 6);
	assert(watchRemove.headers.member.text == "RemoveMatch");

	Exception queuedError;
	client.subscribe(queuedMatch, (const ref DbusSignalMessage signal) {})
		.then((DbusSubscription) {
			assert(false);
		}, (Exception exception) {
			queuedError = exception;
		}).ignoreResult();
	assert(transport.sent.length == 7);
	transport.receive(dbusClientTestError(watchRemove.serial,
		"org.example.CleanupRemoveFailure", "ambiguous"));
	socketManager.loop();
	assert(queuedError !is null);
	assert(queuedError !is seedError);
	auto remote = cast(DbusRemoteError) queuedError;
	assert(remote !is null);
	assert(remote.errorName.text == "org.example.CleanupRemoveFailure");

	Exception laterError;
	client.subscribe(laterMatch, (const ref DbusSignalMessage signal) {})
		.then((DbusSubscription) {
			assert(false);
		}, (Exception exception) {
			laterError = exception;
		}).ignoreResult();
	socketManager.loop();
	assert(laterError is queuedError);
	assert(transport.sent.length == 7);
}

debug(ae_unittest) unittest
{
	auto match = DbusSignalMatch.signal()
		.withInterface(DbusInterfaceName.parse("org.example.Interface"))
		.withMember(DbusMemberName.parse("Changed"));

	{
		auto script = new DbusClientTestAttemptScript;
		auto client = dbusClientTestConnect(script);
		auto transport = script.transports[0];
		dbusClientTestAuthenticate(transport);
		dbusClientTestReady(transport);
		Exception subscribeError;
		client.subscribe(match, (const ref DbusSignalMessage signal) {})
			.then((DbusSubscription) {
				assert(false);
			}, (Exception exception) {
				subscribeError = exception;
			}).ignoreResult();
		assert(transport.sent.length == 5);
		client.disconnect("terminal during application add");
		socketManager.loop();
		assert(subscribeError is client.terminalCause_);
		assert(client.registrations_.length == 0);
		assert(client.rules_.length == 0);
		assert(client.ownerWatches_.length == 0);
		assert(client.remoteMatches_.length == 0);
		assert(transport.sent.length == 5);
	}

	{
		auto script = new DbusClientTestAttemptScript;
		auto client = dbusClientTestConnect(script);
		auto transport = script.transports[0];
		dbusClientTestAuthenticate(transport);
		dbusClientTestReady(transport);
		DbusSubscription subscription;
		client.subscribe(match, (const ref DbusSignalMessage signal) {})
			.then((DbusSubscription value) {
				subscription = value;
			}, (Exception) {
				assert(false);
			}).ignoreResult();
		auto add = dbusClientTestSentMessage(transport, 4);
		transport.receive(dbusClientTestMethodReturn(add.serial, DbusBody.from()));
		socketManager.loop();
		Exception removalError;
		subscription.unsubscribe().then({
			assert(false);
		}, (Exception exception) {
			removalError = exception;
		}).ignoreResult();
		assert(transport.sent.length == 6);
		client.disconnect("terminal during application removal");
		socketManager.loop();
		assert(!subscription.active);
		assert(removalError is client.terminalCause_);
		assert(client.registrations_.length == 0);
		assert(client.rules_.length == 0);
		assert(client.remoteMatches_.length == 0);
		assert(transport.sent.length == 6);
	}

	{
		auto script = new DbusClientTestAttemptScript;
		auto client = dbusClientTestConnect(script);
		auto transport = script.transports[0];
		dbusClientTestAuthenticate(transport);
		dbusClientTestReady(transport);
		auto serviceMatch = match.withSender(DbusBusName.parse("org.example.TerminalService"));
		Exception subscribeError;
		client.subscribe(serviceMatch, (const ref DbusSignalMessage signal) {})
			.then((DbusSubscription) {
				assert(false);
			}, (Exception exception) {
				subscribeError = exception;
			}).ignoreResult();
		auto watchAdd = dbusClientTestSentMessage(transport, 4);
		transport.receive(dbusClientTestMethodReturn(watchAdd.serial, DbusBody.from()));
		socketManager.loop();
		assert(transport.sent.length == 6);
		assert(dbusClientTestSentMessage(transport, 5).headers.member.text == "GetNameOwner");
		client.disconnect("terminal during owner seed");
		socketManager.loop();
		assert(subscribeError is client.terminalCause_);
		assert(client.registrations_.length == 0);
		assert(client.rules_.length == 0);
		assert(client.ownerWatches_.length == 0);
		assert(client.remoteMatches_.length == 0);
		assert(transport.sent.length == 6);
	}

	{
		auto script = new DbusClientTestAttemptScript;
		auto client = dbusClientTestConnect(script);
		auto transport = script.transports[0];
		dbusClientTestAuthenticate(transport);
		dbusClientTestReady(transport);
		DbusSubscription firstSubscription;
		client.subscribe(match, (const ref DbusSignalMessage signal) {})
			.then((DbusSubscription value) {
				firstSubscription = value;
			}, (Exception) {
				assert(false);
			}).ignoreResult();
		auto firstAdd = dbusClientTestSentMessage(transport, 4);
		transport.receive(dbusClientTestMethodReturn(firstAdd.serial, DbusBody.from()));
		socketManager.loop();
		firstSubscription.unsubscribe().ignoreResult();
		auto remove = dbusClientTestSentMessage(transport, 5);
		Exception readdError;
		client.subscribe(match, (const ref DbusSignalMessage signal) {})
			.then((DbusSubscription) {
				assert(false);
			}, (Exception exception) {
				readdError = exception;
			}).ignoreResult();
		transport.receive(dbusClientTestMethodReturn(remove.serial, DbusBody.from()));
		socketManager.loop();
		assert(transport.sent.length == 7);
		assert(dbusClientTestSentMessage(transport, 6).headers.member.text == "AddMatch");
		client.disconnect("terminal during re-add");
		socketManager.loop();
		assert(readdError is client.terminalCause_);
		assert(client.registrations_.length == 0);
		assert(client.rules_.length == 0);
		assert(client.remoteMatches_.length == 0);
	}
}

// A signal that arrives in the same read batch as the reply to a re-add
// AddMatch (queued while a RemoveMatch for the same rule is still pending)
// must reach the queued subscription's handler without waiting for a
// socketManager.loop() tick, mirroring the first-acquisition path.
debug(ae_unittest) unittest
{
	auto script = new DbusClientTestAttemptScript;
	auto client = dbusClientTestConnect(script);
	auto transport = script.transports[0];
	dbusClientTestAuthenticate(transport);
	dbusClientTestReady(transport);

	auto match = DbusSignalMatch.signal()
		.withInterface(DbusInterfaceName.parse("org.example.Interface"))
		.withMember(DbusMemberName.parse("Changed"));

	DbusSubscription firstSubscription;
	client.subscribe(match, (const ref DbusSignalMessage signal) {})
		.then((DbusSubscription value) {
			firstSubscription = value;
		}, (Exception) {
			assert(false);
		}).ignoreResult();
	auto firstAdd = dbusClientTestSentMessage(transport, 4);
	transport.receive(dbusClientTestMethodReturn(firstAdd.serial, DbusBody.from()));
	socketManager.loop();
	assert(firstSubscription !is null);

	firstSubscription.unsubscribe().ignoreResult();
	auto remove = dbusClientTestSentMessage(transport, 5);

	size_t secondCalls;
	DbusSubscription secondSubscription;
	client.subscribe(match, (const ref DbusSignalMessage signal) {
		secondCalls++;
	}).then((DbusSubscription value) {
		secondSubscription = value;
	}, (Exception) {
		assert(false);
	}).ignoreResult();

	// RemoveMatch completes while the re-subscription is queued; this
	// triggers finishRemoteMatchRemoval, which re-adds the rule.
	transport.receive(dbusClientTestMethodReturn(remove.serial, DbusBody.from()));
	socketManager.loop();
	assert(transport.sent.length == 7);
	auto secondAdd = dbusClientTestSentMessage(transport, 6);
	assert(secondAdd.headers.member.text == "AddMatch");

	// Deliver the second AddMatch reply and a matching signal in the same
	// read batch, before running the event loop.
	transport.receive(dbusClientTestMethodReturn(secondAdd.serial, DbusBody.from()));
	transport.receive(dbusClientTestSignal(":1.7", "", DbusBody.from("re-add same batch")));
	assert(secondCalls == 1);
	socketManager.loop();
	assert(secondSubscription !is null);
}

debug(ae_unittest) unittest
{
	auto script = new DbusClientTestAttemptScript;
	auto client = dbusClientTestConnect(script);
	auto transport = script.transports[0];
	dbusClientTestAuthenticate(transport);
	dbusClientTestReady(transport);
	auto service = DbusBusName.parse("org.example.FinalWatchService");
	auto match = DbusSignalMatch.signal()
		.withSender(service)
		.withPath(DbusObjectPath.parse("/org/example/Object"))
		.withInterface(DbusInterfaceName.parse("org.example.Interface"))
		.withMember(DbusMemberName.parse("Changed"));
	DbusSubscription subscription;
	client.subscribe(match, (const ref DbusSignalMessage signal) {})
		.then((DbusSubscription value) {
			subscription = value;
		}, (Exception) {
			assert(false);
		}).ignoreResult();
	auto watchAdd = dbusClientTestSentMessage(transport, 4);
	transport.receive(dbusClientTestMethodReturn(watchAdd.serial, DbusBody.from()));
	socketManager.loop();
	auto seed = dbusClientTestSentMessage(transport, 5);
	transport.receive(dbusClientTestMethodReturn(seed.serial, DbusBody.from(":1.120")));
	socketManager.loop();
	auto add = dbusClientTestSentMessage(transport, 6);
	transport.receive(dbusClientTestMethodReturn(add.serial, DbusBody.from()));
	socketManager.loop();
	assert(subscription !is null);
	subscription.unsubscribe().ignoreResult();
	auto remove = dbusClientTestSentMessage(transport, 7);
	transport.receive(dbusClientTestMethodReturn(remove.serial, DbusBody.from()));
	socketManager.loop();
	assert(transport.sent.length == 9);
	auto watchRemove = dbusClientTestSentMessage(transport, 8);
	assert(watchRemove.headers.member.text == "RemoveMatch");
	auto staleCallbacks = dbusClientTestCaptureCallbacks(transport);
	client.disconnect("terminal during final owner-watch removal");
	staleCallbacks.readData(dbusClientTestMethodReturn(watchRemove.serial, DbusBody.from()));
	socketManager.loop();
	assert(!subscription.active);
	assert(client.registrations_.length == 0);
	assert(client.rules_.length == 0);
	assert(client.ownerWatches_.length == 0);
	assert(client.remoteMatches_.length == 0);
	assert(transport.sent.length == 9);
}
}
