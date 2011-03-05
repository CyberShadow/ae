module ae.shell.shell;

/// A "shell" handles OS window management, input handling, and various other platform-dependent tasks.
class Shell
{
	abstract void run();

	void quit()
	{
		quitting = true;
	}

private:
	bool quitting;
}

Shell shell;
