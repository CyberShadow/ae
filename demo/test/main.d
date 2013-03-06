/**
 * ae.demo.test.main
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

module ae.demo.test.main;

import ae.ui.app.application;
import ae.ui.app.posix.main;
import ae.ui.shell.shell;
import ae.ui.shell.sdl.shell;
import ae.ui.video.video;
import ae.ui.video.sdl.video;
import ae.ui.wm.application;

import ae.demo.test.mycontrol;

final class MyApplication : WMApplication
{
	override string getName() { return "Demo/Test"; }
	override string getCompanyName() { return "CyberShadow"; }
	override bool isResizable() { return false; }

	override int run(string[] args)
	{
		shell = new SDLShell(this);
		shell.video = new SDLVideo();
		root.addChild(new MyControl(shell));
		shell.run();
		shell.video.shutdown();
		return 0;
	}
}

shared static this()
{
	createApplication!MyApplication();
}
