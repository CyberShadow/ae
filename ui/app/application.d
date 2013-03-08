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
import ae.ui.shell.shell;
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

	ShellSettings getDefaultShellSettings()
	{
		ShellSettings settings;
		static if (is(typeof(getDesktopResolution)))
			getDesktopResolution(settings.fullScreenX, settings.fullScreenY);
		return settings;
	}

	ShellSettings getShellSettings() { return config.read("ShellSettings", getDefaultShellSettings()); }
	void setShellSettings(ShellSettings settings) { config.write("ShellSettings", settings); }

	bool isResizable() { return true; }
	bool needSound() { return false; }
	bool needJoystick() { return false; }

	// ****************************** Event handlers *******************************

	//void handleMouseEnter() {}
	//void handleMouseLeave() {}
	//void handleKeyboardFocus() {}
	//void handleKeyboardBlur() {}
	//void handleMinimize() {}
	//void handleRestore() {}

	/// Called after video initialization.
	/// Video initialization currently also happens when the window is resized.
	/// The window size can be accessed via shell.video.getScreenSize.
	void handleInit() {}

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
