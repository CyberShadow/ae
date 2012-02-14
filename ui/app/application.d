/**
 * ae.ui.app.application
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

module ae.ui.app.application;

import ae.sys.desktop;
import ae.sys.config;
import ae.ui.shell.events;
import ae.ui.video.renderer;

/// The purpose of this class is to allow the application to provide app-specific information to the framework.
// This class could theoretically be split up into more layers (ShellApplication, etc.)
class Application
{
	Config config;

	this()
	{
		config = new Config(getName(), getCompanyName());
	}

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

	void getDefaultFullScreenResolution(out uint x, out uint y)
	{
		static if (is(typeof(getDesktopResolution)))
			getDesktopResolution(x, y);
		else
			x = 1024, y = 768;
	}
	void getDefaultWindowSize(out uint x, out uint y) { x = 800; y = 600; }
	bool isFullScreenByDefault() { return false; }
	bool isResizable() { return true; }

	bool setFullScreen() { config.write("FullScreen", !isFullScreen()); return true; }
	bool setWindowSize(uint x, uint y) { config.write("WindowX", x); config.write("WindowY", y); return true; }

	void getFullScreenResolution(out uint x, out uint y)
	{
		getDefaultFullScreenResolution(x, y);
		x = config.read("FullScreenX", x);
		y = config.read("FullScreenY", y);
	}

	void getWindowSize(out uint x, out uint y)
	{
		getDefaultWindowSize(x, y);
		x = config.read("WindowX", x);
		y = config.read("WindowY", y);
	}

	bool isFullScreen()
	{
		return config.read("FullScreen", isFullScreenByDefault());
	}

	bool needSound() { return false; }
	bool needJoystick() { return false; }

	// ****************************** Event handlers *******************************

	//void handleMouseEnter() {}
	//void handleMouseLeave() {}
	//void handleKeyboardFocus() {}
	//void handleKeyboardBlur() {}
	//void handleMinimize() {}
	//void handleRestore() {}

	void handleKeyDown(Key key/*, modifiers? */, dchar character) {}
	void handleKeyUp(Key key/*, modifiers? */) {}

	void handleMouseDown(uint x, uint y, MouseButton button) {}
	void handleMouseUp(uint x, uint y, MouseButton button) {}
	void handleMouseMove(uint x, uint y, MouseButtons buttons) {}
	//void handleMouseRelMove(int dx, int dy) {} /// when cursor is clipped

	void handleJoyAxisMotion(int axis, short value) {}
	void handleJoyHatMotion (int hat, JoystickHatState state) {}
	void handleJoyButtonDown(int button) {}
	void handleJoyButtonUp  (int button) {}

	//void handleResize(uint w, uint h) {}
	void handleQuit() {}

	// ********************************* Rendering *********************************

	void render(Renderer r) {}
}

private __gshared Application application;

/// The application must call this function with its own Application implementation in a static constructor.
void createApplication(A : Application)()
{
	assert(application is null, "Application already set");
	application = new A;
}

// for use in ae.ui.app.*
int runApplication(string[] args)
{
	assert(application !is null, "Application object not set");
	return application.run(args);
}

/// Wraps a delegate that is to be called only from the application thread context.
struct AppCallbackEx(A...)
{
	private void delegate(A) f;

	void bind(void delegate(A) f)
	{
		this.f = f;
	}

	/// Blocks.
	void call(A args)
	{
		assert(f, "Attempting to call unbound AppCallback");
		synchronized(application)
		{
			f(args);
		}
	}

	bool opCast(T)()
		if (is(T == bool))
	{
		return f !is null;
	}
}

alias AppCallbackEx!() AppCallback;
