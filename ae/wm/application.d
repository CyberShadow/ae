module ae.wm.application;

import ae.core.application;
import ae.shell.shell;

class WMApplication : Application
{
	override void handleQuit()
	{
		shell.quit();
	}
}
