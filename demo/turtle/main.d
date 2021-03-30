/**
 * Simple turtle graphics demo
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

module ae.demo.turtle.main;

import std.algorithm.comparison;
import std.math;

import ae.demo.turtle.turtle;
import ae.ui.app.application;
import ae.ui.app.main;
import ae.ui.shell.shell;
import ae.ui.shell.sdl2.shell;
import ae.ui.video.video;
import ae.ui.video.sdl2.video;
import ae.ui.video.renderer;
import ae.utils.graphics.draw;

final class MyApplication : Application
{
	override string getName() { return "Demo/Turtle"; }
	override string getCompanyName() { return "CyberShadow"; }

	Shell shell;

	alias Color = Renderer.COLOR;

	Image!Color image;
	int demoIndex;

	override void render(Renderer s)
	{
		auto canvas = s.lock();
		scope(exit) s.unlock();

		if (image.w != canvas.w || image.h != canvas.h)
			renderImage(canvas.w, canvas.h);
		image.blitTo(canvas);
	}

	override void handleMouseDown(uint x, uint y, MouseButton button)
	{
		demoIndex++;
		image = image.init; // Force redraw next frame
	}

	void renderImage(int w, int h)
	{
		image.size(w, h);
		image.fill(Color.init);

		auto t = image.turtle();
		t.x = w/2;
		t.y = h/2;
		t.scale = min(w, h) * 0.75f;
		t.color = Color.white;

		switch (demoIndex % 4)
		{
			case 0:
				shell.setCaption("Square");
				// Move to the corner
				t.turnLeft(90);
				t.forward(0.5);
				t.turnLeft(90);
				t.forward(0.5);
				t.turnAround();
				// Draw a square
				t.penDown();
				foreach (n; 0..4)
				{
					t.forward(1.0);
					t.turnRight(90);
				}
				break;

			case 1:
				shell.setCaption("Plus");
				// Draw a spoke, turn left, repeat 4 times
				t.penDown();
				foreach (n; 0..4)
				{
					t.forward(0.5);
					t.turnAround();
					t.forward(0.5);
					t.turnLeft(90);
				}
				break;

			case 2:
				// Function to draw an arbitrary regular convex polygon.
				void drawPolygon(int sides)
				{
					t.forward(0.5);
					t.turnRight(90 + 180f / sides);
					t.penDown();
					auto sideAngle = 360f / sides;
					auto sideLength = sin(sideAngle / 180 * PI) * 0.5;
					foreach (n; 0..sides)
					{
						t.forward(sideLength);
						t.turnRight(sideAngle);
					}
					return;
				}

				shell.setCaption("Octagon");
				drawPolygon(8);
				break;

			case 3:
			{
				shell.setCaption("Koch snowflake");
				enum maxDepth = 6;

				// Recursive function used to draw one segment.
				void drawSegment(float scale, int depth)
				{
					if (depth == maxDepth)
						t.forward(scale);
					else
					{
						drawSegment(scale/3, depth+1);
						t.turnLeft(60);
						drawSegment(scale/3, depth+1);
						t.turnRight(120);
						drawSegment(scale/3, depth+1);
						t.turnLeft(60);
						drawSegment(scale/3, depth+1);
					}
				}

				t.forward(0.5);
				t.turnRight(120);
				t.penDown();
				foreach (n; 0..6)
				{
					drawSegment(0.5, 0);
					t.turnRight(60);
				}
				break;
			}

			default:
				assert(false);
		}
	}

	override int run(string[] args)
	{
		shell = new SDL2Shell(this);
		shell.video = new SDL2SoftwareVideo();
		shell.run();
		shell.video.shutdown();
		return 0;
	}

	override void handleQuit()
	{
		shell.quit();
	}
}

shared static this()
{
	createApplication!MyApplication();
}
