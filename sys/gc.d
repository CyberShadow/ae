/**
 * Low-level GC interaction code.
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

module ae.sys.gc;

/// Warning: This structure is currently internal, and may change arbitrarily.
struct GCStats
{
    size_t poolsize;        // total size of pool
    size_t usedsize;        // bytes allocated
    size_t freeblocks;      // number of blocks marked FREE
    size_t freelistsize;    // total of memory on free lists
    size_t pageblocks;      // number of blocks marked PAGE
}

/// Warning: This function is currently internal, and may change arbitrarily.
extern (C) GCStats gc_stats();

void GC_getStats(ref GCStats stats)
{
	stats = gc_stats();
}
