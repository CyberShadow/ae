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
		glColor3ub(color.r, color.g, color.b);
		glBegin(GL_POINTS);
		glVertex2f(x+0.5f, y+0.5f);
		glEnd();
	}

	override void putPixels(Pixel[] pixels)
	{
		glBegin(GL_POINTS);
		foreach (ref pixel; pixels)
		{
			glColor3ub(pixel.color.r, pixel.color.g, pixel.color.b);
			glVertex2f(pixel.x+0.5f, pixel.y+0.5f);
		}
		glEnd();
	}

	override void clear()
	{
		glClear(GL_COLOR_BUFFER_BIT);
	}
}
