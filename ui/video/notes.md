Renderers
=========

Currently, we only only have SDL 1.2 support. [Addendum: there are now SDL and OpenGL renderers.]

SDL 1.2 apparently does most rendering in software. 
This is fine for most of our use cases, except smooth resizing.
Smooth resizing a large image in software is not fast enough for e.g. a fluid zoom animation.
Smooth resizing is also useful at zoom levels <1 - nearest-neighbor-downscaled images are quite ugly,
and realtime software downscaling, even at powers of two, is not feasable on older hardware at high resolutions.
Other perks that 3D acceleration provides is rotation - equally slow in software, but fast in hardware.

All of these are not available when using only SDL.
Not even SDL 1.3 provides smooth resizing, AFAICS.
Therefore, the best way to get these features is to use OpenGL directly.

The problem with using OpenGL directly is that the approach is quite different than when using software rendering.
For one thing, locking hardware surfaces is very expensive, and must be avoided.
SDL 1.3, which can use OpenGL as a hardware-accelerated backend, doesn't even allow locking static hardware textures, or blitting one hardware texture to another.
I'm not sure if/how that translates to the OpenGL API, of which I currently know very little.

Due to locking being expensive, optimal rendering paths can diverge considerably in software vs. hardware rendering.
Some graphics primitives (e.g. rounded rectangles) may be very simple to draw in a RAM bitmap (locked surface),
but require blitting some textures in hardware mode (when the primitive cannot be represented adequately using hardware primitives).

Possible options are:

1. Use only software rendering, and forego any niceties of hardware acceleration. This is the simplest option as far as development effort goes.
2. Use only OpenGL. This restricts the target platforms to those supporting OpenGL. Rendering stuff off-screen or without a GUI may be challenging or impossible.
3. Provide an abstraction which indicates the rendering mode.
   Thus, rendering code can choose whether to directly poke surface pixels if fast locking is available, or restrict itself to backend primitives.

There really isn't that much of a choice.


Textures
========

Logical textures
----------------

The application needs to provide the renderer with a data source (logical texture) for textures.
A "data source" would also allow automatically handling invalidated (lost) textures.

Due to the variety of graphics APIs and types of logical textures (static vs. procedural), there should be two methods available for obtaining pixel data from a logical texture:

1. Drawing pixel data onto pre-allocated pixel memory
2. Getting a pointer to existing pixel memory

For example, SDL textures allow locking to get a pixel memory pointer, which is ideal for the first method.
However, creating OpenGL textures involves passing a pointer to an OpenGL API function.

Similarly, a static bitmap likely already stores its data in memory, but a gradient texture may be more efficient without storing a copy of its output.
In most implementations, one method will be a short wrapper around the other.


Managing different renderers
----------------------------

Renderers need to cache renderer-specific data for each texture source, e.g. to store GPU texture handles.
One way to do it would be to make renderers have an associative array from each logical texture to its private data,
however that approach is slow and problematic.

It's easier to let each texture source have a pointer for renderer-specific data.
This breaks encapsulation somewhat (there needs to be an enum enumerating all renderers), 
and assumes there is at most one instance of any renderer type at any time, but seems like the overall best solution.


Managing destruction
--------------------

Destruction is complicated in a GC-ed environment, mainly due to the fact that some hardware resources are bound to the threads they were created in.
For example, OpenGL operations work on an implicit context, which can be tied to one single thread at a time.
However, the D garbage collector can call finalizers from arbitrary threads - therefore, hardware resources cannot be freed from inside class destructors.

It is safer to signal that a particular hardware resource needs to be freed by enqueuing it for delayed destruction.
Since all allocations inside destructors are currently forbidden, the simplest method is by setting a flag inside every renderer-specific data class tied to a logical texture.
The flag will be set when the GC destroys the logical texture, and the rendering thread will clean it up later.

The above plan relies on two conditions:

1. The renderer-specific data must not point back to the logical texture. This would create a cyclic reference.  
   This is not a problem, since applications pass renderers the logical textures when drawing, so renderers have access to both when it counts.
2. All renderer-specific data must also be reachable via a linked list, so that 
   1. all objects are reachable even when their logical texture "owner" is gone
   2. the GC never picks up stray objects and attempts to finalize them in the wrong thread.

----

	bool renderDataNeedsCleanup;

	/// Base class for all renderer-specific texture data
	class TextureRenderData
	{
		TextureRenderData next;
		bool destroyed;
	}

	/// Base class for logical textures
	class TextureSource
	{
		TextureRenderData[Renderers.max] renderData;

		uint textureVersion;

		// PixelInfo is a simple struct holding a pointer and e.g. stride.

		/// Used when the target pixel memory is already allocated
		abstract void drawTo(PixelInfo dest);

		/// Used when a pointer is needed to existing pixel memory
		abstract PixelInfo getPixels();

		~this()
		{
			foreach (r; renderData)
				if (r)
					r.destroyed = true;
			renderDataNeedsCleanup = true;
		}
	}


Fonts and text
==============

Questions:

* UI font config: passing around "Font" object, or font parameters (name/size)?
* Immediate or cached rendering?

Observations:

* UI font config: name is specified separately from size (scaling UIs) ?
* Text rendering is slow

Requirements:

* Caching fonts
* Caching rendered text

Necessities:

* ~~Font manager (AA by name/size)~~
* Font object for just the size
  * avoids AA lookups
  * provides encapsulation, avoids using globals
* Object encapsulating a "rendered text" surface
