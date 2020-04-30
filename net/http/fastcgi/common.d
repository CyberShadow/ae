/**
 * FastCGI definitions.
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

module ae.net.http.fastcgi.common;

import ae.utils.bitmanip;

/// Listening socket file number
enum FCGI_LISTENSOCK_FILENO = /*STDIN_FILENO*/ 0;

struct FCGI_RecordHeader
{
	ubyte version_;
	FCGI_RecordType type;
	BigEndian!ushort requestId;
	BigEndian!ushort contentLength;
	ubyte paddingLength;
	ubyte reserved;
}
static assert(FCGI_RecordHeader.sizeof == 8);

/// Value for version component of FCGI_Header
enum FCGI_VERSION_1 = 1;

/// Values for type component of FCGI_Header
enum FCGI_RecordType : ubyte
{
	//                                                   WS->App   management  stream
	beginRequest    =  1,   /// FCGI_BEGIN_REQUEST          x
	abortRequest    =  2,   /// FCGI_ABORT_REQUEST          x
	endRequest      =  3,   /// FCGI_END_REQUEST
	params          =  4,   /// FCGI_PARAMS                 x                    x
	stdin           =  5,   /// FCGI_STDIN                  x                    x
	stdout          =  6,   /// FCGI_STDOUT                                      x
	stderr          =  7,   /// FCGI_STDERR                                      x
	data            =  8,   /// FCGI_DATA                   x                    x
	getValues       =  9,   /// FCGI_GET_VALUES             x          x
	getValuesResult = 10,   /// FCGI_GET_VALUES_RESULT                 x
	unknownType     = 11,   /// FCGI_UNKNOWN_TYPE                      x
}

/// Value for requestId component of FCGI_Header
enum FCGI_NULL_REQUEST_ID = 0;

struct FCGI_BeginRequestBody
{
	BigEndian!FCGI_Role role;
    FCGI_RequestFlags flags;
    ubyte[5] reserved;
}

/// Mask for flags component of FCGI_BeginRequestBody
enum FCGI_RequestFlags : ubyte
{
	keepConn = 1, /// FCGI_KEEP_CONN
}

/// Values for role component of FCGI_BeginRequestBody
enum FCGI_Role : ushort
{
	responder  = 1, /// FCGI_RESPONDER
	authorizer = 2, /// FCGI_AUTHORIZER
	filter     = 3, /// FCGI_FILTER
}

struct FCGI_EndRequestBody
{
	BigEndian!uint appStatus;
    FCGI_ProtocolStatus protocolStatus;
    ubyte[3] reserved;
}

/// Values for protocolStatus component of FCGI_EndRequestBody
enum FCGI_ProtocolStatus : ubyte
{
	requestComplete = 0, /// FCGI_REQUEST_COMPLETE
	cantMpxConn     = 1, /// FCGI_CANT_MPX_CONN
	overloaded      = 2, /// FCGI_OVERLOADED
	unknownRole     = 3, /// FCGI_UNKNOWN_ROLE
}

/// Variable names for FCGI_GET_VALUES / FCGI_GET_VALUES_RESULT records
enum FCGI_MAX_CONNS  = "FCGI_MAX_CONNS";
enum FCGI_MAX_REQS   = "FCGI_MAX_REQS";
enum FCGI_MPXS_CONNS = "FCGI_MPXS_CONNS";

struct FCGI_UnknownTypeBody
{
    FCGI_RecordType type;
    ubyte[7] reserved;
}
