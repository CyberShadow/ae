module ae.core.application;

import ae.os.os;

/// The purpose of this class is to allow the application to provide app-specific information to the framework.
class Application
{
	/// Returns a string containing the application name, as visible in the window caption and taskbar, and used in filesystem/registry paths.
	abstract string getName();

	/// Returns the company name (used for Windows registry paths).
	abstract string getCompanyName();

	// TODO: getIcon
	
	/// The application "main" function. The application can create a shell here.
	abstract int run(string[] args);

	/// Called after the shell is initialised, before the message loop.
	abstract void initialise();

	/// Default screen settings.
	void getDefaultFullScreenResolution(out int x, out int y) { return OS.getDefaultResolution(x, y); }
	void getDefaultWindowSize(out int x, out int y) { x = 1024; y = 768; }
	bool isFullScreenByDefault() { return false; }
}

/// The application must initialise this with an instance of an Application implementation in a static constructor.
Application application;
