module ae.shell.events;

enum Key
{
	Esc
}

enum MouseButton : ubyte
{
	Left,
	Right,
	Middle,
	WheelUp,
	WheelDown,
	Max
}

enum MouseButtons : ubyte
{
	None = 0,
	Left      = 1<<0,
	Right     = 1<<1,
	Middle    = 1<<2,
	WheelUp   = 1<<3,
	WheelDown = 1<<4
}
