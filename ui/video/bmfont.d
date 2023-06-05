/**
 * Rendering for simple bitmap fonts.
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

module ae.ui.video.bmfont;

import ae.ui.video.renderer;
import ae.utils.array;
import ae.utils.graphics.fonts.draw;

/// Adapter from a font (as in `ae.utils.graphics.fonts`)
/// and `ProceduralTextureSource` .
final class FontTextureSource(Font) : ProceduralTextureSource
{
	this(Font font, Renderer.COLOR color)
	{
		this.font = font;
		this.color = color;
	} ///

	/// Draw a string.
	void drawText(S)(Renderer r, int x, int y, S s)
	{
		foreach (c; s)
		{
			if (font.hasGlyph(c))
			{
				auto g = font.getGlyph(c);
				auto v = c * font.height;
				r.draw(x, y, this, 0, v, g.width, v + font.height);
				x += g.width;
			}
		}
	}

protected:
	Font font;
	Renderer.COLOR color;

	override void getSize(out int width, out int height)
	{
		width = font.maxWidth;
		height = font.maxGlyph * font.height;
	}

	override void drawTo(TextureCanvas dest)
	{
		foreach (g; 0..font.maxGlyph)
		{
			dchar c = g;
			dest.drawText(0, g * font.height, c.asSlice, font, color);
		}
	}
}

unittest
{
	// Test instantiation
	if (false)
	{
		Renderer r;
		import ae.utils.graphics.fonts.font8x8;
		FontTextureSource!Font8x8 f;
		f.drawText(r, 0, 0, "foo");
	}
}
