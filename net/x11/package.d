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
import std.ascii : toLower;
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
import ae.utils.text.ascii : toDec;

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

/// Used for CreateWindow and ChangeWindowAttributes.
struct WindowAttributes
{
	/// This will generate `Nullable` fields `backPixmap`, `backPixel`, ...
	mixin Optionals!(
		CWBackPixmap      , Pixmap               ,
		CWBackPixel       , CARD32               ,
		CWBorderPixmap    , Pixmap               ,
		CWBorderPixel     , CARD32               ,
		CWBitGravity      , typeof(ForgetGravity),
		CWWinGravity      , typeof(UnmapGravity) ,
		CWBackingStore    , typeof(NotUseful)    ,
		CWBackingPlanes   , CARD32               ,
		CWBackingPixel    , CARD32               ,
		CWOverrideRedirect, BOOL                 ,
		CWSaveUnder       , BOOL                 ,
		CWEventMask       , typeof(NoEventMask)  ,
		CWDontPropagate   , typeof(NoEventMask)  ,
		CWColormap        , Colormap             ,
		CWCursor          , Cursor               ,
	);
}

/// Used for ConfigureWindow.
struct WindowConfiguration
{
	/// This will generate `Nullable` fields `x`, `y`, ...
	mixin Optionals!(
		CWX           , INT16,
		CWY           , INT16,
		CWWidth       , CARD16,
		CWHeight      , CARD16,
		CWBorderWidth , CARD16,
		CWSibling     , Window,
		CWStackMode   , typeof(Above),
	);
}

/// Used for CreateGC, ChangeGC and CopyGC.
struct GCAttributes
{
	/// This will generate `Nullable` fields `c_function`, `planeMask`, ...
	mixin Optionals!(
		GCFunction          , typeof(GXclear)       ,
		GCPlaneMask         , CARD32                ,
		GCForeground        , CARD32                ,
		GCBackground        , CARD32                ,
		GCLineWidth         , CARD16                ,
		GCLineStyle         , typeof(LineSolid)     ,
		GCCapStyle          , typeof(CapNotLast)    ,
		GCJoinStyle         , typeof(JoinMiter)     ,
		GCFillStyle         , typeof(FillSolid)     ,
		GCFillRule          , typeof(EvenOddRule)   ,
		GCTile              , Pixmap                ,
		GCStipple           , Pixmap                ,
		GCTileStipXOrigin   , INT16                 ,
		GCTileStipYOrigin   , INT16                 ,
		GCFont              , Font                  ,
		GCSubwindowMode     , typeof(ClipByChildren),
		GCGraphicsExposures , BOOL                  ,
		GCClipXOrigin       , INT16                 ,
		GCClipYOrigin       , INT16                 ,
		GCClipMask          , Pixmap                ,
		GCDashOffset        , CARD16                ,
		GCDashList          , CARD8                 ,
		GCArcMode           , typeof(ArcChord)      ,
	);
}

/// xReq equivalent for requests with no arguments.
extern(C) struct xEmptyReq
{
    CARD8 reqType;
    CARD8 pad;
    CARD16 length;
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

	/// To avoid repetition, methods for sending packets and handlers for events are generated.
	/// This will generate senders such as sendCreateWindow,
	/// and event handlers such as handleExpose.
	enum generatedCode = (){
		string code;

		foreach (i, Spec; RequestSpecs)
		{
			enum index = toDec(i);
			assert(Spec.reqName[0 .. 2] == "X_");
			code ~= "void send" ~ Spec.reqName[2 .. $] ~ "(Parameters!(RequestSpecs[" ~ index ~ "].encoder) params, ";
			enum haveReply = !is(Spec.decoder == void);
			if (haveReply)
				code ~= "Parameters!(RequestSpecs[" ~ index ~ "].decoder)[1] callback";
			code ~= ") { sendRequest(RequestSpecs[" ~ index ~ "].reqType, RequestSpecs[" ~ index ~ "].encoder(params), ";
			if (haveReply)
				code ~= "(Data data) { RequestSpecs[" ~ index ~ "].decoder(data, callback); }";
			else
				code ~= "null";
			code ~= "); }\n";
		}

		foreach (i, Spec; EventSpecs)
		{
			enum index = toDec(i);
			code ~= "Parameters!(EventSpecs[" ~ index ~ "].decoder)[1] handle" ~ Spec.name ~ ";\n";
		}

		return code;
	}();
	// pragma(msg, generatedCode);
	mixin(generatedCode);

private:
	struct RequestSpec(args...)
	if (args.length == 3)
	{
		enum reqType = args[0];
		enum reqName = __traits(identifier, args[0]);
		alias encoder = args[1];
		alias decoder = args[2];
	}

	/// Instantiates to a function which accepts arguments and
	/// puts them into a struct, according to its fields.
	static template simpleEncoder(Req)
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

	alias RequestSpecs = AliasSeq!(
		RequestSpec!(
			X_CreateWindow,
			function Data (
				// Request struct members
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
				in ref WindowAttributes windowAttributes,
			) {
				CARD32 mask;
				auto values = windowAttributes._serialize(mask);
				mixin(populateRequestFromLocals!xCreateWindowReq);
				return Data(req.bytes) ~ Data(values.bytes);
			},
			void,
		),

		RequestSpec!(
			X_ChangeWindowAttributes,
			function Data (
				// Request struct members
				Window window,

				// Optional parameters whose presence
				// is indicated by a bit mask
				in ref WindowAttributes windowAttributes,
			) {
				CARD32 valueMask;
				auto values = windowAttributes._serialize(valueMask);
				mixin(populateRequestFromLocals!xChangeWindowAttributesReq);
				return Data(req.bytes) ~ Data(values.bytes);
			},
			void,
		),

		RequestSpec!(
			X_GetWindowAttributes,
			simpleEncoder!xResourceReq,
			simpleDecoder!xGetWindowAttributesReply,
		),

		RequestSpec!(
			X_DestroyWindow,
			simpleEncoder!xResourceReq,
			void,
		),

		RequestSpec!(
			X_DestroySubwindows,
			simpleEncoder!xResourceReq,
			void,
		),

		RequestSpec!(
			X_ChangeSaveSet,
			simpleEncoder!xChangeSaveSetReq,
			void,
		),

		RequestSpec!(
			X_ReparentWindow,
			simpleEncoder!xReparentWindowReq,
			void,
		),

		RequestSpec!(
			X_MapWindow,
			simpleEncoder!xResourceReq,
			void,
		),

		RequestSpec!(
			X_MapSubwindows,
			simpleEncoder!xResourceReq,
			void,
		),

		RequestSpec!(
			X_UnmapWindow,
			simpleEncoder!xResourceReq,
			void,
		),

		RequestSpec!(
			X_UnmapSubwindows,
			simpleEncoder!xResourceReq,
			void,
		),

		RequestSpec!(
			X_ConfigureWindow,
			function Data (
				// Request struct members
				Window window,

				// Optional parameters whose presence
				// is indicated by a bit mask
				in ref WindowConfiguration windowConfiguration,
			) {
				CARD16 mask;
				auto values = windowConfiguration._serialize(mask);
				mixin(populateRequestFromLocals!xConfigureWindowReq);
				return Data(req.bytes) ~ Data(values.bytes);
			},
			void,
		),

		RequestSpec!(
			X_CirculateWindow,
			simpleEncoder!xCirculateWindowReq,
			void,
		),

		RequestSpec!(
			X_GetGeometry,
			simpleEncoder!xResourceReq,
			simpleDecoder!xGetGeometryReply,
		),

		RequestSpec!(
			X_QueryTree,
			simpleEncoder!xResourceReq,
			function void(
				Data data,
				void delegate(
					Window root,
					Window parent,
					Window[] children,
				) handler,
			) {
				auto reader = DataReader(data);
				auto header = *reader.read!xQueryTreeReply().enforce("Unexpected reply size");
				auto children = reader.read!Window(header.nChildren).enforce("Unexpected reply size");
				enforce(reader.data.length == 0, "Unexpected reply size");

				handler(
					header.root,
					header.parent,
					children,
				);
			}
		),

		RequestSpec!(
			X_InternAtom,
			function Data (
				// Request struct members
				bool onlyIfExists,

				// Extra data
				const(char)[] name,

			) {
				auto nbytes = name.length.to!CARD16;
				mixin(populateRequestFromLocals!xInternAtomReq);
				return pad4(Data(req.bytes) ~ Data(name.bytes));
			},
			simpleDecoder!xInternAtomReply,
		),

		RequestSpec!(
			X_GetAtomName,
			simpleEncoder!xResourceReq,
			function void(
				Data data,
				void delegate(
					const(char)[] name,
				) handler,
			) {
				auto reader = DataReader(data);
				auto header = *reader.read!xGetAtomNameReply().enforce("Unexpected reply size");
				auto name = reader.read!char(header.nameLength).enforce("Unexpected reply size");
				enforce(reader.data.length < 4, "Unexpected reply size");

				handler(
					name,
				);
			}
		),

		RequestSpec!(
			X_ChangeProperty,
			function Data (
				// Request struct members
				CARD8 mode,
				Window window,
				Atom property,
				Atom type,
				CARD8 format,

				// Extra data
				const(ubyte)[] data,

			) {
				auto nUnits = (data.length * 8 / format).to!CARD32;
				mixin(populateRequestFromLocals!xChangePropertyReq);
				return pad4(Data(req.bytes) ~ Data(data.bytes));
			},
			void,
		),

		RequestSpec!(
			X_DeleteProperty,
			simpleEncoder!xDeletePropertyReq,
			void,
		),

		RequestSpec!(
			X_GetProperty,
			simpleEncoder!xGetPropertyReq,
			function void(
				Data data,
				void delegate(
					CARD8 format,
					Atom propertyType,
					CARD32 bytesAfter,
					const(ubyte)[] value,
				) handler,
			) {
				auto reader = DataReader(data);
				auto header = *reader.read!xGetPropertyReply().enforce("Unexpected reply size");
				auto dataLength = header.nItems * header.format / 8;
				auto value = reader.read!ubyte(dataLength).enforce("Unexpected reply size");
				enforce(reader.data.length < 4, "Unexpected reply size");

				handler(
					header.format,
					header.propertyType,
					header.bytesAfter,
					value,
				);
			}
		),

		RequestSpec!(
			X_ListProperties,
			simpleEncoder!xResourceReq,
			function void(
				Data data,
				void delegate(
					Atom[] atoms,
				) handler,
			) {
				auto reader = DataReader(data);
				auto header = *reader.read!xListPropertiesReply().enforce("Unexpected reply size");
				auto atoms = reader.read!Atom(header.nProperties).enforce("Unexpected reply size");
				enforce(reader.data.length < 4, "Unexpected reply size");

				handler(
					atoms,
				);
			}
		),

		RequestSpec!(
			X_SetSelectionOwner,
			simpleEncoder!xSetSelectionOwnerReq,
			void,
		),

		RequestSpec!(
			X_GetSelectionOwner,
			simpleEncoder!xResourceReq,
			simpleDecoder!xGetSelectionOwnerReply,
		),

		RequestSpec!(
			X_ConvertSelection,
			simpleEncoder!xConvertSelectionReq,
			void,
		),

		RequestSpec!(
			X_SendEvent,
			simpleEncoder!xSendEventReq,
			void,
		),

		RequestSpec!(
			X_GrabPointer,
			simpleEncoder!xGrabPointerReq,
			simpleDecoder!xGrabPointerReply,
		),

		RequestSpec!(
			X_UngrabPointer,
			simpleEncoder!xResourceReq,
			void,
		),

		RequestSpec!(
			X_GrabButton,
			simpleEncoder!xGrabButtonReq,
			void,
		),

		RequestSpec!(
			X_UngrabButton,
			simpleEncoder!xUngrabButtonReq,
			void,
		),

		RequestSpec!(
			X_ChangeActivePointerGrab,
			simpleEncoder!xChangeActivePointerGrabReq,
			void,
		),

		RequestSpec!(
			X_GrabKeyboard,
			simpleEncoder!xGrabKeyboardReq,
			simpleDecoder!xGrabKeyboardReply,
		),

		RequestSpec!(
			X_UngrabKeyboard,
			simpleEncoder!xResourceReq,
			void,
		),

		RequestSpec!(
			X_GrabKey,
			simpleEncoder!xGrabKeyReq,
			void,
		),

		RequestSpec!(
			X_UngrabKey,
			simpleEncoder!xUngrabKeyReq,
			void,
		),

		RequestSpec!(
			X_AllowEvents,
			simpleEncoder!xAllowEventsReq,
			void,
		),

		RequestSpec!(
			X_GrabServer,
			simpleEncoder!xEmptyReq,
			void,
		),

		RequestSpec!(
			X_UngrabServer,
			simpleEncoder!xEmptyReq,
			void,
		),

		RequestSpec!(
			X_QueryPointer,
			simpleEncoder!xResourceReq,
			simpleDecoder!xQueryPointerReply,
		),

		RequestSpec!(
			X_GetMotionEvents,
			simpleEncoder!xGetMotionEventsReq,
			function void(
				Data data,
				void delegate(
					const(xTimecoord)[] events,
				) handler,
			) {
				auto reader = DataReader(data);
				auto header = *reader.read!xGetMotionEventsReply().enforce("Unexpected reply size");
				auto events = reader.read!xTimecoord(header.nEvents).enforce("Unexpected reply size");
				enforce(reader.data.length == 0, "Unexpected reply size");

				handler(
					events,
				);
			}
		),

		RequestSpec!(
			X_TranslateCoords,
			simpleEncoder!xTranslateCoordsReq,
			simpleDecoder!xTranslateCoordsReply,
		),

		RequestSpec!(
			X_WarpPointer,
			simpleEncoder!xWarpPointerReq,
			void,
		),

		RequestSpec!(
			X_SetInputFocus,
			simpleEncoder!xSetInputFocusReq,
			void,
		),

		RequestSpec!(
			X_GetInputFocus,
			simpleEncoder!xEmptyReq,
			simpleDecoder!xGetInputFocusReply,
		),

		RequestSpec!(
			X_QueryKeymap,
			simpleEncoder!xEmptyReq,
			simpleDecoder!xQueryKeymapReply,
		),

		RequestSpec!(
			X_OpenFont,
			simpleEncoder!xOpenFontReq,
			void,
		),

		RequestSpec!(
			X_CloseFont,
			simpleEncoder!xResourceReq,
			void,
		),

		// RequestSpec!(
		// 	X_QueryFont,
		// 	simpleEncoder!xResourceReq,
		// 	TODO
		// ),

		// ...

		RequestSpec!(
			X_CreateGC,
			function Data (
				// Request struct members
				GContext gc,
				Drawable drawable,

				// Optional parameters whose presence
				// is indicated by a bit mask
				in ref GCAttributes gcAttributes,
			) {
				CARD32 mask;
				auto values = gcAttributes._serialize(mask);
				mixin(populateRequestFromLocals!xCreateGCReq);
				return Data(req.bytes) ~ Data(values.bytes);
			},
			void,
		),

		// ...

		RequestSpec!(
			X_ImageText8,
			function Data (
				// Request struct members
				Drawable drawable,
				GContext gc,
				INT16 x,
				INT16 y,

				// Extra data
				const(char)[] string,

			) {
				auto nChars = string.length.to!ubyte;
				mixin(populateRequestFromLocals!xImageText8Req);
				return pad4(Data(req.bytes) ~ Data(string.bytes));
			},
			void,
		),

		// ...

		RequestSpec!(
			X_PolyFillRectangle,
			function Data (
				// Request struct members
				Drawable drawable,
				GContext gc,

				// Extra data
				const(xRectangle)[] rectangles,

			) {
				mixin(populateRequestFromLocals!xPolyFillRectangleReq);
				return Data(req.bytes) ~ Data(rectangles.bytes);
			},
			void,
		),
	);

	struct EventSpec(args...)
	if (args.length == 2)
	{
		enum name = __traits(identifier, args[0]);
		enum type = args[0];
		alias decoder = args[1];
	}

	alias EventSpecs = AliasSeq!(
		EventSpec!(Expose, simpleDecoder!(xEvent.Expose)),
	);

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
		foreach (Spec; EventSpecs)
		{
			if (Spec.type == eventType)
			{
				auto handler = __traits(getMember, this, "handle" ~ Spec.name);
				if (handler)
					return Spec.decoder(packet, handler);
				else
					throw new Exception("No event handler for event: " ~ Spec.name);
			}
		}
		throw new Exception("Unrecognized event: " ~ eventType.to!string);
	}

	void sendRequest(BYTE reqType, Data requestData, void delegate(Data) handler)
	{
		assert(requestData.length >= sz_xReq);
		assert(requestData.length % 4 == 0);
		auto pReq = cast(xReq*)requestData.contents.ptr;
		pReq.reqType = reqType;
		pReq.length = (requestData.length / 4).to!ushort;

		enforce(replyHandlers[sequenceNumber] is null,
			"Sequence number overflow"); // We haven't yet received a reply from the previous cycle
		replyHandlers[sequenceNumber] = handler;
		conn.send(requestData);
		sequenceNumber++;
	}
}

// ************************************************************************

private:

mixin template Optionals(args...)
if (args.length % 2 == 0)
{
	alias _args = args; // DMD bug workaround

	private mixin template Field(size_t i)
	{
		alias Type = args[i * 2 + 1];
		enum maskName = __traits(identifier, args[i * 2]);
		enum fieldName = toLower(maskName[2]) ~ maskName[3 .. $];
		enum prefix = is(typeof(mixin("(){int " ~ fieldName ~ "; }()"))) ? "" : "c_";
		mixin(`Nullable!Type ` ~ prefix ~ fieldName ~ ';');
	}

	static foreach (i; 0 .. args.length / 2)
		mixin Field!i;

	CARD32[] _serialize(Mask)(ref Mask mask) const
	{
		CARD32[] result;
		static foreach (i; 0 .. _args.length / 2)
			if (!this.tupleof[i].isNull)
			{
				enum fieldMask = _args[i * 2];
				assert(mask < fieldMask);
				result ~= this.tupleof[i].get();
				mask |= fieldMask;
			}
		return result;
	}
}

/// Generate code to populate all of a request struct's fields from arguments / locals.
string populateRequestFromLocals(T)()
{
	string code = T.stringof ~ " req;\n";
	foreach (i; RangeTuple!(T.tupleof.length))
	{
		enum name = __traits(identifier, T.tupleof[i]);
		enum isPertinentField =
			name != "reqType" &&
			name != "length" &&
			(name.length < 3 || name[0..3] != "pad");
		if (isPertinentField)
			code ~= "req." ~ name ~ " = " ~ name ~ ";\n";
	}
	return code;
}

// ************************************************************************

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
