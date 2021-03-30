/**
 * Windows process utility code.
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

module ae.sys.windows.process;
version (Windows):

import std.exception;
import std.typecons;

import ae.sys.windows.imports;
mixin(importWin32!q{w32api});
mixin(importWin32!q{winbase});
mixin(importWin32!q{windef});
mixin(importWin32!q{winuser});

import ae.sys.windows.exception;
import ae.sys.windows.text;

alias wenforce = ae.sys.windows.exception.wenforce;

pragma(lib, "user32");

static if (_WIN32_WINNT >= 0x500) {

struct CreatedProcessImpl
{
	PROCESS_INFORMATION pi;
	alias pi this;

	DWORD wait()
	{
		WaitForSingleObject(hProcess, INFINITE);
		DWORD dwExitCode;
		wenforce(GetExitCodeProcess(hProcess, &dwExitCode), "GetExitCodeProcess");
		return dwExitCode;
	}

	~this()
	{
		CloseHandle(pi.hProcess);
		CloseHandle(pi.hThread);
	}
}

alias RefCounted!CreatedProcessImpl CreatedProcess;
CreatedProcess createProcess(string applicationName, string commandLine, STARTUPINFOW si = STARTUPINFOW.init)
{
	return createProcess(applicationName, commandLine, null, si);
}

CreatedProcess createProcess(string applicationName, string commandLine, string currentDirectory, STARTUPINFOW si = STARTUPINFOW.init)
{
	CreatedProcess result;
	wenforce(CreateProcessW(toWStringz(applicationName), cast(LPWSTR)toWStringz(commandLine), null, null, false, 0, null, toWStringz(currentDirectory), &si, &result.pi), "CreateProcess");
	AllowSetForegroundWindow(result.dwProcessId);
	AttachThreadInput(GetCurrentThreadId(), result.dwThreadId, TRUE);
	AllowSetForegroundWindow(result.dwProcessId);
	return result;
}

enum TOKEN_ADJUST_SESSIONID = 0x0100;
//enum SecurityImpersonation = 2;
//enum TokenPrimary = 1;
alias extern(Windows) BOOL function(
  HANDLE hToken,
  DWORD dwLogonFlags,
  LPCWSTR lpApplicationName,
  LPWSTR lpCommandLine,
  DWORD dwCreationFlags,
  LPVOID lpEnvironment,
  LPCWSTR lpCurrentDirectory,
  LPSTARTUPINFOW lpStartupInfo,
  LPPROCESS_INFORMATION lpProcessInfo
) CreateProcessWithTokenWFunc;

/// Create a non-elevated process, if the current process is elevated.
CreatedProcess createDesktopUserProcess(string applicationName, string commandLine, STARTUPINFOW si = STARTUPINFOW.init)
{
	CreateProcessWithTokenWFunc CreateProcessWithTokenW = cast(CreateProcessWithTokenWFunc)GetProcAddress(GetModuleHandle("advapi32.dll"), "CreateProcessWithTokenW");

	HANDLE hShellProcess = null, hShellProcessToken = null, hPrimaryToken = null;
	HWND hwnd = null;
	DWORD dwPID = 0;

	// Enable SeIncreaseQuotaPrivilege in this process.  (This won't work if current process is not elevated.)
	HANDLE hProcessToken = null;
	wenforce(OpenProcessToken(GetCurrentProcess(), TOKEN_ADJUST_PRIVILEGES, &hProcessToken), "OpenProcessToken failed");
	scope(exit) CloseHandle(hProcessToken);

	TOKEN_PRIVILEGES tkp;
	tkp.PrivilegeCount = 1;
	LookupPrivilegeValue(null, SE_INCREASE_QUOTA_NAME.ptr, &tkp.Privileges()[0].Luid);
	tkp.Privileges()[0].Attributes = SE_PRIVILEGE_ENABLED;
	wenforce(AdjustTokenPrivileges(hProcessToken, FALSE, &tkp, 0, null, null), "AdjustTokenPrivileges failed");

	// Get an HWND representing the desktop shell.
	// CAVEATS:  This will fail if the shell is not running (crashed or terminated), or the default shell has been
	// replaced with a custom shell.  This also won't return what you probably want if Explorer has been terminated and
	// restarted elevated.
	hwnd = GetShellWindow();
	enforce(hwnd, "No desktop shell is present");

	// Get the PID of the desktop shell process.
	GetWindowThreadProcessId(hwnd, &dwPID);
	enforce(dwPID, "Unable to get PID of desktop shell.");

	// Open the desktop shell process in order to query it (get the token)
	hShellProcess = wenforce(OpenProcess(PROCESS_QUERY_INFORMATION, FALSE, dwPID), "Can't open desktop shell process");
	scope(exit) CloseHandle(hShellProcess);

	// Get the process token of the desktop shell.
	wenforce(OpenProcessToken(hShellProcess, TOKEN_DUPLICATE, &hShellProcessToken), "Can't get process token of desktop shell");
	scope(exit) CloseHandle(hShellProcessToken);

	// Duplicate the shell's process token to get a primary token.
	// Based on experimentation, this is the minimal set of rights required for CreateProcessWithTokenW (contrary to current documentation).
	const DWORD dwTokenRights = TOKEN_QUERY | TOKEN_ASSIGN_PRIMARY | TOKEN_DUPLICATE | TOKEN_ADJUST_DEFAULT | TOKEN_ADJUST_SESSIONID;
	wenforce(DuplicateTokenEx(hShellProcessToken, dwTokenRights, null, SECURITY_IMPERSONATION_LEVEL.SecurityImpersonation, TOKEN_TYPE.TokenPrimary, &hPrimaryToken), "Can't get primary token");
	scope(exit) CloseHandle(hPrimaryToken);

	CreatedProcess result;

	// Start the target process with the new token.
	wenforce(CreateProcessWithTokenW(
		hPrimaryToken,
		0,
		toWStringz(applicationName), cast(LPWSTR)toWStringz(commandLine),
		0,
		null,
		null,
		&si,
		&result.pi,
	), "CreateProcessWithTokenW failed");

	AllowSetForegroundWindow(result.dwProcessId);
	AttachThreadInput(GetCurrentThreadId(), result.dwThreadId, TRUE);
	AllowSetForegroundWindow(result.dwProcessId);

	return result;
}

// --------------------------------------------------------------------------

mixin(importWin32!q{tlhelp32});

struct ToolhelpSnapshotImpl
{
	HANDLE hSnapshot;

	~this()
	{
		CloseHandle(hSnapshot);
	}
}

alias RefCounted!ToolhelpSnapshotImpl ToolhelpSnapshot;

ToolhelpSnapshot createToolhelpSnapshot(DWORD dwFlags, DWORD th32ProcessID=0)
{
	ToolhelpSnapshot result;
	auto hSnapshot = CreateToolhelp32Snapshot(dwFlags, th32ProcessID);
	wenforce(hSnapshot != INVALID_HANDLE_VALUE, "CreateToolhelp32Snapshot");
	result.hSnapshot = hSnapshot;
	return result;
}

struct ToolhelpIterator(STRUCT, alias FirstFunc, alias NextFunc)
{
private:
	ToolhelpSnapshot snapshot;
	STRUCT s;
	BOOL bSuccess;

	this(ToolhelpSnapshot snapshot)
	{
		this.snapshot = snapshot;
		s.dwSize = STRUCT.sizeof;
		bSuccess = FirstFunc(snapshot.hSnapshot, &s);
	}

public:
	@property
	bool empty() const { return bSuccess == 0; }

	@property
	ref STRUCT front() { return s; }

	void popFront()
	{
		bSuccess = NextFunc(snapshot.hSnapshot, &s);
	}
}

alias ToolhelpIterator!(PROCESSENTRY32, Process32First, Process32Next) ProcessIterator;
@property ProcessIterator processes(ToolhelpSnapshot snapshot) { return ProcessIterator(snapshot); }

alias ToolhelpIterator!(THREADENTRY32, Thread32First, Thread32Next) ThreadIterator;
@property ThreadIterator threads(ToolhelpSnapshot snapshot) { return ThreadIterator(snapshot); }

alias ToolhelpIterator!(MODULEENTRY32, Module32First, Module32Next) ModuleIterator;
@property ModuleIterator modules(ToolhelpSnapshot snapshot) { return ModuleIterator(snapshot); }

alias ToolhelpIterator!(HEAPLIST32, Heap32ListFirst, Heap32ListNext) HeapIterator;
@property HeapIterator heaps(ToolhelpSnapshot snapshot) { return HeapIterator(snapshot); }

// --------------------------------------------------------------------------

struct ProcessWatcher
{
	PROCESSENTRY32[DWORD] oldProcesses;

	void update(void delegate(ref PROCESSENTRY32) oldHandler, void delegate(ref PROCESSENTRY32) newHandler, bool handleExisting = false)
	{
		PROCESSENTRY32[DWORD] newProcesses;
		foreach (ref process; createToolhelpSnapshot(TH32CS_SNAPPROCESS).processes)
			newProcesses[process.th32ProcessID] = process;

		if (oldProcesses || handleExisting) // Skip calling delegates on first run
		{
			if (oldHandler)
				foreach (pid, ref process; oldProcesses)
					if (pid !in newProcesses)
						oldHandler(process);

			if (newHandler)
				foreach (pid, ref process; newProcesses)
					if (pid !in oldProcesses)
						newHandler(process);
		}

		oldProcesses = newProcesses;
	}
}

} // _WIN32_WINNT >= 0x500

// ***************************************************************************

alias ubyte* RemoteAddress;

void readProcessMemory(HANDLE h, RemoteAddress addr, void[] data)
{
	size_t c;
	wenforce(ReadProcessMemory(h, addr, data.ptr, data.length, &c), "ReadProcessMemory");
	enforce(c==data.length, "Not all data read");
}

void writeProcessMemory(HANDLE h, RemoteAddress addr, const(void)[] data)
{
	size_t c;
	wenforce(WriteProcessMemory(h, addr, data.ptr, data.length, &c), "WriteProcessMemory");
	enforce(c==data.length, "Not all data written");
}

void readProcessVar(T)(HANDLE h, RemoteAddress addr, T* v)
{
	h.readProcessMemory(addr, v[0..1]);
}

T readProcessVar(T)(HANDLE h, RemoteAddress addr)
{
	T v;
	h.readProcessVar(addr, &v);
	return v;
}

void writeProcessVar(T)(HANDLE h, RemoteAddress addr, auto ref T v)
{
	h.writeProcessMemory(addr, (&v)[0..1]);
}

struct RemoteProcessVarImpl(T)
{
	T local;
	@property T* localPtr() { return &local; }
	RemoteAddress remotePtr;
	HANDLE hProcess;

	this(HANDLE hProcess)
	{
		this.hProcess = hProcess;
		remotePtr = cast(RemoteAddress)wenforce(VirtualAllocEx(hProcess, null, T.sizeof, MEM_COMMIT, PAGE_READWRITE));
	}

	void read()
	{
		readProcessMemory (hProcess, remotePtr, localPtr[0..1]);
	}

	void write()
	{
		writeProcessMemory(hProcess, remotePtr, localPtr[0..1]);
	}

	~this()
	{
		VirtualFreeEx(hProcess, remotePtr, 0, MEM_RELEASE);
	}
}

/// Binding to a variable located in another process.
/// Automatically allocates and deallocates remote memory.
/// Use .read() and .write() to update local/remote data.
template RemoteProcessVar(T)
{
	alias RefCounted!(RemoteProcessVarImpl!T) RemoteProcessVar;
}
