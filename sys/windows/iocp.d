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
import core.sys.windows.winsock2 : sockaddr;

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
