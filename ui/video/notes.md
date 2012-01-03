Currently, we only only have SDL 1.2 support.

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