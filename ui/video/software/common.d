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
 * Portions created by the Initial Developer are Copyright (C) 2012
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

module ae.ui.video.software.common;

/// Mixin implementing Renderer methods using Canvas.
/// Mixin context: "bitmap" must return a Canvas-like object.
mixin template SoftwareRenderer()
{
	override void putPixel(int x, int y, COLOR color)
	{
		bitmap.safePut(x, y, color);
	}

	override void putPixels(Pixel[] pixels)
	{
		foreach (ref pixel; pixels)
			bitmap.safePut(pixel.x, pixel.y, pixel.color);
	}

	override void fillRect(int x0, int y0, int x1, int y1, COLOR color)
	{
		bitmap.fillRect(x0, y0, x1, y1, color);
	}

	override void fillRect(float x0, float y0, float x1, float y1, COLOR color)
	{
		bitmap.aaFillRect(x0, y0, x1, y1, color);
	}

	override void clear()
	{
		bitmap.clear(COLOR.init);
	}

	override void draw(int x, int y, TextureSource source, int u0, int v0, int u1, int v1)
	{
		auto w = bitmap.window(x, y, x+(u1-u0), y+(v1-v0));
		source.drawTo(w);
	}

	override void draw(float x0, float y0, float x1, float y1, TextureSource source, int u0, int v0, int u1, int v1)
	{
		// assert(0, "TODO");
	}
}
