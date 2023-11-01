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

import ae.sys.data : Data;
import ae.utils.array : asSlice;

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
	/// Get stream state.
	/// Applications should generally not need to consult this, except
	/// when processing an out-of-band event, like SIGINT.
	@property bool isOpen();

	/// This is the default value for the `close` `message` string parameter.
	static immutable defaultCloseMessage = "Stream closed by request of local software";
	static immutable defaultCloseInfo = CloseInfo(CloseInfo.Source.local, defaultCloseMessage, null);

	/// Logically close the stream.
	/// Synchronously calls and propagates any registered close handlers.
	/// Params:
	///  closeInfo = `CloseInfo` to pass/propagate to
	///              any registered stream close handlers.
	void close(CloseInfo closeInfo = defaultCloseInfo);

	/// Callback property for when a stream was closed.
	alias CloseHandler = void delegate(CloseInfo info);
	// @property CloseHandler handleClose(); /// ditto
	@property void handleClose(CloseHandler value); /// ditto
}

/// Common interface for writable streams and adapters.
interface IWriteStream(Datum) : IStreamBase
{
	/// Queue data for sending.
	void put(scope Datum[] data);

	/// ditto
	final void put(Datum datum)
	{
		this.put(datum.asSlice);
	}
}

/// Common interface for readable streams and adapters.
interface IReadStream(Datum) : IStreamBase
{
	/// Callback property for when new data is read.
	alias DataHandler = void delegate(Datum data);
	// @property DataHandler handleData(); /// ditto
	@property void handleData(DataHandler value); /// ditto
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

void splice(Datum)(IReadStream!Datum readStream, IWriteStream!Datum writeStream)
{
	readStream.handleData = &writeStream.put;
	readStream.handleClose = (closeInfo) { if (writeStream.isOpen) writeStream.close(closeInfo); };
	writeStream.handleClose = (closeInfo) { if (readStream.isOpen) readStream.close(closeInfo); };
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
