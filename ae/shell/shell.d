module ae.shell.shell;

/// A "shell" handles OS window management, input handling, and various other platform-dependent tasks.
class Shell
{
	abstract void run();

	abstract void setCaption(string caption);

	void quit()
	{
		quitting = true;
	}

protected:
	bool quitting;
}

__gshared Shell shell;
