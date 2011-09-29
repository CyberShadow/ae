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
	Explosions,
	EnemyBullets,
	Enemies,
	BulletParticles,
	ShipBullets,
	Ship,
	Max
}

GameEntity[][Plane.Max] planes;
bool initializing = true;

Image!G16 canvas;
float cf(float x) { assert(canvas.w == canvas.h); return x*canvas.w; }
int   ci(float x) { assert(canvas.w == canvas.h); return cast(int)round(x*canvas.w); }
auto BLACK = G16(0x0000);
auto WHITE = G16(0xFFFF);

bool up, down, left, right, space;

class GameEntity
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
		foreach(i, obj; planes[plane])
			if (this is obj)
			{
				planes[plane] = planes[plane][0..i] ~ planes[plane][i+1..$];
				return;
			}
		assert(0, "Not found");
	}
}

// *********************************************************

class Game : GameEntity
{
	this()
	{
		add(Plane.Logic);
		new BulletParticles();
	}

	override void step(uint deltaTicks)
	{
		foreach (i; 0..deltaTicks)
			new Star();
		if (!initializing && planes[Plane.Ship].length!=0 && uniform(0, 1000)==0)
			new Thingy(uniform(0., 1.), frands()*0.0003, 0.0002+frand()*0.0003);
		if (!initializing && planes[Plane.Ship].length==0 && planes[Plane.Enemies].length==0 && planes[Plane.EnemyBullets].length==0 && planes[Plane.Explosions].length==0)
			new Ship();
	}

	override void render() {}
}

// *********************************************************

class GameObject : GameEntity
{
	float x, y, vx=0, vy=0, r=0;
	bool dead;

	enum DEATHBRAKES = 0.998;

	override void step(uint deltaTicks)
	{
		x += vx*deltaTicks;
		y += vy*deltaTicks;
		if (dead)
			vx *= DEATHBRAKES,
			vy *= DEATHBRAKES;
	}

	final void collideWith(Plane[] planeIndices...)
	{
		assert(!dead);

		foreach (plane; planeIndices)
			foreach (obj; planes[plane])
			{
				auto enemy = cast(GameObject) obj;
				if (enemy && !enemy.dead)
					if (dist(x-enemy.x, y-enemy.y) < r+enemy.r)
					{
						die();
						enemy.die();
						return;
					}
			}
	}

	void die()
	{
		if (r)
			new Explosion(this);
		remove();
	}
}

// *********************************************************

float frand () { return uniform!`[)`( 0.0f, 1.0f); }
float frands() { return uniform!`()`(-1.0f, 1.0f); }

class Star : GameEntity
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
		y += deltaTicks * (0.0001+(1-z)*0.00005);
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
	this()
	{
		x = 0.5;
		y = 0.9;
		r = 0.040;
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
		super.step(deltaTicks);
		if (x<0.05 || x>0.95) vx = 0;
		if (y<0.05 || y>0.95) vy = 0;
		x = bound(x, 0.05, 0.95);
		y = bound(y, 0.05, 0.95);

		static bool lastSpace;
		if (space && !lastSpace)
		{
			new Bullet(this, -0.034, -0.026);
			new Bullet(this, +0.034, -0.026);
		}
		lastSpace = space;

		collideWith(Plane.Enemies, Plane.EnemyBullets);
	}

	override void die()
	{
		new Explosion(this, 0.150);
		remove();
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
	this(Ship ship, float dx, float dy)
	{
		this.x = ship.x + dx;
		this.y = ship.y + dy;
		this.vx = ship.vx;
		this.vy = ship.vy - 0.000_500;
		add(Plane.ShipBullets);
	}

	int t;

	override void step(uint deltaTicks)
	{
		super.step(deltaTicks);
		if (y < -0.25 || x < 0 || x > 1)
			return remove();

		//if ((t+=deltaTicks) % 1 == 0)
			BulletParticles.create(this,
				frands()*0.000_010,
				frand ()*0.000_100 + 0.000_200);

		collideWith(Plane.Enemies, Plane.EnemyBullets);
	}

	override void die()
	{
		super.die();
		foreach (n; 0..500)
		{
			auto a = uniform(0, TAU);
			BulletParticles.create(this,
				frand()*cos(a)*0.000_300,
				frand()*sin(a)*0.000_300 - 0.000_100,
				0.003);
		}
	}

	override void render()
	{
		canvas.aaPutPixel(cf(x), cf(y), WHITE);
	}
}

class BulletParticles : GameEntity
{
	struct Particle
	{
		float x, y, vx, vy, t, s;
	}

	enum MAX_PARTICLES = 1024*32;
	static __gshared Particle* particles;
	static __gshared int particleCount;

	static void create(Bullet source, float vx, float vy, float s = 0.001)
	{
		assert(particles, "Not initialized?");
		if (particleCount == MAX_PARTICLES)
			return;
		particles[particleCount++] = Particle(source.x, source.y, vx, vy, 0, s);
	}

	this()
	{
		particles = (new Particle[MAX_PARTICLES]).ptr;
		add(Plane.BulletParticles);
	}

	override void step(uint deltaTicks)
	{
		int i = 0;
		while (i < particleCount)
			with (particles[i])
			{
				x += vx;
				y += vy;
				t += s;
				if (t >= 1)
					particles[i] = particles[--particleCount];
				else
					i++;
			}
	}

	override void render()
	{
		foreach (ref particle; particles[0..particleCount])
			with (particle)
				canvas.aaPutPixel(cf(x), cf(y), WHITE, canvas.tofracBounded(1-t));
	}
}

class Enemy : GameObject
{
}

class Thingy : Enemy
{
	float a, death;
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
			super.step(1);
			if (y > 1.060)
			{
				remove();
				return;
			}
			a += 0.001;
			t++;

			if (!dead)
			{
				if (t%1000==0 && planes[Plane.Ship].length)
					new Missile(this);
			}
			else
			{
				death += 0.002;
				if (death > 1)
					remove();
			}
		}
	}

	override void die()
	{
		dead = true;
		death = 0;
		new Explosion(this);
	}

	override void render()
	{
		void disc(float x, float y, float r0, float r1)
		{
			if (!dead)
				canvas.softEdgedCircle(cf(x), cf(y), cf(r0), cf(r1), WHITE);
			else
			{
				canvas.softEdgedCircle(cf(x), cf(y), cf(r0), cf(r1), G16(canvas.tofracBounded(1-death)));
				canvas.softEdgedCircle(cf(x), cf(y), cf(0), cf(r1*death), BLACK);
			}
		}
		disc(x, y, 0.020, 0.030);
		disc(x+0.040*cos(a), y+0.040*sin(a), 0.010, 0.014);
		disc(x-0.040*cos(a), y-0.040*sin(a), 0.010, 0.014);
	}
}

class Missile : Enemy
{
	int t;

	this(Enemy parent)
	{
		this.x = parent.x;
		this.y = parent.y;
		this.r = 0.008;
		t = 0;
		if (planes[Plane.Ship].length)
		{
			Ship ship = cast(Ship)planes[Plane.Ship][0];
			vx = ship.x - parent.x;
			vy = ship.y - parent.y;
		}
		float f = 0.0002/dist(this.vx, this.vy);
		vx *= f;
		vy *= f;
		add(Plane.EnemyBullets);
	}

	override void step(uint deltaTicks)
	{
		super.step(deltaTicks);
		if (x<0 || x>1 || y<0 || y>1)
			return remove();
		t += deltaTicks;
	}

	override void render()
	{
		r = 0.008+0.002*sin(t/100f);
		canvas.softEdgedCircle(cf(x), cf(y), cf(r-0.003), cf(r), G16(canvas.tofracBounded(0.75+0.25*(-sin(t/100f)))));
	}
}

class Explosion : GameObject
{
	float size, maxt;
	int t;

	this(GameObject source, float size = 0)
	{
		if (size==0) size = source.r*2;
		this.x = source.x;
		this.y = source.y;
		this.vx = source.vx;
		this.vy = source.vy;
		this.size = size;
		this.t = 0;
		this.maxt = size*16500;
		this.dead = true;
		add(Plane.Explosions);
	}

	override void step(uint deltaTicks)
	{
		t += deltaTicks;
		super.step(deltaTicks);

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

class Splode : GameEntity
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
