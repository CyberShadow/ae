module demo.test.main;

import ae.core.application;
import ae.core.main;
import ae.shell.shell;
import ae.shell.sdl.shell;
import ae.video.video;
import ae.video.sdl.video;
import ae.wm.application;

import demo.test.mycontrol;

final class MyApplication : WMApplication
{
	override string getName() { return "Demo/Test"; }
	override string getCompanyName() { return "CyberShadow"; }

	override int run(string[] args)
	{
		shell = new SDLShell();
		video = new SDLVideo();
		root.children ~= new MyControl();
		shell.run();
		return 0;
	}
}

shared static this()
{
	application = new MyApplication;
}
