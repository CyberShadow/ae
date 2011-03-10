module ae.video.surface;

/// Abstract class for a video surface.
class Surface
{
	struct Bitmap
	{
		uint* pixels;
		uint w, h, stride;

		uint* pixelPtr(uint x, uint y)
		{
			assert(x<w && y<h);
			return cast(uint*)(cast(ubyte*)pixels + y*stride) + x;
		}
		
		uint opIndex(uint x, uint y)
		{
			return *pixelPtr(x, y);
		}
		
		void opIndexAssign(uint value, uint x, uint y)
		{
			*pixelPtr(x, y) = value;
		}
	}

	abstract Bitmap lock();
	abstract void unlock();
}
