/**
 * X11 protocol.
 * Work in progress.
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

module ae.net.x11;

import std.algorithm.searching;
import std.conv : to;
import std.exception;
import std.meta;
import std.process : environment;
import std.socket;
import std.typecons : Nullable;

public import deimos.X11.X;
public import deimos.X11.Xmd;
import deimos.X11.Xproto;
public import deimos.X11.Xprotostr;

import ae.net.asockets;
import ae.utils.array;
import ae.utils.exception : CaughtException;
import ae.utils.meta;

/// These are always 32-bit in the protocol,
/// but are defined as possibly 64-bit in X.h.
/// Redefine these in terms of the protocol we implement here.
public
{
    alias CARD32    Window;
    alias CARD32    Drawable;
    alias CARD32    Font;
    alias CARD32    Pixmap;
    alias CARD32    Cursor;
    alias CARD32    Colormap;
    alias CARD32    GContext;
    alias CARD32    Atom;
    alias CARD32    VisualID;
    alias CARD32    Time;
    alias CARD8     KeyCode;
    alias CARD32    KeySym;
}

/// Implements the X11 protocol as a client.
/// Allows connecting to a local or remote X11 server.
final class X11Client
{
	/// Connect to the default X server
	/// (according to `$DISPLAY`).
	this()
	{
		this(environment["DISPLAY"]);
	}

	/// Connect to the server described by the specified display
	/// string.
	this(string display)
	{
		this(parseDisplayString(display));
	}

	/// Parse a display string into connectable address specs.
	static AddressInfo[] parseDisplayString(string display)
	{
		auto hostParts = display.findSplit(":");
		enforce(hostParts, "Invalid display string: " ~ display);
		enforce(!hostParts[2].startsWith(":"), "DECnet is unsupported");

		enforce(hostParts[2].length, "No display number"); // Not to be confused with the screen number
		auto displayNumber = hostParts[2].findSplit(".")[0];

		string hostname = hostParts[0];
		AddressInfo[] result;

		version (Posix) // Try UNIX sockets first
		if (!hostname.length)
			foreach (useAbstract; [true, false]) // Try abstract UNIX sockets first
			{
				version (linux) {} else continue;
				auto path = (useAbstract ? "\0" : "") ~ "/tmp/.X11-unix/X" ~ displayNumber;
				auto addr = new UnixAddress(path);
				result ~= AddressInfo(AddressFamily.UNIX, SocketType.STREAM, cast(ProtocolType)0, addr, path);
			}

		if (!hostname.length)
			hostname = "localhost";

		result ~= getAddressInfo(hostname, (X_TCP_PORT + displayNumber.to!ushort).to!string);
		return result;
	}

	/// Connect to the given address specs.
	this(AddressInfo[] ai)
	{
		conn = new SocketConnection;
		conn.handleConnect = &onConnect;
		conn.handleReadData = &onReadData;
		conn.connect(ai);
	}

	SocketConnection conn; /// Underlying connection.

	void delegate() handleConnect; /// Handler for when a connection is successfully established.
	@property void handleDisconnect(void delegate(string, DisconnectType) dg) { conn.handleDisconnect = dg; } /// Setter for a disconnect handler.

	void delegate(scope ref const xError error) handleError; /// Error handler

	void delegate(Data event) handleGenericEvent; /// GenericEvent handler

	/// Connection information received from the server.
	xConnSetupPrefix connSetupPrefix;
	xConnSetup connSetup; /// ditto
	string vendor; /// ditto
	immutable(xPixmapFormat)[] pixmapFormats; /// ditto
	struct Root
	{
		xWindowRoot root;
		struct Depth
		{
			xDepth depth;
			immutable(xVisualType)[] visualTypes;
		}
		Depth[] depths;
	}
	Root[] roots; /// ditto

	/// Generate a new resource ID, which can be used
	/// to identify resources created by this connection.
	CARD32 newRID()
	{
		auto counter = ridCounter++;
		CARD32 rid = connSetup.ridBase;
		ubyte counterBit = 0;
		foreach (ridBit; 0 .. typeof(rid).sizeof * 8)
		{
			auto ridMask = CARD32(1) << ridBit;
			if (connSetup.ridMask & ridMask) // May we use this bit?
			{
				// Copy the bit
				auto bit = (counter >> counterBit) & 1;
				rid |= bit << ridBit;

				auto counterMask = typeof(counter)(1) << counterBit;
				counter &= ~counterMask; // Clear the bit in the counter (for overflow check)
			}
		}
		enforce(counter == 0, "RID counter overflow - too many RIDs");
		return rid;
	}

	mixin((){
		string code;

		foreach (name; __traits(allMembers, RequestSpecs))
		{
			alias Spec = typeof(__traits(getMember, RequestSpecs, name));
			code ~= "void " ~ name ~ "(Parameters!(RequestSpecs." ~ name ~ ".encoder) params, ";
			enum haveReply = !is(typeof(Spec.decoder is null));
			if (haveReply)
				code ~= "Parameters!(RequestSpecs." ~ name ~ ".decoder) callback";
			code ~= ") { sendRequest(RequestSpecs." ~ name ~ ".encoder(params), ";
			if (haveReply)
				code ~= "(Data data) { RequestSpecs." ~ name ~ ".decoder(data, callback); }";
			else
				code ~= "null";
			code ~= "); }";
		}

		foreach (name; __traits(allMembers, EventSpecs))
		{
			alias Spec = typeof(__traits(getMember, EventSpecs, name));
			code ~= "Parameters!(EventSpecs." ~ name ~ ".decoder)[1] " ~ name ~ ";";
		}

		return code;
	}());

private:
	struct RequestSpec(alias encoder_, alias decoder_)
	{
		alias encoder = encoder_;
		alias decoder = decoder_;
	}

	/// Instantiates to a function which accepts arguments and
	/// puts them into a struct, according to its fields.
	static template simpleEncoder(Req, CARD8 reqType)
	{
		template isPertinentFieldIdx(size_t index)
		{
			enum name = __traits(identifier, Req.tupleof[index]);
			enum bool isPertinentFieldIdx =
				name != "reqType" &&
				name != "length" &&
				(name.length < 3 || name[0..3] != "pad");
		}
		alias FieldIdxType(size_t index) = typeof(Req.tupleof[index]);
		enum pertinentFieldIndices = Filter!(isPertinentFieldIdx, RangeTuple!(Req.tupleof.length));

		Data simpleEncoder(
			staticMap!(FieldIdxType, pertinentFieldIndices) args,
		) {
			Req req;
			req.reqType = reqType;

			foreach (i; RangeTuple!(args.length))
			{
				enum structIndex = pertinentFieldIndices[i];
				req.tupleof[structIndex] = args[i];
			}

			return Data((&req)[0 .. 1]);
		}
	}

	template simpleDecoder(Res)
	{
		template isPertinentFieldIdx(size_t index)
		{
			enum name = __traits(identifier, Res.tupleof[index]);
			enum bool isPertinentFieldIdx =
				name != "type" &&
				name != "sequenceNumber" &&
				(name.length < 3 || name[0..3] != "pad");
		}
		alias FieldIdxType(size_t index) = typeof(Res.tupleof[index]);
		enum pertinentFieldIndices = Filter!(isPertinentFieldIdx, RangeTuple!(Res.tupleof.length));

		void simpleDecoder(
			Data data,
			void delegate(staticMap!(FieldIdxType, pertinentFieldIndices)) handler,
		) {
			enforce(Res.sizeof < sz_xGenericReply || data.length == Res.sizeof,
				"Unexpected reply size");
			auto res = cast(Res*)data.contents.ptr;

			staticMap!(FieldIdxType, pertinentFieldIndices) args;

			foreach (i; RangeTuple!(args.length))
			{
				enum structIndex = pertinentFieldIndices[i];
				args[i] = res.tupleof[structIndex];
			}

			handler(args);
		}
	}

	struct RequestSpecs
	{
		RequestSpec!(
			function Data (
				// xCreateWindowReq struct members
				CARD8 depth, 
				Window wid,
				Window parent,
				INT16 x,
				INT16 y,
				CARD16 width,
				CARD16 height,
				CARD16 borderWidth,
				CARD16 c_class,
				VisualID visual,

				// Optional parameters whose presence
				// is indicated by a bit mask

				// Note: this is very ugly, but I'm looking forward to
				// named arguments making this much nicer to use.

				Nullable!Pixmap                  backgroundPixmap   = Nullable!Pixmap.init,
				Nullable!CARD32                  backgroundPixel    = Nullable!CARD32.init,
				Nullable!Pixmap                  borderPixmap       = Nullable!Pixmap.init,
				Nullable!CARD32                  borderPixel        = Nullable!CARD32.init,
				Nullable!(typeof(ForgetGravity)) bitGravity         = Nullable!(typeof(ForgetGravity)).init,
				Nullable!(typeof(UnmapGravity))  winGravity         = Nullable!(typeof(UnmapGravity)).init,
				Nullable!(typeof(NotUseful))     backingStore       = Nullable!(typeof(NotUseful)).init,
				Nullable!CARD32                  backingPlanes      = Nullable!CARD32.init,
				Nullable!CARD32                  backingPixel       = Nullable!CARD32.init,
				Nullable!BOOL                    overrideRedirect   = Nullable!BOOL.init,
				Nullable!BOOL                    saveUnder          = Nullable!BOOL.init,
				Nullable!(typeof(NoEventMask))   eventMask          = Nullable!(typeof(NoEventMask)).init,
				Nullable!(typeof(NoEventMask))   doNotPropagateMask = Nullable!(typeof(NoEventMask)).init,
				Nullable!Colormap                colormap           = Nullable!Colormap.init,
				Nullable!Cursor                  cursor             = Nullable!Cursor.init,
			) {
				xCreateWindowReq req;
				req.reqType = X_CreateWindow;
				req.depth = depth;
				req.wid = wid;
				req.parent = parent;
				req.x = x;
				req.y = y;
				req.width = width;
				req.height = height;
				req.borderWidth = borderWidth;
				req.c_class = c_class;
				req.visual = visual;

				CARD32[] values;
				void putValue(T)(Nullable!T param, typeof(CWBackPixmap) mask)
				{
					assert(req.mask < mask);
					if (!param.isNull)
					{
						req.mask |= mask;
						values ~= param.get();
					}
				}

				putValue(backgroundPixmap, CWBackPixmap);
				putValue(backgroundPixel, CWBackPixel);
				putValue(borderPixmap, CWBorderPixmap);
				putValue(borderPixel, CWBorderPixel);
				putValue(bitGravity, CWBitGravity);
				putValue(winGravity, CWWinGravity);
				putValue(backingStore, CWBackingStore);
				putValue(backingPlanes, CWBackingPlanes);
				putValue(backingPixel, CWBackingPixel);
				putValue(overrideRedirect, CWOverrideRedirect);
				putValue(saveUnder, CWSaveUnder);
				putValue(eventMask, CWEventMask);
				putValue(doNotPropagateMask, CWDontPropagate);
				putValue(colormap, CWColormap);
				putValue(cursor, CWCursor);

				return Data(req.bytes) ~ Data(values.bytes);
			},
			null,
		) createWindow;

		// ...

		RequestSpec!(
			function Data (
				// xCreateGCReq struct members
				GContext gc,
				Drawable drawable,

				// Optional parameters whose presence
				// is indicated by a bit mask

				Nullable!(typeof(GXclear))        c_function         = Nullable!(typeof(GXclear)).init,
				Nullable!(CARD32)                 planeMask          = Nullable!(CARD32).init,
				Nullable!(CARD32)                 foreground         = Nullable!(CARD32).init,
				Nullable!(CARD32)                 background         = Nullable!(CARD32).init,
				Nullable!(CARD16)                 lineWidth          = Nullable!(CARD16).init,
				Nullable!(typeof(LineSolid))      lineStyle          = Nullable!(typeof(LineSolid)).init,
				Nullable!(typeof(CapNotLast))     capStyle           = Nullable!(typeof(CapNotLast)).init,
				Nullable!(typeof(JoinMiter))      joinStyle          = Nullable!(typeof(JoinMiter)).init,
				Nullable!(typeof(FillSolid))      fillStyle          = Nullable!(typeof(FillSolid)).init,
				Nullable!(typeof(EvenOddRule))    fillRule           = Nullable!(typeof(EvenOddRule)).init,
				Nullable!(Pixmap)                 tile               = Nullable!(Pixmap).init,
				Nullable!(Pixmap)                 stipple            = Nullable!(Pixmap).init,
				Nullable!(INT16)                  tileStippleXOrigin = Nullable!(INT16).init,
				Nullable!(INT16)                  tileStippleYOrigin = Nullable!(INT16).init,
				Nullable!(Font)                   font               = Nullable!(Font).init,
				Nullable!(typeof(ClipByChildren)) subwindowMode      = Nullable!(typeof(ClipByChildren)).init,
				Nullable!(BOOL)                   graphicsExposures  = Nullable!(BOOL).init,
				Nullable!(INT16)                  clipXOrigin        = Nullable!(INT16).init,
				Nullable!(INT16)                  clipYOrigin        = Nullable!(INT16).init,
				Nullable!(Pixmap)                 clipMask           = Nullable!(Pixmap).init,
				Nullable!(CARD16)                 dashOffset         = Nullable!(CARD16).init,
				Nullable!(CARD8)                  dashes             = Nullable!(CARD8).init,
				Nullable!(typeof(ArcChord))       arcMode            = Nullable!(typeof(ArcChord)).init,
			) {
				xCreateGCReq req;
				req.reqType = X_CreateGC;
				req.gc = gc;
				req.drawable = drawable;

				CARD32[] values;
				void putValue(T)(Nullable!T param, typeof(GCFunction) mask)
				{
					assert(req.mask < mask);
					if (!param.isNull)
					{
						req.mask |= mask;
						values ~= param.get();
					}
				}

				// GCFunction			c_function	typeof(Clear)
				// GCPlaneMask			planeMask	CARD32
				// GCForeground			foreground	CARD32
				// GCBackground			background	CARD32
				// GCLineWidth			lineWidth	CARD16
				// GCLineStyle			lineStyle	typeof(Solid)
				// GCCapStyle			capStyle	typeof(NotLast)
				// GCJoinStyle			joinStyle	typeof(Miter)
				// GCFillStyle			fillStyle	typeof(Solid)
				// GCFillRule			fillRule	typeof(EvenOdd)
				// GCTile				tile	Pixmap                               
				// GCStipple			stipple	Pixmap                               
				// GCTileStipXOrigin	tileStippleXOrigin	INT16                    
				// GCTileStipYOrigin	tileStippleYOrigin	INT16                    
				// GCFont				font	FONT                                 
				// GCSubwindowMode		subwindowMode	typeof(ClipByChildren)       
				// GCGraphicsExposures	graphicsExposures	BOOL                     
				// GCClipXOrigin		clipXOrigin	INT16                            
				// GCClipYOrigin		clipYOrigin	INT16                            
				// GCClipMask			clipMask	Pixmap or None                   
				// GCDashOffset			dashOffset	CARD16                           
				// GCDashList			dashes	CARD8                                
				// GCArcMode			arcMode	typeof(Chord)

				putValue(c_function, GCFunction		);
				putValue(planeMask, GCPlaneMask		);
				putValue(foreground, GCForeground	);
				putValue(background, GCBackground	);
				putValue(lineWidth, GCLineWidth		);
				putValue(lineStyle, GCLineStyle		);
				putValue(capStyle, GCCapStyle		);
				putValue(joinStyle, GCJoinStyle		);
				putValue(fillStyle, GCFillStyle		);
				putValue(fillRule, GCFillRule		);
				putValue(tile, GCTile			);
				putValue(stipple, GCStipple		);
				putValue(tileStippleXOrigin, GCTileStipXOrigin);
				putValue(tileStippleYOrigin, GCTileStipYOrigin);
				putValue(font, GCFont			);
				putValue(subwindowMode, GCSubwindowMode	);
				putValue(graphicsExposures, GCGraphicsExposures);
				putValue(clipXOrigin, GCClipXOrigin	);
				putValue(clipYOrigin, GCClipYOrigin	);
				putValue(clipMask, GCClipMask		);
				putValue(dashOffset, GCDashOffset	);
				putValue(dashes, GCDashList		);
				putValue(arcMode, GCArcMode		);

				return Data(req.bytes) ~ Data(values.bytes);
			},
			null,
		) createGC;

		// ...

		RequestSpec!(
			function Data (
				// xImageTextReq struct members
				Drawable drawable,
				GContext gc,
				INT16 x,
				INT16 y,

				// Extra data
				const(char)[] string,

			) {
				xImageTextReq req;
				req.reqType = X_ImageText8;
				req.drawable = drawable;
				req.gc = gc;
				req.x = x;
				req.y = y;
				req.nChars = string.length.to!ubyte;

				return pad4(Data(req.bytes) ~ Data(string.bytes));
			},
			null,
		) imageText8;

		// ...

		RequestSpec!(
			function Data (
				// xPolyFillRectangleReq struct members
				Drawable drawable,
				GContext gc,

				// Extra data
				const(xRectangle)[] rectangles,

			) {
				xPolyFillRectangleReq req;
				req.reqType = X_PolyFillRectangle;
				req.drawable = drawable;
				req.gc = gc;

				return Data(req.bytes) ~ Data(rectangles.bytes);
			},
			null,
		) polyFillRectangle;

		// ...

		RequestSpec!(
			simpleEncoder!(xResourceReq, X_MapWindow),
			null,
		) mapWindow;
	}

	struct EventSpec(BYTE type_, alias decoder_)
	{
		enum type = type_;
		alias decoder = decoder_;
	}

	struct EventSpecs
	{
		EventSpec!(Expose, simpleDecoder!(xEvent.Expose)) handleExpose;
	}

	static Data pad4(Data packet)
	{
		packet.length = (packet.length + 3) / 4 * 4;
		return packet;
	}

	void onConnect()
	{
		xConnClientPrefix prefix;
		version (BigEndian)
			prefix.byteOrder = 'B';
		version (LittleEndian)
			prefix.byteOrder = 'l';
		prefix.majorVersion = X_PROTOCOL;
		prefix.minorVersion = X_PROTOCOL_REVISION;
		// no authentication

		conn.send(Data(prefix.bytes));
	}

	Data buffer;

	bool connected;

	ushort sequenceNumber = 1;
	void delegate(Data)[0x1_0000] replyHandlers;

	uint ridCounter; // for newRID

	void onReadData(Data data)
	{
		buffer ~= data;

		try
			while (true)
			{
				if (!connected)
				{
					auto reader = DataReader(buffer);

					auto pConnSetupPrefix = reader.read!xConnSetupPrefix();
					if (!pConnSetupPrefix)
						return;

					auto additionalBytes = reader.read!uint((*pConnSetupPrefix).length);
					if (!additionalBytes)
						return;
					auto additionalReader = DataReader(additionalBytes.data);

					connSetupPrefix = *pConnSetupPrefix;
					switch ((*pConnSetupPrefix).success)
					{
						case 0: // Failed
						{
							auto reason = additionalReader.read!char((*pConnSetupPrefix).lengthReason)
								.enforce("Insufficient bytes for reason");
							conn.disconnect("X11 connection failed: " ~ cast(string)reason.arr, DisconnectType.error);
							break;
						}
						case 1: // Success
						{
							auto pConnSetup = additionalReader.read!xConnSetup()
								.enforce("Connection setup packet too short");
							connSetup = *pConnSetup;

							auto vendorBytes = additionalReader.read!uint(((*pConnSetup).nbytesVendor + 3) / 4)
								.enforce("Connection setup packet too short");
							this.vendor = DataReader(vendorBytes.data).read!char((*pConnSetup).nbytesVendor).arr.idup;

							// scope(failure) { import std.stdio, ae.utils.json; writeln(connSetupPrefix.toPrettyJson); writeln(connSetup.toPrettyJson); writeln(pixmapFormats.toPrettyJson); writeln(roots.toPrettyJson); }

							this.pixmapFormats =
								additionalReader.read!xPixmapFormat((*pConnSetup).numFormats)
								.enforce("Connection setup packet too short")
								.arr.idup;
							foreach (i; 0 .. (*pConnSetup).numRoots)
							{
								Root root;
								// scope(failure) { import std.stdio, ae.utils.json; writeln(root.toPrettyJson); }
								root.root = *additionalReader.read!xWindowRoot()
									.enforce("Connection setup packet too short");
								foreach (j; 0 .. root.root.nDepths)
								{
									Root.Depth depth;
									depth.depth = *additionalReader.read!xDepth()
										.enforce("Connection setup packet too short");
									depth.visualTypes = additionalReader.read!xVisualType(depth.depth.nVisuals)
										.enforce("Connection setup packet too short")
										.arr.idup;
									root.depths ~= depth;
								}
								this.roots ~= root;
							}

							enforce(!additionalReader.data.length,
								"Left-over bytes in connection setup packet");

							connected = true;
							if (handleConnect)
								handleConnect();

							break;
						}
						case 2: // Authenticate
						{
							auto reason = additionalReader.read!char((*pConnSetupPrefix).lengthReason)
								.enforce("Insufficient bytes for reason");
							conn.disconnect("X11 authentication required: " ~ cast(string)reason.arr, DisconnectType.error);
							break;
						}
						default:
							throw new Exception("Unknown connection success code");
					}

					buffer = reader.data;
				}

				if (connected)
				{
					auto reader = DataReader(buffer);

					auto pGenericReply = reader.peek!xGenericReply();
					if (!pGenericReply)
						return;

					Data packet;

					switch ((*pGenericReply).type)
					{
						case X_Error:
						default:
							packet = reader.read!xGenericReply().data;
							assert(packet);
							break;
						case X_Reply:
						case GenericEvent:
							packet = reader.read!uint((*pGenericReply).length).data;
							if (!packet)
								return;
							break;
					}

					switch ((*pGenericReply).type)
					{
						case X_Error:
							if (handleError)
								handleError(*DataReader(packet).read!xError);
							else
								throw new Exception("Protocol error");
							break;
						case X_Reply:
							onReply(packet);
							break;
						case GenericEvent:
							if (handleGenericEvent)
								handleGenericEvent(packet);
							break;
						default:
							onEvent(packet);
					}

					buffer = reader.data;
				}
			}
		catch (CaughtException e)
			conn.disconnect(e.msg, DisconnectType.error);
	}

	void onReply(Data packet)
	{
		auto pHeader = DataReader(packet).peek!xGenericReply;
		auto handler = replyHandlers[(*pHeader).sequenceNumber];
		enforce(handler !is null,
			"Unexpected packet");
		replyHandlers[(*pHeader).sequenceNumber] = null;
		handler(packet);
	}

	void onEvent(Data packet)
	{
		auto pEvent = DataReader(packet).peek!xEvent;
		auto eventType = (*pEvent).u.type;
		foreach (name; __traits(allMembers, EventSpecs))
		{
			alias Spec = typeof(__traits(getMember, EventSpecs, name));
			if (Spec.type == eventType)
			{
				auto handler = __traits(getMember, this, name);
				if (handler)
					return Spec.decoder(packet, handler);
				else
					throw new Exception("No event handler for event: " ~ name);
			}
		}
		throw new Exception("Unrecognized event: " ~ eventType.to!string);
	}

	void sendRequest(Data requestData, void delegate(Data) handler)
	{
		assert(requestData.length >= sz_xReq);
		assert(requestData.length % 4 == 0);
		auto pReq = cast(xReq*)requestData.contents.ptr;
		pReq.length = (requestData.length / 4).to!ushort;

		enforce(replyHandlers[sequenceNumber] is null,
			"Sequence number overflow"); // We haven't yet received a reply from the previous cycle
		replyHandlers[sequenceNumber] = handler;
		conn.send(requestData);
		sequenceNumber++;
	}
}

private:

import std.traits;

/// Typed wrapper for Data.
/// Because Data is reference counted, this type allows encapsulating
/// a safe but typed reference to a Data slice.
struct DataObject(T)
if (!hasIndirections!T)
{
	Data data;

	T opCast(T : bool)() const
	{
		return !!data;
	}

	@property T* ptr()
	{
		assert(data && data.length == T.sizeof);
		return cast(T*)data.contents.ptr;
	}

	ref T opUnary(string op : "*")()
	{
		return *ptr;
	}
}

/// Ditto, but a dynamic array of values.
struct DataArray(T)
if (!hasIndirections!T)
{
	Data data;
	@property T[] arr()
	{
		assert(data && data.length % T.sizeof == 0);
		return cast(T[])data.contents;
	}

	T opCast(T : bool)() const
	{
		return !!data;
	}

	alias arr this;
}

/// Consumes bytes from a Data instance and returns them as typed objects on request.
/// Consumption must be committed explicitly once all desired bytes are read.
struct DataReader
{
	Data data;

	DataObject!T peek(T)()
	if (!hasIndirections!T)
	{
		if (data.length < T.sizeof)
			return DataObject!T.init;
		return DataObject!T(data[0 .. T.sizeof]);
	}

	DataArray!T peek(T)(size_t length)
	if (!hasIndirections!T)
	{
		auto size = T.sizeof * length;
		if (data.length < size)
			return DataArray!T.init;
		return DataArray!T(data[0 .. size]);
	}

	DataObject!T read(T)()
	if (!hasIndirections!T)
	{
		if (auto p = peek!T())
		{
			data = data[T.sizeof .. $];
			return p;
		}
		return DataObject!T.init;
	}

	DataArray!T read(T)(size_t length)
	if (!hasIndirections!T)
	{
		if (auto p = peek!T(length))
		{
			data = data[T.sizeof * length .. $];
			return p;
		}
		return DataArray!T.init;
	}
}
