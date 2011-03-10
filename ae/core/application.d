module ae.core.application;

import ae.os.os;
import ae.shell.events;

/// The purpose of this class is to allow the application to provide app-specific information to the framework.
class Application
{
	// ************************** Application information **************************

	/// Returns a string containing the application name, as visible in the window caption and taskbar, and used in filesystem/registry paths.
	abstract string getName();

	/// Returns the company name (used for Windows registry paths).
	abstract string getCompanyName();

	// TODO: getIcon

	// ******************************** Entry point ********************************

	/// The application "main" function. The application can create a shell here.
	abstract int run(string[] args);

	// ************************** Default screen settings **************************

	void getDefaultFullScreenResolution(out uint x, out uint y) { return OS.getDefaultResolution(x, y); }
	void getDefaultWindowSize(out uint x, out uint y) { x = 800; y = 600; }
	bool isFullScreenByDefault() { return false; }

	void getFullScreenResolution(out uint x, out uint y)
	{
		getDefaultFullScreenResolution(x, y);
		x = OS.Config.read("FullScreenX", x);
		y = OS.Config.read("FullScreenY", y);
	}

	void getWindowSize(out uint x, out uint y)
	{
		getDefaultWindowSize(x, y);
		x = OS.Config.read("WindowX", x);
		y = OS.Config.read("WindowY", y);
	}

	bool isFullScreen()
	{
		return OS.Config.read("FullScreen", isFullScreenByDefault());
	}

	// ****************************** Event handlers *******************************

	//void handleMouseEnter() {}
	//void handleMouseLeave() {}
	//void handleKeyboardFocus() {}
	//void handleKeyboardBlur() {}
	//void handleMinimize() {}
	//void handleRestore() {}

	//void handleKeyDown(Key key/*, modifiers? */, dchar character) {}
	//void handleKeyUp(Key key/*, modifiers? */) {}

	//void handleMouseMove(uint x, uint y) {}
	//void handleMouseRelMove(int dx, int dy) {} /// when cursor is clipped
	void handleMouseDown(uint x, uint y, MouseButton button) {}
	void handleMouseUp(uint x, uint y, MouseButton button) {}

	//void handleResize(uint w, uint h) {}
	void handleQuit() {}
}

/// The application must initialise this with an instance of an Application implementation in a static constructor.
__gshared Application application;
