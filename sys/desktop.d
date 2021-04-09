/**
 * OS-specific desktop stuff.
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

module ae.sys.desktop;

// Really just one stray function... though clipboard stuff could go here too

version (Windows)
{
	import ae.sys.windows.imports;
	mixin(importWin32!q{winuser});

	pragma(lib, "user32");

	/// Get the desktop resolution.
	void getDesktopResolution(out uint x, out uint y)
	{
		x = GetSystemMetrics(SM_CXSCREEN);
		y = GetSystemMetrics(SM_CYSCREEN);
	}
}
