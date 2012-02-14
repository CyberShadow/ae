/**
 * ae.ui.video.sdlopengl.renderer
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

	override void line(float x0, float y0, float x1, float y1, COLOR color)
	{
		x0 += 0.5f;
		y0 += 0.5f;
		x1 += 0.5f;
		y1 += 0.5f;

		auto a = atan2(y1-y0, x1-x0);
		float ca = 0.5 * cos(a);
		float sa = 0.5 * sin(a);
		x0 -= ca;
		y0 -= sa;
		x1 -= ca;
		y1 -= sa;

		glColor3ub(color.r, color.g, color.b);
		glBegin(GL_LINES);
		glVertex2f(x0, y0);
		glVertex2f(x1, y1);
		glEnd();
	}

	/*override void hline(int x0, int x1, int y, COLOR color)
	{
		glColor3ub(color.r, color.g, color.b);
		glBegin(GL_LINES);
		glVertex2f(x0, y+0.5f);
		glVertex2f(x1, y+0.5f);
		glEnd();
	}*/

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
