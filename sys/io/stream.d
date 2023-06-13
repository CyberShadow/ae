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

module ae.sys.io.stream;

import ae.sys.data : Data;
import ae.utils.array : asSlice;

/// Used to indicate the state of a stream throughout its lifecycle.
enum StreamState
{
	/// The initial state, or the state after a close was fully processed.
	closed,

	/// A stream attempt is in progress.
	opening,

	/// A stream is established.
	open,

	/// Closing in progress. No data can be sent or received at this point.
	/// We are waiting for queued data to be actually sent before closing.
	closing,
}

/// Returns true if this is a connection state for which disconnecting is valid.
/// Generally, applications should be aware of the life cycle of their sockets,
/// so checking the state of a connection is unnecessary (and a code smell).
/// However, unconditionally disconnecting some connected sockets can be useful
/// when it needs to occur "out-of-bound" (not tied to the application normal life cycle),
/// such as in response to a signal.
bool closable(StreamState state) { return state >= StreamState.opening && state <= StreamState.open; }

/// Payload of a stream close event.
/// Contains information about why a stream was closed.
/// Can be used to decide e.g. when it makes sense to reconnect.
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
	/// Callback setter for when a stream has been opened (if applicable).
	alias OpenHandler = void delegate();
	@property void handleOpen(OpenHandler value); /// ditto

	/// Get stream state.
	/// Applications should generally not need to consult this, except
	/// when processing an out-of-band event, like SIGINT.
	@property StreamState state();

	/// This is the default value for the `close` `message` string parameter.
	static immutable defaultCloseMessage = "Software closed the stream";
	static immutable defaultCloseInfo = CloseInfo(CloseInfo.Source.local, defaultCloseMessage, null);

	/// Logically close the stream.
	/// Synchronously calls and propagates any registered close handlers.
	/// For write streams, if there is any queued data, the stream will be actually closed
	/// after all pending data is flushed.
	/// Params:
	///  closeInfo = CloseInfo to pass/propagate to
	///              any registered stream close handlers.
	void close(CloseInfo closeInfo = defaultCloseInfo);

	/// Callback setter for when a stream was closed.
	alias CloseHandler = void delegate(CloseInfo info);
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

	/// Callback setter for when all queued data has been sent.
	alias BufferFlushedHandler = void delegate();
	@property void handleBufferFlushed(BufferFlushedHandler value); /// ditto
}

/// Common interface for readable streams and adapters.
interface IReadStream(Datum) : IStreamBase
{
	/// Callback setter for when new data is read.
	alias DataHandler = void delegate(Datum data);
	@property void handleData(DataHandler value); /// ditto

}

/// Common interface for streams and adapters.
interface IStream(Datum) : IReadStream!Datum, IWriteStream!Datum
{

}

alias IDataStream = IStream!Data;
