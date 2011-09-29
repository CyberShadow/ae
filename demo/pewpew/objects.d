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

/// Game objects and logic
module ae.demo.pewpew.objects;

import std.random;
import std.math;

import ae.utils.math;
import ae.utils.graphics.image;

__gshared:

enum Plane
{
	Logic,
	BG3,
	BG2,
	BG1,
	Bullets,
	Explosions,
	Enemies,
	Ship,
	Max
}

GameObject[][Plane.Max] planes;
bool initializing = true;

Image!G16 canvas;
float cf(float x) { assert(canvas.w == canvas.h); return x*canvas.w; }
int   ci(float x) { assert(canvas.w == canvas.h); return cast(int)round(x*canvas.w); }
auto WHITE = G16(0xFFFF);

bool up, down, left, right, space;

class GameObject
{
	Plane plane;

	abstract void step(uint deltaTicks);
	abstract void render();

	void add(Plane plane)
	{
		this.plane = plane;
		planes[plane] ~= this;
	}

	void remove()
	{
		foreach(i,obj;planes[plane])
			if (this is obj)
			{
				planes[plane] = planes[plane][0..i] ~ planes[plane][i+1..$];
				return;
			}
		assert(0, "Not found");
	}
}

// *********************************************************

class Game : GameObject
{
	this()
	{
		add(Plane.Logic);
	}

	override void step(uint deltaTicks)
	{
		foreach (i; 0..deltaTicks)
			new Star();
		if (!initializing && planes[Plane.Ship].length!=0 && uniform(0, 1000)==0)
			new Thingy(uniform(0., 1.), frands()*0.0003, 0.0002+frand()*0.0003);
		if (!initializing && planes[Plane.Ship].length==0 && planes[Plane.Enemies].length==0 && planes[Plane.Bullets].length==0 && planes[Plane.Explosions].length==0)
			new Ship();
	}

	override void render() {}
}

// *********************************************************

float frand () { return uniform!`[)`( 0.0f, 1.0f); }
float frands() { return uniform!`()`(-1.0f, 1.0f); }

class Star : GameObject
{
	float x, y, z;

	this()
	{
		z = frand();
		x = frand();
		y = 0;
		add(cast(Plane)((1-z)*3));
	}

	override void step(uint deltaTicks)
	{
		y += deltaTicks * (0.0002+(1-z)*0.0001);
		if (y>1)
			remove();
	}

	override void render()
	{
		canvas.aaPutPixel(cf(x), cf(y), canvas.COLOR(canvas.fixfpart(canvas.tofix((1-z)*0.5))));
	}
}

class Ship : GameObject
{
	float x, y, vx, vy;

	this()
	{
		x = 0.5;
		y = 0.9;
		vx = vy = 0;
		add(Plane.Ship);
	}

	override void step(uint deltaTicks)
	{
		const a    = 0.000_001;
		const maxv = 0.000_500;

		if (left)
			vx = bound(vx-a*deltaTicks, -maxv, 0);
		else
		if (right)
			vx = bound(vx+a*deltaTicks, 0,  maxv);
		else
			vx = 0;

		if (up)
			vy = bound(vy-a*deltaTicks, -maxv, 0);
		else
		if (down)
			vy = bound(vy+a*deltaTicks, 0,  maxv);
		else
			vy = 0;
		x = bound(x+vx*deltaTicks, 0.05, 0.95);
		y = bound(y+vy*deltaTicks, 0.05, 0.95);

		foreach (obj; planes[Plane.Enemies] ~ planes[Plane.Bullets])
		{
			auto enemy = cast(Enemy)obj;
			if (enemy)
				if (dist(x-enemy.x, y-enemy.y)<0.040+enemy.r)
				{
					remove();
					enemy.remove();
					new Explosion(x, y, 0.150);
					new Explosion(enemy.x, enemy.y, enemy.r*2);
					return;
				}
		}

		static bool lastSpace;
		if (space && !lastSpace)
		{
			new Bullet(x-0.034, y-0.026);
			new Bullet(x+0.034, y-0.026);
		}
		lastSpace = space;
	}

	override void render()
	{
		canvas.aaFillRect     (cf(x-0.040), cf(y-0.020), cf(x-0.028), cf(y+0.040), G16(0x4000));
		canvas.aaFillRect     (cf(x-0.038), cf(y-0.018), cf(x-0.030), cf(y+0.038), G16(0xC000));
		canvas.aaFillRect     (cf(x+0.040), cf(y-0.020), cf(x+0.028), cf(y+0.040), G16(0x4000));
		canvas.aaFillRect     (cf(x+0.038), cf(y-0.018), cf(x+0.030), cf(y+0.038), G16(0xC000));
		canvas.aaFillRect     (cf(x-0.030), cf(y+0.020), cf(x+0.030), cf(y+0.024), G16(0x4000));
		canvas.aaFillRect     (cf(x-0.008), cf(y-0.040), cf(x+0.008), cf(y+0.030), G16(0x4000));
		canvas.aaFillRect     (cf(x-0.006), cf(y-0.038), cf(x+0.006), cf(y+0.028), G16(0xC000));
		canvas.softEdgedCircle(cf(x      ), cf(y+0.020), cf(  0.014), cf(  0.020), G16(0xC000));
	}
}

class Bullet : GameObject
{
	float x, y;

	this(float x, float y)
	{
		this.x = x;
		this.y = y;
		add(Plane.Bullets);
	}

	override void step(uint deltaTicks)
	{
		y -= 0.0004 * deltaTicks;
		if (y < 0)
			return remove();

		foreach (obj; planes[Plane.Enemies])
		{
			auto enemy = cast(Enemy)obj;
			if (enemy)
				if (dist(x-enemy.x, y-enemy.y)<enemy.r)
				{
					remove();
					enemy.remove();
					new Explosion(enemy.x, enemy.y);
					return;
				}
		}
	}

	override void render()
	{
		//ThinLine!(false)(x, y, x, y+5, 255, 255);
		canvas.vline(ci(x), ci(y), ci(y+0.010), WHITE);
	}
}

class Enemy : GameObject
{
	float x, y, r;
}

class Thingy : Enemy
{
	float vx, vy, a;
	int t;

	this(float x, float vx, float vy)
	{
		this.x = x;
		this.y = -0.060;
		this.r = 0.030;
		this.vx = vx;
		this.vy = vy;
		a = 0;
		t = 0;
		add(Plane.Enemies);
	}

	override void step(uint deltaTicks)
	{
		for (int n=0; n<deltaTicks; n++)
		{
			if (x < 0.020)
				vx = max(vx, -vx);
			if (x > 0.980)
				vx = min(vx, -vx);
			x += vx;
			y += vy;
			if (y > 1.060)
			{
				remove();
				return;
			}
			a += 0.001;
			t++;

			if (t%1000==0 && planes[Plane.Ship].length)
			{
				new Missile(this);
			}
		}
	}

	override void render()
	{
		canvas.softEdgedCircle(cf(x), cf(y), cf(0.020), cf(0.030), WHITE);
		canvas.softEdgedCircle(cf(x+0.040*cos(a)), cf(y+0.040*sin(a)), cf(0.010), cf(0.014), WHITE);
		canvas.softEdgedCircle(cf(x-0.040*cos(a)), cf(y-0.040*sin(a)), cf(0.010), cf(0.014), WHITE);
	}
}

class Missile : Enemy
{
	float vx, vy;
	int t;

	this(Enemy parent)
	{
		this.x = parent.x;
		this.y = parent.y;
		this.r = 0.008;
		t = 0;
		Ship ship = cast(Ship)planes[Plane.Ship][0];
		vx = ship.x - parent.x;
		vy = ship.y - parent.y;
		float f = 0.0002/dist(this.vx, this.vy);
		vx *= f;
		vy *= f;
		add(Plane.Bullets);
	}

	override void step(uint deltaTicks)
	{
		x += vx*deltaTicks;
		y += vy*deltaTicks;
		if (x<0 || x>1 || y<0 || y>1)
			return remove();
		t += deltaTicks;
	}

	override void render()
	{
		float r = 0.008+0.002*sin(t/100f);
		canvas.softEdgedCircle(cf(x), cf(y), cf(r-0.003), cf(r), G16(canvas.tofrac(0.75+0.25*(-sin(t/100f)))));
	}
}

class Explosion : GameObject
{
	float x, y, size, maxt;
	int t;

	this(float x, float y, float size=0.060f)
	{
		this.x = x;
		this.y = y;
		this.size = size;
		this.t = 0;
		this.maxt = size*16500;
		add(Plane.Explosions);
	}

	override void step(uint deltaTicks)
	{
		t += deltaTicks;
		if (t>maxt)
			remove;
		else
		if (frand() < size)
		{
			float tf = t/maxt; // time factor
			float ex = x+tf*size*frands();
			float ey = y+tf*size*frands();
			float ed = dist(x-ex, y-ey);
			if (ed>size) return;
			float r =
				frand()*       // random factor
				(1-ed/size);   // distance factor
			new Splode(ex, ey, size/3*r);
		}
	}

	override void render()
	{
	}
}

class Splode : GameObject
{
	float x, y, r, cr;
	bool growing;

	this(float x, float y, float r)
	{
		this.x = x;
		this.y = y;
		this.r = r;
		this.cr = 0;
		this.growing = true;
		add(Plane.Explosions);
	}

	override void step(uint deltaTicks)
	{
		const ra = 0.000_020;
		if (growing)
		{
			cr += ra;
			if (cr>=r)
				growing = false;
		}
		else
		{
			cr -= ra;
			if (cr<=0)
			{
				remove();
				return;
			}
		}
	}

	override void render()
	{
		//std.stdio.writefln("%f %f %f", x, y, cr);
		canvas.softEdgedCircle(cf(x), cf(y), cf(cr-0.003), cf(cr), G16(cast(canvas.frac) min(canvas.frac.max, canvas.tofix(cr/r))));
	}
}
