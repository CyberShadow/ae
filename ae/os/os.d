module ae.os.os;

version(Windows)
	public import ae.os.windows.windows;
else
	public import ae.os.posix.posix;

/// Abstract interface for OS-dependent actions
struct DefaultOS
{
	void getDefaultResolution(out uint x, out uint y)
	{
		x = 1024;
		y = 768;
	}
}
