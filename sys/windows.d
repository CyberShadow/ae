/**
 * Various wrapper and utility code for the Windows API.
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

module ae.sys.windows;

import std.exception;
import std.string;
import std.typecons;
import std.utf;

import win32.windows;

string fromWString(in wchar[] buf)
{
	foreach (i, c; buf)
		if (!c)
			return toUTF8(buf[0..i]);
	return toUTF8(buf);
}

string fromWString(in wchar* buf)
{
	const(wchar)* p = buf;
	for (; *p; p++) {}
	return toUTF8(buf[0..p-buf]);
}

LPCWSTR toWStringz(string s)
{
	return s is null ? null : toUTF16z(s);
}

LARGE_INTEGER largeInteger(long n)
{
	LARGE_INTEGER li; li.QuadPart = n; return li;
}

ULARGE_INTEGER ulargeInteger(ulong n)
{
	ULARGE_INTEGER li; li.QuadPart = n; return li;
}

ulong makeUlong(DWORD dwLow, DWORD dwHigh)
{
	ULARGE_INTEGER li;
	li.LowPart  = dwLow;
	li.HighPart = dwHigh;
	return li.QuadPart;
}

// --------------------------------------------------------------------------

class WindowsException : Exception
{
	DWORD code;

	this(DWORD code, string str=null)
	{
		this.code = code;

		wchar *lpMsgBuf = null;
		FormatMessageW(
			FORMAT_MESSAGE_ALLOCATE_BUFFER | FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS,
			null,
			code,
			MAKELANGID(LANG_NEUTRAL, SUBLANG_DEFAULT),
			cast(LPWSTR)&lpMsgBuf,
			0,
			null);

		auto message = lpMsgBuf.fromWString();
		if (lpMsgBuf)
			LocalFree(lpMsgBuf);

		message = strip(message);
		message ~= format(" (error %d)", code);
		if (str)
			message = str ~ ": " ~ message;

		super(message);
	}
}

T wenforce(T)(T cond, string str=null)
{
	if (cond)
		return cond;

	throw new WindowsException(GetLastError(), str);
}

void sendCopyData(HWND hWnd, DWORD n, in void[] buf)
{
	COPYDATASTRUCT cds;
	cds.dwData = n;
	cds.cbData = cast(uint)buf.length;
	cds.lpData = cast(PVOID)buf.ptr;
	SendMessage(hWnd, WM_COPYDATA, 0, cast(LPARAM)&cds);
}

enum MAPVK_VK_TO_VSC = 0;

void keyDown(ubyte c) { keybd_event(c, cast(ubyte)MapVirtualKey(c, MAPVK_VK_TO_VSC), 0              , 0); }
void keyUp  (ubyte c) { keybd_event(c, cast(ubyte)MapVirtualKey(c, MAPVK_VK_TO_VSC), KEYEVENTF_KEYUP, 0); }

void press(ubyte c, uint delay=0)
{
	if (c) keyDown(c);
	Sleep(delay);
	if (c) keyUp(c);
	Sleep(delay);
}

void keyDownOn(HWND h, ubyte c) { PostMessage(h, WM_KEYDOWN, c, MapVirtualKey(c, MAPVK_VK_TO_VSC) << 16); }
void keyUpOn  (HWND h, ubyte c) { PostMessage(h, WM_KEYUP  , c, MapVirtualKey(c, MAPVK_VK_TO_VSC) << 16); }

void pressOn(HWND h, ubyte c, uint delay=0)
{
	if (c) keyDownOn(h, c);
	Sleep(delay);
	if (c) keyUpOn(h, c);
	Sleep(delay);
}

// Messages

void processWindowsMessages()
{
	MSG m;
	while (PeekMessageW(&m, null, 0, 0, PM_REMOVE))
	{
		TranslateMessage(&m);
		DispatchMessageW(&m);
	}
}

void messageLoop()
{
	MSG m;
	while (GetMessageW(&m, null, 0, 0))
	{
		TranslateMessage(&m);
		DispatchMessageW(&m);
	}
}

// Windows

import std.range;

struct WindowIterator
{
private:
	LPCWSTR szClassName, szWindowName;
	HWND hParent, h;

public:
	@property
	bool empty() const { return h is null; }

	@property
	HWND front() const { return cast(HWND)h; }

	void popFront()
	{
		h = FindWindowExW(hParent, h, szClassName, szWindowName);
	}
}

WindowIterator windowIterator(string szClassName, string szWindowName, HWND hParent=null)
{
	auto iterator = WindowIterator(toWStringz(szClassName), toWStringz(szWindowName), hParent);
	iterator.popFront(); // initiate search
	return iterator;
}

private static wchar[0xFFFF] textBuf;

string windowStringQuery(alias FUNC)(HWND h)
{
	SetLastError(0);
	auto result = FUNC(h, textBuf.ptr, textBuf.length);
	if (result)
		return textBuf[0..result].toUTF8();
	else
	{
		auto code = GetLastError();
		if (code)
			throw new WindowsException(code, __traits(identifier, FUNC));
		else
			return null;
	}
}

alias windowStringQuery!GetClassNameW  getClassName;
alias windowStringQuery!GetWindowTextW getWindowText;

/// Create an utility hidden window.
HWND createHiddenWindow(string name, WNDPROC proc)
{
	auto szName = toWStringz(name);

	HINSTANCE hInstance = GetModuleHandle(null);

	WNDCLASSEXW wcx;

	wcx.cbSize = wcx.sizeof;
	wcx.lpfnWndProc = proc;
	wcx.hInstance = hInstance;
	wcx.lpszClassName = szName;
	wenforce(RegisterClassExW(&wcx), "RegisterClassEx failed");

	HWND hWnd = CreateWindowW(
		szName,              // name of window class
		szName,              // title-bar string
		WS_OVERLAPPEDWINDOW, // top-level window
		CW_USEDEFAULT,       // default horizontal position
		CW_USEDEFAULT,       // default vertical position
		CW_USEDEFAULT,       // default width
		CW_USEDEFAULT,       // default height
		null,                // no owner window
		null,                // use class menu
		hInstance,           // handle to application instance
		null);               // no window-creation data
	wenforce(hWnd, "CreateWindow failed");

	return hWnd;
}

// Processes

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
	CreatedProcess result;
	wenforce(CreateProcessW(toWStringz(applicationName), cast(LPWSTR)toWStringz(commandLine), null, null, false, 0, null, null, &si, &result.pi), "CreateProcess");
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
	LookupPrivilegeValueW(null, SE_INCREASE_QUOTA_NAME.ptr, &tkp.Privileges()[0].Luid);
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

import win32.tlhelp32;

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

// --------------------------------------------------------------------------

} // _WIN32_WINNT >= 0x500

int messageBox(string message, string title, int style=0)
{
	return MessageBoxW(null, toWStringz(message), toWStringz(title), style);
}

uint getLastInputInfo()
{
	LASTINPUTINFO lii = { LASTINPUTINFO.sizeof };
	wenforce(GetLastInputInfo(&lii), "GetLastInputInfo");
	return lii.dwTime;
}

// ---------------------------------------

import std.traits;

/// Given a static function declaration, generate a loader with the same name in the current scope
/// that loads the function dynamically from the given DLL.
mixin template DynamicLoad(alias F, string DLL, string NAME=__traits(identifier, F))
{
	static ReturnType!F loader(ARGS...)(ARGS args)
	{
		import win32.windef;

		alias typeof(&F) FP;
		static FP fp = null;
		if (!fp)
		{
			HMODULE dll = wenforce(LoadLibrary(DLL), "LoadLibrary");
			fp = cast(FP)wenforce(GetProcAddress(dll, NAME), "GetProcAddress");
		}
		return fp(args);
	}

	mixin(`alias loader!(ParameterTypeTuple!F) ` ~ NAME ~ `;`);
}

///
unittest
{
	mixin DynamicLoad!(GetVersion, "kernel32.dll");
	GetVersion(); // called via GetProcAddress
}

// ---------------------------------------

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
