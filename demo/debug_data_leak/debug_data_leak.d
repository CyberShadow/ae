/**
 * Demonstrates the AE_DEBUG_DATA_LEAK feature.
 *
 * This demo shows how to diagnose Data memory leaks by capturing stack traces
 * when Data objects are allocated. The debug machinery tracks all live
 * allocations and can dump them grouped by allocation site.
 *
 * The demo creates various Data allocations from different call sites,
 * then dumps all live allocations to show how they are grouped by
 * stack trace, making it easy to identify where memory is being held.
 *
 * In real usage, the dump is automatically triggered when an out-of-memory
 * condition occurs, helping identify what's consuming all the memory.
 *
 * Usage:
 *   dub run
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

module ae.demo.debug_data_leak.debug_data_leak;

import std.stdio;

import ae.sys.data;

// Keep references to prevent deallocation
Data[] leakedData;

void main()
{
    writeln("=== Data Leak Tracking Demo ===");
    writeln();
    writeln("This demo illustrates the AE_DEBUG_DATA_LEAK feature.");
    writeln("It creates Data allocations from different call sites and shows");
    writeln("how they are grouped by stack trace in the debug output.");
    writeln();

    writeln("Creating Data allocations from different call sites...");
    writeln();

    // Create allocations from different functions to show grouping
    allocateNetworkBuffers(3);
    allocateFileBuffers(2);
    allocateTemporaryBuffers(5);
    allocateInLoop(4, 512);

    writeln();
    writeln("Total allocations held: ", leakedData.length);
    writeln();

    debug (AE_DEBUG_DATA_LEAK)
    {
        writeln("Dumping all live Data allocations:");
        writeln("(In real usage, this dump occurs automatically on out-of-memory)");
        writeln();
        stderr.flush();
        stdout.flush();
        dumpDataAllocations();
    }
    else
    {
        writeln("AE_DEBUG_DATA_LEAK not enabled.");
        writeln("Run with: dub run --debug=AE_DEBUG_DATA_LEAK");
    }

    writeln();
    writeln("Demo complete.");
    writeln();
    writeln("In the output above, allocations are grouped by stack trace.");
    writeln("Each group shows the total bytes and count of allocations from");
    writeln("that call site, making it easy to identify memory hotspots.");
}

/// Simulates allocating network receive buffers
void allocateNetworkBuffers(int count)
{
    writeln("  Allocating ", count, " network buffers (4KB each)...");
    foreach (i; 0 .. count)
        leakedData ~= Data(4096);
}

/// Simulates allocating file read buffers
void allocateFileBuffers(int count)
{
    writeln("  Allocating ", count, " file buffers (8KB each)...");
    foreach (i; 0 .. count)
        leakedData ~= Data(8192);
}

/// Simulates allocating temporary processing buffers
void allocateTemporaryBuffers(int count)
{
    writeln("  Allocating ", count, " temporary buffers (1KB each)...");
    foreach (i; 0 .. count)
        leakedData ~= Data(1024);
}

/// Simulates allocating buffers in a loop with a helper
void allocateInLoop(int count, size_t size)
{
    writeln("  Allocating ", count, " buffers of ", size, " bytes in a loop...");
    foreach (i; 0 .. count)
        leakedData ~= allocateSingleBuffer(size);
}

/// Helper function - allocations here will have a different stack trace
Data allocateSingleBuffer(size_t size)
{
    return Data(size);
}
