/**
 * Game objects and logic
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

module ae.demo.pewpew.objects;

import std.random;
import std.math;

import ae.utils.container;
import ae.utils.math;
import ae.utils.geometry;
import ae.utils.graphics.image;

__gshared:

enum Plane
{
	Logic,
	BG0,
	BG1,
	BG2,
	Ship,
	PlasmaOrbs,
	Enemies,
	Particles,
	Torpedoes,
	Explosions,
	Max
}

enum STAR_LAYERS = 3;

DListContainer!GameEntity[Plane.Max] planes;
bool initializing = true;

alias G16 COLOR;
//alias G8 COLOR; // less precise, but a bit faster

Image!COLOR canvas;
float cf(float x) { assert(canvas.w == canvas.h); return x*canvas.w; }
int   ci(float x) { assert(canvas.w == canvas.h); return cast(int)(x*canvas.w); }
T cbound(T)(T x) { return bound(x, 0, canvas.w); }
auto BLACK = COLOR(0);
auto WHITE = COLOR(COLOR.BaseType.max);

bool up, down, left, right, fire;

bool useAnalog; float analogX, analogY;

float frand () { return uniform!`[)`( 0.0f, 1.0f); }
float frands() { return uniform!`()`(-1.0f, 1.0f); }

T ssqr(T)(T x) { return sqr(x) * sign(x); }
float frands2() { return ssqr(frands()); }

// *********************************************************

class GameEntity
{
	mixin DListLink;
	Plane plane;

	abstract void step(uint deltaTicks);
	abstract void render();

	void add(Plane plane)
	{
		this.plane = plane;
		planes[plane].add(this);
	}

	void remove()
	{
		planes[plane].remove(this);
	}
}

class Game : GameEntity
{
	this()
	{
		add(Plane.Logic);
		spawnParticles = new SpawnParticles(Plane.Particles);
		foreach (layer; 0..STAR_LAYERS)
			starFields[layer] = new StarField(cast(Plane)(Plane.BG0 + layer));
		torpedoParticles = new TorpedoParticles(Plane.Particles);
	}

	uint spawnTimer;

	override void step(uint deltaTicks)
	{
		foreach (i; 0..deltaTicks)
		{
			auto z = frand();
			auto star = Star(
				frand(), 0,
				0.0001f + (1-z) * 0.00005f,
				canvas.COLOR(canvas.fixfpart(canvas.tofix((1-z)*0.5f))));
			auto layer = cast(int)((1-z)*3);
			starFields[layer].add(star);
		}
		if (!initializing && ship && !ship.dead && spawnTimer--==0)
		{
			new Thingy();
			spawnTimer = uniform(1500, 2500);
		}
		if (!initializing && planes[Plane.Ship].empty && planes[Plane.Enemies].empty && planes[Plane.PlasmaOrbs].empty && planes[Plane.Explosions].empty)
			new Ship();
	}

	override void render() {}
}

// *********************************************************

class ParticleManager(Particle) : GameEntity
{
	Particle* particles;
	int particleCount;

	void add(Particle particle)
	{
		if (particleCount == Particle.MAX)
			return;
		particles[particleCount++] = particle;
	}

	this(Plane plane)
	{
		particles = (new Particle[Particle.MAX]).ptr;
		super.add(plane);
	}

	override void step(uint deltaTicks)
	{
		int i = 0;
		while (i < particleCount)
			with (particles[i])
			{
				enum REMOVE = q{ particles[i] = particles[--particleCount]; };
				enum NEXT   = q{ i++; };
				mixin(Particle.STEP);
			}
	}

	override void render()
	{
		import std.parallelism;
		foreach (ref particle; taskPool.parallel(particles[0..particleCount]))
			with (particle)
			{
				mixin(Particle.RENDER);
			}
	}
}

/+
class ParticleManager(Particle) : GameEntity
{
	Particle[] particles;

	void add(Particle particle)
	{
		particles ~= particle;
	}

	this(Plane plane)
	{
		super.add(plane);
	}

	override void step(uint deltaTicks)
	{
		for (int i=0; i<particles.length; i++)
			with (particles[i])
			{
				enum REMOVE = q{ particles = particles[0..i] ~ particles[i+1..$]; };
				enum NEXT   = q{ };
				mixin(Particle.STEP);
			}
	}

	override void render()
	{
		foreach (ref particle; particles)
			with (particle)
			{
				mixin(Particle.RENDER);
			}
	}
}
+/

struct Star
{
	float x, y, vy;
	COLOR color;

	enum MAX = 1024*32;

	enum STEP =
	q{
		y += deltaTicks * vy;
		if (y > 1f)
			{ mixin(REMOVE); }
		else
			{ mixin(NEXT); }
	};

	enum RENDER =
	q{
		canvas.aaPutPixel(cf(x), cf(y), color);
	};
}

alias ParticleManager!Star StarField;
StarField[STAR_LAYERS] starFields;

// *********************************************************

class GameObject : GameEntity
{
	float x, y, vx=0, vy=0;
	Shape!float[] shapes; /// shape coordinates are relative to x,y
	bool dead;

	enum DEATHBRAKES = 0.998f;

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
					foreach (shape1; shapes)
					{
						if (shape1.kind == ShapeKind.none) continue;
						shape1.translate(x, y);
						foreach (shape2; enemy.shapes)
						{
							if (shape2.kind == ShapeKind.none) continue;
							shape2.translate(enemy.x, enemy.y);
							if (intersects(shape1, shape2))
							{
								die();
								enemy.die();
								return;
							}
						}
					}
			}
	}

	void die()
	{
		remove();
	}
}

// *********************************************************

class Ship : GameObject
{
	float death = 0f, spawn = 0f;
	bool spawning;
	uint t;

	enum SPAWN_START = 0.3f;
	enum SPAWN_END = 0.3f;

	this()
	{
		x = 0.5f;
		y = 0.85f;
		vx = vy = 0;
		shapes ~= shape(rect(-0.040f, -0.020f, -0.028f, +0.040f)); // left wing
		shapes ~= shape(rect(+0.040f, -0.020f, +0.028f, +0.040f)); // right wing
		shapes ~= shape(rect(-0.008f, -0.040f, +0.008f, +0.030f)); // center hull
		shapes ~= shape(rect(-0.030f, +0.020f, +0.030f, +0.024f)); // bridge
		shapes ~= shape(circle(0, +0.020f, 0.020f));               // round section
		add(Plane.Ship);
		ship = this;
		dead = spawning = true;
	}

	override void step(uint deltaTicks)
	{
		if (!dead)
		{
			const a    = 0.000_001f;
			const maxv = 0.000_500f;

			if (useAnalog)
				vx = analogX * maxv,
				vy = analogY * maxv;
			else
			{
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
			}

			t += deltaTicks;
		}
		super.step(deltaTicks);

		if (!dead)
		{
			if (x<0.05f || x>0.95f) vx = 0;
			if (y<0.05f || y>0.95f) vy = 0;
			x = bound(x, 0.05f, 0.95f);
			y = bound(y, 0.05f, 0.95f);

			static bool wasFiring;
			//fire = t % 250 == 0;
			if (fire && !wasFiring)
			{
				new Torpedo(-0.034f, -0.020f);
				new Torpedo(+0.034f, -0.020f);
			}
			wasFiring = !!fire;

			collideWith(Plane.Enemies, Plane.PlasmaOrbs);
		}
		else
		if (spawning)
		{
			spawn += 0.0005f;

			if (spawn < SPAWN_START+1f)
				foreach (n; 0..5)
				{
					float px = frands()*0.050f;
					spawnParticles.add(SpawnParticle(
						x + px*1.7f + frands ()*0.010f,
						spawnY()    + frands2()*0.050f,
						x + px,
					));
				}

			if (spawn >= SPAWN_START+1f+SPAWN_END)
				spawning = dead = false;
		}
		else
		{
			death += (1f/2475f);
			if (death > 1f)
				remove();
		}
	}

	override void die()
	{
		new Explosion(this, 0.150f);
		dead = true;
	}

	override void render()
	{
		enum Gray25 = COLOR.BaseType.max / 4;
		enum Gray75 = COLOR.BaseType.max / 4 * 3;

		void drawRect(float x0, float y0, float x1, float y1, COLOR color)
		{
			canvas.aaFillRect(cf(x+x0), cf(y+y0), cf(x+x1), cf(y+y1), color);
		}

		void drawRect2(Rect!float r)
		{
			r.sort();
			drawRect(r.x0       , r.y0       , r.x1       , r.y1       , COLOR(Gray25));
			drawRect(r.x0+0.002f, r.y0+0.002f, r.x1-0.002f, r.y1-0.002f, COLOR(Gray75));
		}

		void drawCircle(Circle!float c, COLOR color)
		{
			canvas.softCircle(cf(x+c.x), cf(y+c.y), cf(c.r*0.7f), cf(c.r), color);
		}


		void warp(float x, float y, float r)
		{
			auto bgx0 = cbound(ci(x-r));
			auto bgy0 = cbound(ci(y-r));
			auto bgx1 = cbound(ci(x+r));
			auto bgy1 = cbound(ci(y+r));
			auto window = canvas.window(bgx0, bgy0, bgx1, bgy1);
			static Image!COLOR bg;
			copyCanvas(window, bg);
			window.warp!q{
				alias extraArgs[0] cx;
				alias extraArgs[1] cy;
				int dx = x-cx;
				int dy = y-cy;
				float f = dist(dx, dy) / cx;
				if (f < 1f && f > 0f)
				{
					float f2 = (1-f)*sqrt(sqrt(f)) + f*f;
					assert(f2 < 1f);
					int sx = cx + cast(int)(dx / f * f2);
					int sy = cy + cast(int)(dy / f * f2);

					if (sx>=0 && sx<w && sy>=0 && sy<h)
						c = src[sx, sy];
					else
						c = COLOR(0);
				}
			}(bg, ci(x)-bgx0, ci(y)-bgy0);
		}

		if (spawning)
		{
			enum R = 0.15f;
			warp(x, spawnY(), R * sqrt(sin(spawn/(SPAWN_START+1f+SPAWN_END)*PI)));
		}

		static Image!COLOR bg;
		int bgx0, bgyS;
		if (spawning)
		{
			bgx0 = ci(x-0.050f);
			bgyS = ci(spawnY());
			copyCanvas(canvas.window(bgx0, bgyS, ci(x+0.050f), ci(y+0.050f)), bg);
		}

		drawRect2 (shapes[0].rect);
		drawRect2 (shapes[1].rect);
		drawRect2 (shapes[2].rect);
		drawRect  (shapes[3].rect.tupleof, COLOR(Gray25));
		drawCircle(shapes[4].circle      , COLOR(Gray75));

		if (spawning)
			canvas.draw(bgx0, bgyS, bg);
	}

	float spawnY()
	{
		return y-0.050f + (0.100f * bound(spawn-SPAWN_START, 0f, 1f));
	}
}

Ship ship;

struct SpawnParticle
{
	float x0, y0, x1, t=0f;

	enum MAX = 1024*32;

	enum STEP =
	q{
		t += 0.002f;
		if (t > 1f)
			{ mixin(REMOVE); }
		else
			{ mixin(NEXT); }
	};

	enum RENDER =
	q{
		float y1 = ship.spawnY();
		float tt0 = sqr(sqr(t));
		float tt1 = min(1, tt0+0.15f);
		float lx0 = x0 + tt0*(x1-x0);
		float ly0 = y0 + tt0*(y1-y0);
		float lx1 = x0 + tt1*(x1-x0);
		float ly1 = y0 + tt1*(y1-y0);
		//canvas.aaPutPixel(cf(x), cf(y), WHITE, canvas.tofracBounded(tt));
		canvas.aaLine(cf(lx0), cf(ly0), cf(lx1), cf(ly1), WHITE, canvas.tofracBounded(sqr(tt0)));
	};
}

alias ParticleManager!SpawnParticle SpawnParticles;
SpawnParticles spawnParticles;

// *********************************************************

class Torpedo : GameObject
{
	this(float dx, float dy)
	{
		this.x = ship.x + dx;
		this.y = ship.y + dy;
		this.vx = ship.vx;
		this.vy = ship.vy - 0.000_550f;
		shapes ~= Shape!float(Point!float(0, 0));
		add(Plane.Torpedoes);
	}

	int t;

	override void step(uint deltaTicks)
	{
		super.step(deltaTicks);
		if (y < -0.25f || x < 0 || x > 1)
			return remove();

		//if ((t+=deltaTicks) % 1 == 0)
			torpedoParticles.add(TorpedoParticle(
				x, y,
				frands()*0.000_010f,
				frand ()*0.000_100f + 0.000_200f));

		collideWith(Plane.Enemies, Plane.PlasmaOrbs);
	}

	override void die()
	{
		remove();
		foreach (n; 0..500)
		{
			auto a = uniform(0, TAU);
			torpedoParticles.add(TorpedoParticle(x, y,
				frand()*cos(a)*0.000_300f,
				frand()*sin(a)*0.000_300f - 0.000_100f,
				0.003f));
		}
	}

	override void render()
	{
		canvas.aaPutPixel(cf(x), cf(y), WHITE);
	}
}

struct TorpedoParticle
{
	float x, y, vx, vy, s = 0.001f, t = 0;

	enum MAX = 1024*64;

	enum STEP =
	q{
		x += vx;
		y += vy;
		t += s;
		if (t >= 1)
			mixin(REMOVE);
		else
			mixin(NEXT);
	};

	enum RENDER =
	q{
		canvas.aaPutPixel(cf(x), cf(y), WHITE, canvas.tofracBounded(1-t));
	};
}

alias ParticleManager!TorpedoParticle TorpedoParticles;
TorpedoParticles torpedoParticles;

// *********************************************************

class Enemy : GameObject
{
}

class ThingyPart : Enemy
{
	float death = 0f;

	override void render()
	{
		float r1 = shapes[0].circle.r;
		float r0 = r1*(2f/3f);

		if (!dead)
			canvas.softCircle(cf(x), cf(y), cf(r0), cf(r1), WHITE);
		else
		{
			canvas.softCircle(cf(x), cf(y), cf(r0), cf(r1), COLOR(canvas.tofracBounded(1-death)));
			canvas.softCircle(cf(x), cf(y), cf(r0*death), cf(r1*death), BLACK);
		}
	}
}

class Thingy : ThingyPart
{
	float a, va;
	ThingySatellite[] satellites;
	int charge; // max is 2000

	this()
	{
		this.x = uniform(0f, 1f);
		this.y = -0.060f;
		this.vx = frands()*0.0003f;
		this.vy = 0.0002f+frand()*0.0003f;
		shapes ~= shape(circle(0, 0, 0.030f));
		va = 0.002f * sign(frands());
		a = frand()*TAU;
		charge = 0;
		auto numSatellites = uniform!"[]"(2, 2+(ship.t / 10_000));

		//charge=int.min; x=0.25f;vx=0;vy=0.0001f; static int c=2; numSatellites=c++;

		foreach (i; 0..numSatellites)
			satellites ~= new ThingySatellite();

		add(Plane.Enemies);
	}

	override void step(uint deltaTicks)
	{
		for (int n=0; n<deltaTicks; n++)
		{
			if (x < 0.020f)
				vx = max(vx, -vx);
			if (x > 0.980f)
				vx = min(vx, -vx);
			super.step(1);
			if (y > 1.060f)
			{
				foreach (s; satellites)
					if (!s.dead)
						s.remove();
				remove();
				return;
			}
			a += va;

			if (!dead)
			{
				foreach (s; satellites)
					if (!s.dead)
						charge++;

				while (charge >= 2000)
				{
					charge -= 2000;
					if (ship && !ship.dead)
						new PlasmaOrb(this);
				}
			}
			else
			{
				death += 0.002f;
				if (death > 1)
					remove();
			}
		}

		uint level = 0;
		uint lastLevelCount = 1;
		void arrange(ThingySatellite[] satellites)
		{
			foreach (i, s; satellites)
			{
				auto sd = 0.040f + 0.025f*level + s.death*0.020f; // satellite distance
				auto sa = a + TAU*i/satellites.length + level*(TAU/lastLevelCount/2);
				s.x = x + sd*cos(sa);
				s.y = y + sd*sin(sa);
			}
			level++;
			lastLevelCount = cast(uint)satellites.length;
		}

		if (satellites.length <= 8)
			arrange(satellites[ 0.. $]);
		else
		if (satellites.length <= 12)
		{
			arrange(satellites[ 0.. 6]);
			arrange(satellites[ 6.. $]);
		}
		else
		if (satellites.length <= 24)
		{
			arrange(satellites[ 0.. 8]);
			arrange(satellites[ 8.. $]);
		}
		else
		if (satellites.length <= 32)
		{
			arrange(satellites[ 0.. 8]);
			arrange(satellites[ 8..16]);
			arrange(satellites[16.. $]);
		}
		else
		if (satellites.length <= 48)
		{
			arrange(satellites[ 0.. 8]);
			arrange(satellites[ 8..24]);
			arrange(satellites[24.. $]);
		}
		else
		if (satellites.length <= 64)
		{
			arrange(satellites[ 0.. 8]);
			arrange(satellites[ 8..24]);
			arrange(satellites[24..40]);
			arrange(satellites[40.. $]);
		}
		else
		{
			arrange(satellites[ 0.. 8]);
			arrange(satellites[ 8..24]);
			arrange(satellites[24..48]);
			arrange(satellites[48.. $]);
		}
	}

	override void die()
	{
		dead = true;
		foreach (s; satellites)
			s.dead = true;
		new Explosion(this, 0.060f);
	}
}

class ThingySatellite : ThingyPart
{
	this()
	{
		shapes ~= shape(circle(0, 0, 0.014f));
		add(Plane.Enemies);
	}

	override void step(uint deltaTicks)
	{
		if (dead)
		{
			death += 0.002f;
			if (death > 1)
				remove();
		}
	}

	override void die()
	{
		dead = true;
	}
}

class PlasmaOrb : Enemy
{
	int t;
	float death = 0f;

	this(Enemy parent)
	{
		this.x = parent.x;
		this.y = parent.y;
		shapes ~= shape(circle(0, 0, 0.008f));
		t = 0;
		vx = ship.x - parent.x;
		vy = ship.y - parent.y;
		float f = 0.0002f/dist(this.vx, this.vy);
		vx *= f;
		vy *= f;
		add(Plane.PlasmaOrbs);
	}

	override void step(uint deltaTicks)
	{
		super.step(deltaTicks);
		if (x<0 || x>1 || y<0 || y>1)
			return remove();
		if (!dead)
		{
			t += deltaTicks;
			shapes[0].circle.r  = 0.008f+0.002f*sin(t/100f);
		}
		else
		{
			shapes[0].circle.r += 0.000_050f;
			death += 0.005f;
			if (death >= 1f)
				remove();
		}
	}

	override void die()
	{
		dead = true;
	}

	override void render()
	{
		auto r = shapes[0].circle.r;
		auto brightness = 0.75f+0.25f*(-sin(t/100f));
		if (!dead)
			canvas.softCircle(cf(x), cf(y), cf(r-0.003f), cf(r), COLOR(canvas.tofracBounded(brightness)));
		else
		{
			brightness *= 1-(death/2);
			canvas.softRing(cf(x), cf(y), cf(death*r), cf(average(r, death*r)), cf(r), COLOR(canvas.tofracBounded(brightness)));
		}
	}
}

// *********************************************************

class Explosion : GameObject
{
	float size, maxt;
	int t;

	this(GameObject source, float size)
	{
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
				frand() *      // random factor
				(1-ed/size);   // distance factor
			new Splode(ex, ey, size/3*r);
		}
	}

	override void die() { assert(0); }

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
		const ra = 0.000_020f;
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
		//std.stdio.writeln([x, y, cr]);
		canvas.softCircle(cf(x), cf(y), max(0f, cf(cr)-1.5f), cf(cr), COLOR(canvas.tofracBounded(cr/r)));
	}
}
