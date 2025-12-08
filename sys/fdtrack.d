/**
 * File Descriptor Leak Tracking
 *
 * Debug utility to help identify file descriptor leaks by capturing stack traces
 * when FDs are allocated. When the FD count exceeds a configurable threshold,
 * dumps all allocation stack traces to help identify the source of the leak.
 *
 * Uses the GNU linker's --wrap option to intercept libc calls at link time.
 * Only works on Linux x86-64 with GNU ld or compatible linker.
 *
 * Usage:
 * ---
 * // In your dub.sdl:
 * dependency "ae:fdtrack" version="*"
 * debugVersions "AE_DEBUG_FD_LEAK"
 * ---
 *
 * The ae:fdtrack subpackage is a sourceLibrary that compiles the wrapper
 * functions directly into your executable and automatically adds the required
 * --wrap linker flags.
 *
 * Set the AE_DEBUG_FD_LEAK_THRESHOLD environment variable to configure the
 * threshold (default: 1000).
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
module ae.sys.fdtrack;

debug (AE_DEBUG_FD_LEAK):

version (linux) version (X86_64):

private:

// Stack trace type from druntime - declared without @nogc to allow use in hooks
extern (C) Throwable.TraceInfo _d_traceContext(void* ptr = null) nothrow;

/// Captures the current stack trace.
Throwable.TraceInfo captureStackTrace() nothrow
{
    return _d_traceContext();
}

/// Prints a captured stack trace to stderr.
void printStackTrace(Throwable.TraceInfo info)
{
    import core.stdc.stdio : stderr, fprintf;

    assert(info !is null);

    try
        foreach (line; info)
            fprintf(stderr, "  %.*s\n", cast(int) line.length, line.ptr);
    catch (Throwable)
        fprintf(stderr, "  (error printing stack trace)\n");
}

// ------------------------------------------------------------------------
// FD Tracking Storage
// ------------------------------------------------------------------------

__gshared size_t threshold = 1000;
__gshared bool thresholdExceeded = false;
__gshared Throwable.TraceInfo[] fdTraces;

shared static this()
{
    import core.stdc.stdlib : getenv, atoi, calloc;

    if (auto env = getenv("AE_DEBUG_FD_LEAK_THRESHOLD"))
    {
        int val = atoi(env);
        if (val > 0)
            threshold = val;
    }

    // Allocate trace storage - we only need to track up to threshold FDs
    if (auto mem = cast(Throwable.TraceInfo*) calloc(threshold, (Throwable.TraceInfo).sizeof))
        fdTraces = mem[0 .. threshold];
}

void trackFd(int fd) nothrow
{
    if (fd < 0)
        return;

    if (fd < fdTraces.length)
        fdTraces[fd] = captureStackTrace();

    // Trigger dump when threshold exceeded (fd number reaches threshold)
    if (!thresholdExceeded && fd >= threshold)
    {
        import core.atomic : atomicExchange;

        if (!atomicExchange(&thresholdExceeded, true))
        {
            try
                dumpAllFds(fd, true);
            catch (Throwable)
            {
            }
        }
    }
}

void untrackFd(int fd) nothrow
{
    if (fd < 0)
        return;

    if (fd < fdTraces.length)
        fdTraces[fd] = null;
}

void dumpAllFds(int triggeringFd, bool exceeded)
{
    import core.stdc.stdio : stderr, fprintf;

    fprintf(stderr, "\n");
    fprintf(stderr, "============================================================\n");
    if (exceeded)
    {
        fprintf(stderr, "AE_DEBUG_FD_LEAK: Threshold exceeded (threshold: %zu)\n", threshold);
        fprintf(stderr, "Triggering FD: %d\n", triggeringFd);
    }
    else
    {
        fprintf(stderr, "AE_DEBUG_FD_LEAK: Dump requested (threshold: %zu)\n", threshold);
    }
    fprintf(stderr, "============================================================\n\n");

    fprintf(stderr, "Allocation stack traces for all tracked FDs:\n\n");

    size_t printed = 0;
    foreach (fd, trace; fdTraces)
    {
        if (trace !is null)
        {
            fprintf(stderr, "--- FD %zu ---\n", fd);
            printStackTrace(trace);
            fprintf(stderr, "\n");
            printed++;
        }
    }

    fprintf(stderr, "============================================================\n");
    fprintf(stderr, "Total FDs with traces: %zu\n", printed);
    fprintf(stderr, "============================================================\n\n");
}

// ------------------------------------------------------------------------
// Original function declarations (provided by linker via __real_*)
// ------------------------------------------------------------------------

import core.stdc.stdio : FILE, fileno;
import core.sys.posix.dirent : DIR;

extern (C) nothrow
{
    int __real_open(const char* pathname, int flags, uint mode);
    int __real_open64(const char* pathname, int flags, uint mode);
    int __real_openat(int dirfd, const char* pathname, int flags, uint mode);
    int __real_openat64(int dirfd, const char* pathname, int flags, uint mode);
    int __real_creat(const char* pathname, uint mode);
    int __real_creat64(const char* pathname, uint mode);
    FILE* __real_fopen(const char* pathname, const char* mode);
    FILE* __real_fopen64(const char* pathname, const char* mode);
    FILE* __real_freopen(const char* pathname, const char* mode, FILE* stream);
    FILE* __real_freopen64(const char* pathname, const char* mode, FILE* stream);
    int __real_fclose(FILE* stream);
    DIR* __real_opendir(const char* name);
    DIR* __real_fdopendir(int fd);
    int __real_closedir(DIR* dirp);
    int dirfd(DIR* dirp); // not in druntime
    int __real_socket(int domain, int type, int protocol);
    int __real_close(int fd);
    int __real_accept(int sockfd, void* addr, uint* addrlen);
    int __real_accept4(int sockfd, void* addr, uint* addrlen, int flags);
    int __real_pipe(int* pipefd);
    int __real_pipe2(int* pipefd, int flags);
    int __real_dup(int oldfd);
    int __real_dup2(int oldfd, int newfd);
    int __real_dup3(int oldfd, int newfd, int flags);
    int __real_socketpair(int domain, int type, int protocol, int* sv);
    int __real_epoll_create(int size);
    int __real_epoll_create1(int flags);
    int __real_eventfd(uint initval, int flags);
    int __real_signalfd(int fd, const void* mask, int flags);
    int __real_timerfd_create(int clockid, int flags);
    int __real_inotify_init();
    int __real_inotify_init1(int flags);
}

// ------------------------------------------------------------------------
// Wrapped Functions (called by linker instead of originals)
// ------------------------------------------------------------------------

extern (C) int __wrap_open(const char* pathname, int flags, uint mode) nothrow
{
    int fd = __real_open(pathname, flags, mode);
    trackFd(fd);
    return fd;
}

extern (C) int __wrap_open64(const char* pathname, int flags, uint mode) nothrow
{
    int fd = __real_open64(pathname, flags, mode);
    trackFd(fd);
    return fd;
}

extern (C) int __wrap_openat(int dirfd, const char* pathname, int flags, uint mode) nothrow
{
    int fd = __real_openat(dirfd, pathname, flags, mode);
    trackFd(fd);
    return fd;
}

extern (C) int __wrap_openat64(int dirfd, const char* pathname, int flags, uint mode) nothrow
{
    int fd = __real_openat64(dirfd, pathname, flags, mode);
    trackFd(fd);
    return fd;
}

extern (C) int __wrap_creat(const char* pathname, uint mode) nothrow
{
    int fd = __real_creat(pathname, mode);
    trackFd(fd);
    return fd;
}

extern (C) int __wrap_creat64(const char* pathname, uint mode) nothrow
{
    int fd = __real_creat64(pathname, mode);
    trackFd(fd);
    return fd;
}

extern (C) FILE* __wrap_fopen(const char* pathname, const char* mode) nothrow
{
    FILE* f = __real_fopen(pathname, mode);
    if (f !is null)
        trackFd(fileno(f));
    return f;
}

extern (C) FILE* __wrap_fopen64(const char* pathname, const char* mode) nothrow
{
    FILE* f = __real_fopen64(pathname, mode);
    if (f !is null)
        trackFd(fileno(f));
    return f;
}

extern (C) FILE* __wrap_freopen(const char* pathname, const char* mode, FILE* stream) nothrow
{
    if (stream !is null)
        untrackFd(fileno(stream));
    FILE* f = __real_freopen(pathname, mode, stream);
    if (f !is null)
        trackFd(fileno(f));
    return f;
}

extern (C) FILE* __wrap_freopen64(const char* pathname, const char* mode, FILE* stream) nothrow
{
    if (stream !is null)
        untrackFd(fileno(stream));
    FILE* f = __real_freopen64(pathname, mode, stream);
    if (f !is null)
        trackFd(fileno(f));
    return f;
}

extern (C) int __wrap_fclose(FILE* stream) nothrow
{
    if (stream !is null)
        untrackFd(fileno(stream));
    return __real_fclose(stream);
}

extern (C) DIR* __wrap_opendir(const char* name) nothrow
{
    DIR* d = __real_opendir(name);
    if (d !is null)
        trackFd(dirfd(d));
    return d;
}

extern (C) DIR* __wrap_fdopendir(int fd) nothrow
{
    // fdopendir takes ownership of fd, so it's already tracked
    return __real_fdopendir(fd);
}

extern (C) int __wrap_closedir(DIR* dirp) nothrow
{
    if (dirp !is null)
        untrackFd(dirfd(dirp));
    return __real_closedir(dirp);
}

extern (C) int __wrap_socket(int domain, int type, int protocol) nothrow
{
    int fd = __real_socket(domain, type, protocol);
    trackFd(fd);
    return fd;
}

extern (C) int __wrap_close(int fd) nothrow
{
    untrackFd(fd);
    return __real_close(fd);
}

extern (C) int __wrap_accept(int sockfd, void* addr, uint* addrlen) nothrow
{
    int fd = __real_accept(sockfd, addr, addrlen);
    trackFd(fd);
    return fd;
}

extern (C) int __wrap_accept4(int sockfd, void* addr, uint* addrlen, int flags) nothrow
{
    int fd = __real_accept4(sockfd, addr, addrlen, flags);
    trackFd(fd);
    return fd;
}

extern (C) int __wrap_pipe(int* pipefd) nothrow
{
    int ret = __real_pipe(pipefd);
    if (ret == 0)
    {
        trackFd(pipefd[0]);
        trackFd(pipefd[1]);
    }
    return ret;
}

extern (C) int __wrap_pipe2(int* pipefd, int flags) nothrow
{
    int ret = __real_pipe2(pipefd, flags);
    if (ret == 0)
    {
        trackFd(pipefd[0]);
        trackFd(pipefd[1]);
    }
    return ret;
}

extern (C) int __wrap_dup(int oldfd) nothrow
{
    int fd = __real_dup(oldfd);
    trackFd(fd);
    return fd;
}

extern (C) int __wrap_dup2(int oldfd, int newfd) nothrow
{
    untrackFd(newfd);
    int fd = __real_dup2(oldfd, newfd);
    if (fd >= 0)
        trackFd(fd);
    return fd;
}

extern (C) int __wrap_dup3(int oldfd, int newfd, int flags) nothrow
{
    untrackFd(newfd);
    int fd = __real_dup3(oldfd, newfd, flags);
    if (fd >= 0)
        trackFd(fd);
    return fd;
}

extern (C) int __wrap_socketpair(int domain, int type, int protocol, int* sv) nothrow
{
    int ret = __real_socketpair(domain, type, protocol, sv);
    if (ret == 0)
    {
        trackFd(sv[0]);
        trackFd(sv[1]);
    }
    return ret;
}

extern (C) int __wrap_epoll_create(int size) nothrow
{
    int fd = __real_epoll_create(size);
    trackFd(fd);
    return fd;
}

extern (C) int __wrap_epoll_create1(int flags) nothrow
{
    int fd = __real_epoll_create1(flags);
    trackFd(fd);
    return fd;
}

extern (C) int __wrap_eventfd(uint initval, int flags) nothrow
{
    int fd = __real_eventfd(initval, flags);
    trackFd(fd);
    return fd;
}

extern (C) int __wrap_signalfd(int fd, const void* mask, int flags) nothrow
{
    int newfd = __real_signalfd(fd, mask, flags);
    if (fd == -1 && newfd >= 0)
    {
        trackFd(newfd);
    }
    return newfd;
}

extern (C) int __wrap_timerfd_create(int clockid, int flags) nothrow
{
    int fd = __real_timerfd_create(clockid, flags);
    trackFd(fd);
    return fd;
}

extern (C) int __wrap_inotify_init() nothrow
{
    int fd = __real_inotify_init();
    trackFd(fd);
    return fd;
}

extern (C) int __wrap_inotify_init1(int flags) nothrow
{
    int fd = __real_inotify_init1(flags);
    trackFd(fd);
    return fd;
}

// ------------------------------------------------------------------------
// Public API
// ------------------------------------------------------------------------

public:

/// Manually dump all tracked FDs
void dumpTrackedFds()
{
    dumpAllFds(-1, false);
}

/// Get current count of tracked FDs
size_t getTrackedFdCount() nothrow
{
    size_t count = 0;
    foreach (trace; fdTraces)
        if (trace !is null)
            count++;
    return count;
}

/// Check if threshold has been exceeded
bool hasExceededThreshold() nothrow
{
    return thresholdExceeded;
}
