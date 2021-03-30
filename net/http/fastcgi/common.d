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
 *   Vladimir Panteleev <ae@cy.md>
 */

module ae.net.http.fastcgi.common;

import ae.utils.bitmanip;

/// Listening socket file number
enum FCGI_LISTENSOCK_FILENO = /*STDIN_FILENO*/ 0;

/// FastCGI protocol packet header.
struct FCGI_RecordHeader
{
	ubyte version_; /// FastCGI protocol version. Should be FCGI_VERSION_1.
	FCGI_RecordType type; /// FastCGI record (packet) type.
	BigEndian!ushort requestId; /// Request ID.
	BigEndian!ushort contentLength; /// Number of bytes of data following this header.
	ubyte paddingLength; /// Number of additional bytes used for padding.
	ubyte reserved; /// Unused.
}
static assert(FCGI_RecordHeader.sizeof == 8);

/// Value for version component of FCGI_Header
enum FCGI_VERSION_1 = 1;

/// Values for type component of FCGI_Header
enum FCGI_RecordType : ubyte
{
	beginRequest    =  1,   /// FCGI_BEGIN_REQUEST     ( webserver-sent                     )
	abortRequest    =  2,   /// FCGI_ABORT_REQUEST     ( webserver-sent                     )
	endRequest      =  3,   /// FCGI_END_REQUEST
	params          =  4,   /// FCGI_PARAMS            ( webserver-sent,             stream )
	stdin           =  5,   /// FCGI_STDIN             ( webserver-sent,             stream )
	stdout          =  6,   /// FCGI_STDOUT            (                             stream )
	stderr          =  7,   /// FCGI_STDERR            (                             stream )
	data            =  8,   /// FCGI_DATA              ( webserver-sent,             stream )
	getValues       =  9,   /// FCGI_GET_VALUES        ( webserver-sent, management         )
	getValuesResult = 10,   /// FCGI_GET_VALUES_RESULT (                 management         )
	unknownType     = 11,   /// FCGI_UNKNOWN_TYPE      (                 management         )
}

/// Value for requestId component of FCGI_Header.
enum FCGI_NULL_REQUEST_ID = 0;

/// Structure of FCGI_BEGIN_REQUEST packets.
struct FCGI_BeginRequestBody
{
	BigEndian!FCGI_Role role; /// FastCGI application role.
    FCGI_RequestFlags flags; /// Request flags.
    ubyte[5] reserved; /// Unused.
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

/// Structure of FCGI_END_REQUEST packets.
struct FCGI_EndRequestBody
{
	BigEndian!uint appStatus; /// Application-supplied status code.
    FCGI_ProtocolStatus protocolStatus; /// FastCGI status code.
    ubyte[3] reserved; /// Unused.
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
enum FCGI_MAX_REQS   = "FCGI_MAX_REQS"; /// ditto
enum FCGI_MPXS_CONNS = "FCGI_MPXS_CONNS"; /// ditto

/// Structure of FCGI_UNKNOWN_TYPE packets.
struct FCGI_UnknownTypeBody
{
    FCGI_RecordType type; /// The record type that was not recognized.
    ubyte[7] reserved; /// Unused.
}
