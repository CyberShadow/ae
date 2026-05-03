/**
 * IOCP and overlapped-I/O Win32 declarations not provided by druntime.
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

module ae.sys.windows.iocp;

version (Windows):

import core.sys.windows.windows;
import core.sys.windows.winsock2 : sockaddr, WSAIoctl;

extern (Windows) nothrow @nogc
{
	struct OVERLAPPED_ENTRY
	{
		ULONG_PTR     lpCompletionKey;
		OVERLAPPED*   lpOverlapped;
		ULONG_PTR     Internal;
		DWORD         dwNumberOfBytesTransferred;
	}

	BOOL GetQueuedCompletionStatusEx(
		HANDLE             CompletionPort,
		OVERLAPPED_ENTRY*  lpCompletionPortEntries,
		ULONG              ulCount,
		ULONG*             ulNumEntriesRemoved,
		DWORD              dwMilliseconds,
		BOOL               fAlertable);

	struct WSABUF
	{
		ULONG  len;
		char*  buf;
	}

	int WSARecv(
		size_t          s,             // SOCKET
		WSABUF*         lpBuffers,
		DWORD           dwBufferCount,
		DWORD*          lpNumberOfBytesRecvd,
		DWORD*          lpFlags,
		OVERLAPPED*     lpOverlapped,
		void*           lpCompletionRoutine);

	int WSASend(
		size_t          s,             // SOCKET
		WSABUF*         lpBuffers,
		DWORD           dwBufferCount,
		DWORD*          lpNumberOfBytesSent,
		DWORD           dwFlags,
		OVERLAPPED*     lpOverlapped,
		void*           lpCompletionRoutine);

	int WSARecvFrom(
		size_t          s,             // SOCKET
		WSABUF*         lpBuffers,
		DWORD           dwBufferCount,
		DWORD*          lpNumberOfBytesRecvd,
		DWORD*          lpFlags,
		sockaddr*       lpFrom,
		int*            lpFromlen,
		OVERLAPPED*     lpOverlapped,
		void*           lpCompletionRoutine);

	// AcceptEx and GetAcceptExSockaddrs are exported from Mswsock.dll.
	BOOL AcceptEx(
		size_t      sListenSocket,
		size_t      sAcceptSocket,
		void*       lpOutputBuffer,
		DWORD       dwReceiveDataLength,
		DWORD       dwLocalAddressLength,
		DWORD       dwRemoteAddressLength,
		DWORD*      lpdwBytesReceived,
		OVERLAPPED* lpOverlapped);

	void GetAcceptExSockaddrs(
		void*               lpOutputBuffer,
		DWORD               dwReceiveDataLength,
		DWORD               dwLocalAddressLength,
		DWORD               dwRemoteAddressLength,
		sockaddr**          LocalSockaddr,
		int*                LocalSockaddrLength,
		sockaddr**          RemoteSockaddr,
		int*                RemoteSockaddrLength);

	// Creates a socket with WSA_FLAG_OVERLAPPED; needed for AcceptEx candidates.
	size_t WSASocketW(
		int    af,
		int    type,
		int    protocol,
		void*  lpProtocolInfo,  // LPWSAPROTOCOL_INFOW — null for defaults
		uint   g,               // GROUP
		DWORD  dwFlags);

	// Thread-pool wait: fires a callback when an object becomes signaled.
	// Not in druntime; declared here.
	BOOL RegisterWaitForSingleObject(
		HANDLE*             phNewWaitObject,
		HANDLE              hObject,
		WAITORTIMERCALLBACK Callback,
		PVOID               Context,
		ULONG               dwMilliseconds,
		ULONG               dwFlags);

	void WSASetLastError(int);
}

// ConnectEx is dispatched via a function pointer obtained at runtime through
// WSAIoctl with SIO_GET_EXTENSION_FUNCTION_POINTER.
extern (Windows) alias LPFN_CONNECTEX = BOOL function(
	size_t           s,
	const(sockaddr)* name,
	int              namelen,
	void*            lpSendBuffer,
	DWORD            dwSendDataLength,
	DWORD*           lpdwBytesSent,
	OVERLAPPED*      lpOverlapped) nothrow @nogc;

pragma(lib, "Mswsock");

// Error codes not in druntime
enum WSA_IO_PENDING             = 997;
enum ERROR_NETNAME_DELETED      = 64;
enum ERROR_NO_DATA              = 232;

// AcceptEx constants
enum WSA_FLAG_OVERLAPPED        = 0x01;
enum SO_UPDATE_ACCEPT_CONTEXT   = 0x700B;
// Each AcceptEx address slot must be sizeof(SOCKADDR_STORAGE)+16.
// SOCKADDR_STORAGE is 128 bytes on Windows, so each slot is 144 bytes.
enum ACCEPT_ADDR_SIZE           = 128 + 16;

// ConnectEx constants
// {25A207B9-DDF3-4660-8EE9-76E58C74063E}
enum GUID WSAID_CONNECTEX = GUID(
	0x25a207b9, 0xddf3, 0x4660,
	[0x8e, 0xe9, 0x76, 0xe5, 0x8c, 0x74, 0x06, 0x3e]);

// SIO_GET_EXTENSION_FUNCTION_POINTER == IOC_INOUT | IOC_WS2 | 6 == 0xC8000006
enum DWORD SIO_GET_EXTENSION_FUNCTION_POINTER = 0xC8000006;

// Must be set on the socket after ConnectEx completes for getpeername /
// shutdown / etc. to behave correctly.
enum SO_UPDATE_CONNECT_CONTEXT  = 0x7010;
