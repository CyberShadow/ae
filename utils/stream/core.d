/**
 * Asynchronous stream fundamentals.
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

module ae.utils.stream;

import core.lifetime;

import std.sumtype;
import std.typecons;

import ae.sys.data : Data;
import ae.sys.dataset;
import ae.utils.array : asSlice;
import ae.utils.promise;
import ae.utils.vec;

/// Payload of a stream close event.
/// Contains information about why a stream was closed.
/// Can be used to decide e.g. when it makes sense to reconnect or signal an error.
struct CloseInfo
{
	/// What caused the stream to close.
	/// The distinction is superficial if `error` is non-`null`.
	enum Source
	{
		/// The stream was closed from the local side, i.e. the local application.
		/// If `error` is `null`, e.g. because the current application called `.close()`.
		/// If `error` is non-`null`, e.g. because of a protocol error,
		/// or the application threw an exception which was not handled,
		/// or the application attempted to connect to an invalid address
		/// (an operation failed synchronously).
		local,

		/// The stream was closed from the remote side or something in-between.
		/// If `error` is null, e.g. because the peer application closed the
		/// stream or an EOF was encountered.
		/// If `error` is non-`null`, e.g. because the connection was
		/// reset by the peer, or an I/O error was encountered.
		remote,
	}
	Source source; /// ditto

	/// A human-readable string providing context for why the stream was closed.
	/// E.g.: "Read error", "Connect error", "EOF", "SIGTERM".
	string reason;

	/// If `null`, the stream was closed gracefully (EOF).
	/// If non-`null`, it's an object representing the error
	/// that was encountered when the stream was closed.
	/// `error.msg` contains a human-readable description of the error.
	/// The exception class may contain additional information, such as `errno`.
	const Throwable error;
}

interface IStreamBase
{
	// /// Get stream state.
	// /// Applications should generally not need to consult this, except
	// /// when processing an out-of-band event, like SIGINT.
	// @property bool isOpen();

	// /// This is the default value for the `close` `message` string parameter.
	// static immutable defaultCloseMessage = "Stream closed by request of local software";
	// static immutable defaultCloseInfo = CloseInfo(CloseInfo.Source.local, defaultCloseMessage, null);

	// /// Logically close the stream.
	// /// Synchronously calls and propagates any registered close handlers.
	// /// Params:
	// ///  closeInfo = `CloseInfo` to pass/propagate to
	// ///              any registered stream close handlers.
	// void close(CloseInfo closeInfo = defaultCloseInfo);

	// /// Callback property for when a stream was closed.
	// alias CloseHandler = void delegate(CloseInfo info);
	// // @property CloseHandler handleClose(); /// ditto
	// @property void handleClose(CloseHandler value); /// ditto
}

struct EOF {}
alias Packet(Datum) = SumType!(
	Datum,
	EOF,
);

/// Used to signal when a packet has been read.
alias ReadPromise(Datum) = Promise!(Packet!Datum);

/// Used to signal when a written packet was processed.
alias WritePromise = Promise!void;

/// Common interface for writable streams and adapters.
/// The converse of a `IReadStream`.
interface IWriteStream(Datum) : IStreamBase
{
	/// Asynchronously write a packet.
	/// The returned promise is resolved when the write is complete,
	/// however, implementations should generally allow enqueuing
	/// writes without waiting for the previous ones to complete.
	WritePromise write(Packet!Datum packet);

	/// Signal an error.
	/// Should cause the corresponding read to fail.
	/// The returned promise should generally not fail.
	WritePromise write(Exception error);
}

/// Common interface for readable streams and adapters.
/// The converse of a `IWriteStream`.
interface IReadStream(Datum) : IStreamBase
{
	/// Requests a packet.
	/// This overload allows the caller to signal completion or a
	/// write error to the packet's sender.
	/// `handler` is called with a promise which will deliver the
	/// packet, and should return a promise which signals when the
	/// packet has been processed (or can be used to signal a write
	/// error).
	void read(scope WritePromise delegate(ReadPromise!Datum) handler);

	/// Simplified `read` wrapper.  The packet is assumed to have been
	/// successfully processed as soon as `handler` returns without throwing.
	/// Exceptions thrown by `handler` are signaled as write errors.
	final void read(void delegate(Packet!Datum) handler)
	{
		read((ReadPromise!Datum p) => p.dmd21804workaround.then((packet) {
			handler(packet);
			return resolve();
		}));
	}

	/// Simplified `read` wrapper.
	/// The packet is assumed to have been successfully processed immediately;
	/// there is no way to signal a write error.
	final ReadPromise!Datum read()
	{
		auto p = new typeof(return);
		read((Packet!Datum packet) {
			p.fulfill(packet);
		});
		return p;
	}
}

alias IDataReadStream = IReadStream!Data;
alias IDataWriteStream = IWriteStream!Data;

/// A pair of read and write streams.
interface IDuplex(Datum)
{
	@property IWriteStream!Datum writeStream();
	@property IReadStream!Datum readStream();
}

alias IDataDuplex = IDuplex!Data;


import std.range;

/// `IReadStream` backed by a range.
class RangeReadStream(R) : IReadStream!(ElementType!R)
{
	alias Datum = ElementType!R;

	R range;
	this(R range) { this.range = move(range); }

	void read(scope WritePromise delegate(ReadPromise!Datum) handler)
	{
		if (range.empty)
			handler(resolve(Packet!Datum(EOF())));
		else
		{
			handler(resolve(Packet!Datum(range.front)));
			range.popFront();
		}
	}

	// alias read = IReadStream!(ElementType!R).read;
}
IReadStream!(ElementType!R) rangeReadStream(R)(R range) { return new RangeReadStream!R(move(range)); }

Promise!(T[]) readArray(T)(IReadStream!T stream)
{
	import std.array : appender;
	auto result = appender!(T[]);
	auto p = new Promise!(T[]);
	void readNext()
	{
		stream.read().then((Packet!int packet) {
			packet.match!(
				(T i) { result ~= i; readNext(); },
				(EOF _) { p.fulfill(result[]); },
			);
		}, (Exception e) {
			p.reject(e);
		});
	}
	readNext();
	return p;
}

unittest
{
	import ae.net.asockets : socketManager;

	int[] readResult;
	[1, 2, 3]
		.rangeReadStream
		.readArray
		.then((int[] result) { readResult = result; });
	socketManager.loop();
	assert(readResult == [1, 2, 3]);
}

/// Write a range to a `IWriteStream`.
Promise!void writeRange(R, Stream)(R range, Stream stream)
if (is(Stream : IWriteStream!(ElementType!R)))
{
	alias Datum = ElementType!R;

	auto p = new Promise!void;
	void writeNext()
	{
		if (range.empty)
		{
			stream.write(Packet!Datum(EOF()))
				.then(&p.fulfill);
		}
		else
		{
			stream.write(Packet!Datum(range.front))
				.then(&writeNext);
			range.popFront();
		}
	}
	writeNext();
	return p;
}

class AppenderWriteStream(Datum) : IWriteStream!Datum
{
	this()
	{
		p = new Promise!(Datum[]);
	}

	WritePromise write(Packet!Datum packet)
	{
		packet.match!(
			(Datum datum) { appender ~= datum; },
			(EOF) { p.fulfill(appender[]); },
		);
		return resolve();
	}

	WritePromise write(Exception error)
	{
		p.reject(error);
		return resolve();
	}

	@property Promise!(Datum[]) donePromise() { return p; }

private:
	Appender!(Datum[]) appender;
	Promise!(Datum[]) p;
}

unittest
{
	import ae.net.asockets : socketManager;

	auto w = new AppenderWriteStream!int;
	[1, 2, 3].writeRange(w);
	int[] writeResult;
	w.donePromise.then((result) { writeResult = result; });
	socketManager.loop();
	assert(writeResult == [1, 2, 3]);
}


/// Returns a pair of read/write streams.
/// Writing a packet to the write stream causes it to be readable from the read stream.
IDuplex!Datum pipe(Datum)()
{
	static final class PipeDuplex : IDuplex!Datum, IReadStream!Datum, IWriteStream!Datum
	{
		struct PendingRead
		{
			ReadPromise!Datum readPromise;
			WritePromise donePromise;
		}
		PendingRead pendingRead;

		struct PendingWrite
		{
			Packet!Datum packet;
			Exception error;
			WritePromise donePromise;
		}
		/*Nullable!*/PendingWrite pendingWrite;

		private void prod()
		{
			if (pendingRead !is PendingRead.init && pendingWrite !is PendingWrite.init)
			{
				if (pendingWrite.error)
					pendingRead.readPromise.reject(pendingWrite.error);
				else
					pendingRead.readPromise.fulfill(pendingWrite.packet);
				auto writeDonePromise = pendingWrite.donePromise;
				// pendingRead.donePromise.then({ return writeDonePromise; });
				pendingRead.donePromise.then(&writeDonePromise.fulfill);

				pendingRead = PendingRead.init;
				pendingWrite = PendingWrite.init;
			}
		}

		void read(scope WritePromise delegate(ReadPromise!Datum) handler)
		{
			if (pendingRead !is PendingRead.init)
				assert(false, "A read request is already pending");
			auto readPromise = new ReadPromise!Datum;
			auto writePromise = handler(readPromise);
			pendingRead = PendingRead(readPromise, writePromise);
			prod();
		}

		private WritePromise handleWrite(Packet!Datum packet, Exception error)
		{
			auto promise = new WritePromise;
			if (pendingWrite !is PendingWrite.init)
				assert(false, "A write request is already pending");
			pendingWrite = PendingWrite(packet, error, promise);
			prod();
			return promise;
		}

		WritePromise write(Packet!Datum packet) { return handleWrite(packet, null); }
		WritePromise write(Exception error) { return handleWrite(Packet!Datum.init, error); }

		IReadStream!Datum readStream() { return this; }
		IWriteStream!Datum writeStream() { return this; }
	}
	return new PipeDuplex;
}

unittest
{
	if (false)
	{
		cast(void) pipe!Data();
	}
}

unittest
{
	import ae.net.asockets : socketManager;

	auto p = pipe!int();
	[1, 2, 3].writeRange(p.writeStream);
	int[] readResult;
	p.readStream.readArray.then((int[] result) { readResult = result; });
	socketManager.loop();
	assert(readResult == [1, 2, 3]);
}

/// Copy from a read stream to a write stream, packet-by-packet.
/// The next packet is read from `readStream` only after it has been fully written to `writeStream`.
/// The returned `Promise` is fulfilled after the `EOF` has been read and written, or in case of an error.
/// Errors are propagated to the other stream and to the returned `Promise`.
Promise!void splice(Datum)(IReadStream!Datum readStream, IWriteStream!Datum writeStream)
{
	auto copyDone = new Promise!void;
	void copyOnePacket()
	{
		readStream.read((ReadPromise!Datum readPromise) => readPromise.dmd21804workaround.then((Packet!Datum packet) {
			Promise!void readPromise;
			auto writePromise = writeStream.write(packet);
			packet.match!(
				(ref Datum _) { writePromise.then(&copyOnePacket); },
				(ref EOF   _) { writePromise.then(&copyDone.fulfill); },
			);
			return writePromise;
		}, (Exception error) {
			// return null;
			Promise!void readPromise;
			return readPromise;
		}));
	}
	copyOnePacket();
	return copyDone;
}

unittest
{
	if (false)
	{
		IDataReadStream readStream;
		IDataWriteStream writeStream;
		splice(readStream, writeStream);
	}
}

unittest
{
	import ae.net.asockets : socketManager;

	auto app = new AppenderWriteStream!int;
	splice(
		[1, 2, 3].rangeReadStream,
		app,
	);
	int[] result;
	app.donePromise.then((r) { result = r; });
	socketManager.loop();
	assert(result == [1, 2, 3]);
}
