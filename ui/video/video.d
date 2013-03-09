/**
 * ae.ui.video.video
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

module ae.ui.video.video;

import ae.ui.app.application;

class Video
{
public:
	/// Start driver (Application dictates settings).
	abstract void start(Application application);

	/// Stop driver (may block).
	abstract void stop();

	/// Stop driver (asynchronous).
	abstract void stopAsync(AppCallback callback);

	/// Shutdown (de-initialize) video driver. Blocks.
	abstract void shutdown();

	/// Query the window size that's currently running.
	/// This is different from the information in ShellSettings
	/// in that it returns the current client area regardless
	/// of the screen mode.
	abstract void getScreenSize(out uint width, out uint height);

	/// Shell hooks.
	AppCallback errorCallback;
}
