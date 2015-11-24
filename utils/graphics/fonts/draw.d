/**
 * Draw a bitmap font.
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

module ae.utils.graphics.fonts.draw;

import ae.utils.graphics.draw;
import ae.utils.graphics.view;

/// Draw text using a bitmap font.
void drawText(V, FONT, S, COLOR)(auto ref V v, int x, int y, S s, ref FONT font, COLOR color) @nogc
	if (isWritableView!V && is(COLOR : ViewColor!V))
{
	auto x0 = x;
	foreach (c; s)
	{
		if (c == '\r')
			x = x0;
		else
		if (c == '\n')
		{
			x = x0;
			y += font.height;
		}
		else
		{
			auto glyph = font.getGlyph(font.hasGlyph(c) ? c : ' ');
			foreach (cy; 0..font.height)
				foreach (cx; 0..glyph.width)
					if (glyph.rows[cy] & (1 << cx))
						v.safePut(x+cx, y+cy, color);
			x += glyph.width;
		}
	}
}

version(unittest)
{
	import ae.utils.graphics.image;
	import ae.utils.graphics.fonts.font8x8;
}

unittest
{
	auto v = Image!ubyte(100, 8);
	v.drawText(0, 0, "Hello World!", font8x8, ubyte(255));
	//v.toPNG.toFile("test.png");
}
