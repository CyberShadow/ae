/**
 * Demonstrates the AE_DEBUG_FD_LEAK feature.
 *
 * This demo shows how to diagnose file descriptor leaks by capturing
 * stack traces when FDs are allocated. When the number of open FDs
 * exceeds a configurable threshold, the debug machinery prints all
 * allocation stack traces to help identify the source of the leak.
 *
 * The demo creates various types of file descriptors, intentionally
 * "forgetting" to close them. When the threshold is exceeded, the
 * debug output shows where each FD was allocated.
 *
 * Usage:
 *   dub build && AE_DEBUG_FD_LEAK_THRESHOLD=5 ./ae-demo-debug-fd-leak
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

module ae.demo.demo_fd_leak.demo_fd_leak;

import std.stdio;

import ae.sys.fdtrack;

void main()
{
    writeln("=== FD Leak Tracking Demo ===");
    writeln();
    writeln("This demo illustrates the AE_DEBUG_FD_LEAK feature.");
    writeln("It creates various types of FDs but intentionally doesn't close them,");
    writeln("simulating file descriptor leaks.");
    writeln();

    import std.process : environment;
    auto threshold = environment.get("AE_DEBUG_FD_LEAK_THRESHOLD", "1000");
    writeln("Current FD threshold: ", threshold);
    writeln("(Set AE_DEBUG_FD_LEAK_THRESHOLD environment variable to change)");
    writeln();

    writeln("Initial tracked FD count: ", getTrackedFdCount());
    writeln();

    writeln("Creating various types of file descriptors...");
    writeln();

    // Different types of FD leaks
    leakSockets(3);
    leakFiles(3);
    leakPipes(2);
    leakSocketPairs(2);
    leakEventFds(2);

    writeln();
    writeln("Final tracked FD count: ", getTrackedFdCount());
    writeln("Threshold exceeded: ", hasExceededThreshold());
    writeln();

    if (!hasExceededThreshold())
    {
        writeln("Threshold was not exceeded. Manually dumping FDs:");
        writeln();
        dumpTrackedFds();
    }

    writeln();
    writeln("Demo complete.");
    writeln();
    writeln("In the stack traces above, you can see exactly where each");
    writeln("file descriptor was allocated, making it easy to identify");
    writeln("and fix the leak.");
}

/// Leak sockets (via std.socket)
void leakSockets(int count)
{
    import std.socket : TcpSocket;

    writeln("  Leaking ", count, " sockets (std.socket.TcpSocket)...");
    foreach (i; 0 .. count)
    {
        auto sock = new TcpSocket();
        // Intentionally not closing - this is the leak!
    }
}

/// Leak files (via std.stdio.File)
File*[] leakedFiles; // prevent GC collection
void leakFiles(int count)
{
    import std.file : tempDir;
    import std.path : buildPath;

    writeln("  Leaking ", count, " files (std.stdio.File)...");
    foreach (i; 0 .. count)
    {
        auto path = buildPath(tempDir(), "fdtrack_demo_temp");
        auto f = new File(path, "w");
        leakedFiles ~= f; // prevent GC from closing
        // Intentionally not closing - this is the leak!
    }
}

/// Leak pipes
void leakPipes(int count)
{
    import core.sys.posix.unistd : pipe;

    writeln("  Leaking ", count, " pipes (", count * 2, " FDs)...");
    foreach (i; 0 .. count)
    {
        int[2] pipefd;
        if (pipe(pipefd) == 0)
        {
            // Intentionally not closing - this is the leak!
        }
    }
}

/// Leak socket pairs
void leakSocketPairs(int count)
{
    import core.sys.posix.sys.socket : socketpair, AF_UNIX, SOCK_STREAM;

    writeln("  Leaking ", count, " socket pairs (", count * 2, " FDs)...");
    foreach (i; 0 .. count)
    {
        int[2] sv;
        if (socketpair(AF_UNIX, SOCK_STREAM, 0, sv) == 0)
        {
            // Intentionally not closing - this is the leak!
        }
    }
}

/// Leak eventfds
void leakEventFds(int count)
{
    import core.sys.linux.sys.eventfd : eventfd;

    writeln("  Leaking ", count, " eventfds...");
    foreach (i; 0 .. count)
    {
        int fd = eventfd(0, 0);
        // Intentionally not closing - this is the leak!
    }
}
