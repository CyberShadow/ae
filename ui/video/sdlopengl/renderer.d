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
 * Portions created by the Initial Developer are Copyright (C) 2011-2012
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

module ae.ui.video.sdlopengl.renderer;

import std.exception;

import derelict.sdl.sdl;
import derelict.opengl.gl;
import derelict.opengl.glu;

import ae.ui.video.renderer;
import ae.ui.shell.sdl.shell;
import ae.utils.math;

final class SDLOpenGLRenderer : Renderer
{
	this(uint w, uint h)
	{
		this.w = w;		
		this.h = h;
		this.canFastLock = false;

		glViewport(0, 0, w, h);
		glMatrixMode(GL_PROJECTION);
		glLoadIdentity();
		glOrtho(0, w, h, 0, 0, 1);
		glMatrixMode(GL_MODELVIEW);
		glLoadIdentity();
		glDisable(GL_DEPTH_TEST);
	}

	override Bitmap fastLock()
	{
		assert(false, "Can't fastLock OpenGL");
	}

	override Bitmap lock()
	{
		assert(false, "Not implemented");
	}

	override void unlock()
	{
		assert(false, "Not implemented");
	}

	override void present()
	{
		SDL_GL_SwapBuffers();
		if (TextureRenderData.cleanupNeeded)
			cleanupTextures();
	}

	// **********************************************************************

	private uint w, h;

	override @property uint width()
	{
		return w;
	}

	override @property uint height()
	{
		return h;
	}

	override void putPixel(int x, int y, COLOR color)
	{
		// GL_POINTS is blurry when using multisampling
		fillRect(x, y, x+1, y+1, color);
	}

	override void putPixels(Pixel[] pixels)
	{
		foreach (ref pixel; pixels)
		{
			glColor3ub(pixel.color.r, pixel.color.g, pixel.color.b);
			glRecti(pixel.x, pixel.y, pixel.x+1, pixel.y+1);
		}
	}

	override void fillRect(int x0, int y0, int x1, int y1, COLOR color)
	{
		glColor3ub(color.r, color.g, color.b);
		glRecti(x0, y0, x1, y1);
	}

	override void fillRect(float x0, float y0, float x1, float y1, COLOR color)
	{
		glColor3ub(color.r, color.g, color.b);
		glRectf(x0, y0, x1, y1);
	}

	override void clear()
	{
		glClear(GL_COLOR_BUFFER_BIT);
	}

	// **********************************************************************

	override void draw(int x, int y, TextureSource source, int u0, int v0, int u1, int v1)
	{
		draw(x, y, x+(u1-u0), y+(v1-v0), source, u0, v0, u1, v1);
	}

	override void draw(float x0, float y0, float x1, float y1, TextureSource source, int u0, int v0, int u1, int v1)
	{
		auto data = updateTexture(source);
		glEnable(GL_TEXTURE_2D);
		glColor3ub(255, 255, 255);

		float u0f = cast(float)u0 / data.w;
		float v0f = cast(float)v0 / data.h;
		float u1f = cast(float)u1 / data.w;
		float v1f = cast(float)v1 / data.h;

		glBegin(GL_QUADS);
			glTexCoord2f(u0f, v0f); glVertex2f(x0, y0);
			glTexCoord2f(u1f, v0f); glVertex2f(x1, y0);
			glTexCoord2f(u1f, v1f); glVertex2f(x1, y1);
			glTexCoord2f(u0f, v1f); glVertex2f(x0, y1);
		glEnd();
		glDisable(GL_TEXTURE_2D);
	}

	static if (is(COLOR == BGRX))
	{
		enum TextureFormat = GL_BGRA;
		enum InternalTextureFormat = GL_RGB8;
	}
	else
		static assert(0, "FIXME");

	// also binds unconditionally
	private OpenGLTextureRenderData updateTexture(TextureSource source)
	{
		auto data = cast(OpenGLTextureRenderData) cast(void*) source.renderData[Renderers.SDLOpenGL];
		if (data is null || data.invalid)
		{
			source.renderData[Renderers.SDLOpenGL] = data = new OpenGLTextureRenderData;
			data.next = OpenGLTextureRenderData.head;
			OpenGLTextureRenderData.head = data;
			rebuildTexture(data, source);
		}
		else
		{
			glBindTexture(GL_TEXTURE_2D, data.id);
			if (data.textureVersion != source.textureVersion)
			{
				auto pixelInfo = source.getPixels();
				glPixelStorei(GL_PACK_ROW_LENGTH, pixelInfo.stride);
				glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, pixelInfo.w, pixelInfo.h, TextureFormat, GL_UNSIGNED_BYTE, pixelInfo.pixelPtr(0, 0));
				data.textureVersion = source.textureVersion;
			}
		}
		return data;
	}

	private void rebuildTexture(OpenGLTextureRenderData data, TextureSource source)
	{
		glGenTextures(1, &data.id);
		glBindTexture(GL_TEXTURE_2D, data.id);
		glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
		glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);

		auto pixelInfo = source.getPixels();
		data.w = roundUpToPowerOfTwo(pixelInfo.w);
		data.h = roundUpToPowerOfTwo(pixelInfo.h);

		glPixelStorei(GL_PACK_ROW_LENGTH, pixelInfo.stride);
		if (isPowerOfTwo(pixelInfo.w) && isPowerOfTwo(pixelInfo.h))
			glTexImage2D(GL_TEXTURE_2D, 0, InternalTextureFormat, data.w, data.h, 0, TextureFormat, GL_UNSIGNED_BYTE, pixelInfo.pixelPtr(0, 0));
		else
		{
			glTexImage2D(GL_TEXTURE_2D, 0, InternalTextureFormat, data.w, data.h, 0, TextureFormat, GL_UNSIGNED_BYTE, null);
			glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, pixelInfo.w, pixelInfo.h, TextureFormat, GL_UNSIGNED_BYTE, pixelInfo.pixelPtr(0, 0));
		}
		data.textureVersion = source.textureVersion;
	}

	override void shutdown()
	{
		cleanupTextures(true);
	}

	private void cleanupTextures(bool all=false)
	{
		for (auto node = OpenGLTextureRenderData.head; node; node = node.next)
			if (!node.invalid && (all || node.destroyed))
				node.destroy(); // TODO: unlink
		if (all)
			OpenGLTextureRenderData.head = null;
	}
}

private final class OpenGLTextureRenderData : TextureRenderData
{
	GLuint id;
	OpenGLTextureRenderData next;
	static OpenGLTextureRenderData head;
	bool invalid;
	uint w, h;

	void destroy()
	{
		invalid = true;
		glDeleteTextures(1, &id);
	}
}
