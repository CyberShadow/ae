module ng.os.os;

version(Windows)
	public import ng.os.windows.windows;
else
	public import ng.os.posix.posix;

/// Abstract interface for OS-dependent actions
struct DefaultOS
{
	void getDefaultResolution(out int x, out int y)
	{
		x = 1024;
		y = 768;
	}
}
