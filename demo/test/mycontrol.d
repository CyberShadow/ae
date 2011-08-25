/* ***** BEGIN LICENSE BLOCK *****
 * Version: MPL 1.1/GPL 3.0
 *
 * The contents of this file are subject to the Mozilla Public License Version
 * 1.1 (the "License"); you may not use this file except in compliance with
 * the License. You may obtain a copy of the License at
 * http://www.mozilla.org/MPL/
 *
 * Software distributed under the License is distributed on an "AS IS" basis,
 * WITHOUT WARRANTY OF ANY KIND, either express or implied. See the License
 * for the specific language governing rights and limitations under the
 * License.
 *
 * The Original Code is the ArmageddonEngine library.
 *
 * The Initial Developer of the Original Code is
 * Vladimir Panteleev <vladimir@thecybershadow.net>
 * Portions created by the Initial Developer are Copyright (C) 2011
 * the Initial Developer. All Rights Reserved.
 *
 * Contributor(s):
 *
 * Alternatively, the contents of this file may be used under the terms of the
 * GNU General Public License Version 3 (the "GPL") or later, in which case
 * the provisions of the GPL are applicable instead of those above. If you
 * wish to allow use of your version of this file only under the terms of the
 * GPL, and not to allow others to use your version of this file under the
 * terms of the MPL, indicate your decision by deleting the provisions above
 * and replace them with the notice and other provisions required by the GPL.
 * If you do not delete the provisions above, a recipient may use your version
 * of this file under the terms of either the MPL or the GPL.
 *
 * ***** END LICENSE BLOCK ***** */

module demo.test.mycontrol;

import ae.shell.shell;
import ae.shell.events;
import ae.video.surface;
import ae.wm.controls.control;
import std.conv;

import std.random;

class MyControl : Control
{
	this()
	{
		w = 800;
		h = 600;
	}

	struct Coord { uint x, y, c; void* dummy; }
	Coord[] coords;

	override void handleMouseMove(uint x, uint y, MouseButtons buttons)
	{
		if (buttons)
		{
			uint b = cast(uint)buttons;
			b = (b&1)|((b&2)<<7)|((b&4)<<14);
			b |= b<<4;
			b |= b<<2;
			b |= b<<1;
			coords ~= Coord(x, y, b);
		}
	}

	override void render(Surface s, int x, int y)
	{
		foreach (i; 0..100)
			coords ~= Coord(uniform(0, w), uniform(0, h), uniform(0, 0x1_00_00_00));
		shell.setCaption(to!string(coords.length));

		auto b = s.lock();
		foreach (coord; coords)
			b[coord.x, coord.y] = coord.c;
		s.unlock();
	}
}

