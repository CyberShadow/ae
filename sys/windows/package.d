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
version (Windows):

public import ae.sys.windows.exception;
public import ae.sys.windows.dll;
public import ae.sys.windows.input;
public import ae.sys.windows.misc;
public import ae.sys.windows.process;
public import ae.sys.windows.text;
public import ae.sys.windows.window;
