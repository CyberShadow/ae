/**
 * ae.ui.shell.shell
 *
 * License:
 *   This Source Code Form is subject to the terms of
 *   the Mozilla Public License, v. 2.0. If a copy of
 *   the MPL was not distributed with this file, You
 *   can obtain one at http://mozilla.org/MPL/2.0/.
 *
 * Authors:
 *   Vladimir Panteleev <ae@cy.md>
 */

module ae.ui.shell.shell;

import ae.ui.video.video;
import ae.ui.audio.audio;

/// A "shell" handles OS window management, input handling, and various other platform-dependent tasks.
class Shell
{
	/// Run the main loop.
	abstract void run();

	/// Set window title.
	abstract void setCaption(string caption);

	/// Request the event loop to stop.
	/// May be called from another thread.
	void quit()
	{
		if (!quitting)
		{
			quitting = true;
			prod();
		}
	}

	/// Wake event thread with a no-op event.
	abstract void prod();

	Video video; /// `Video` implementation.
	Audio audio; /// `Audio` implementation.

protected:
	bool quitting;
}

/// Specifies the window / screen mode.
enum ScreenMode
{
	windowed          , ///
	maximized         , ///
	fullscreen        , ///
	windowedFullscreen, ///
}

/// The default / remembered screen settings.
struct ShellSettings
{
	uint fullScreenX = 1024; /// Full-screen resolution.
	uint fullScreenY =  768; /// ditto
	uint windowSizeX =  800; /// Window size.
	uint windowSizeY =  600; /// ditto
	int windowPosX   = int.min; /// Windows position. `int.min` means unset.
	int windowPosY   = int.min; /// ditto
	ScreenMode screenMode = ScreenMode.windowed; /// Window / screen mode.
}
