/// OS-dependent entry point.
module ae.app.main;

version(Windows)
	import ae.app.windows.main;
else
	import ae.app.posix.main;

import ae.app.application;

int ngmain(string[] args)
{
	if (application is null)
		throw new Exception("Application object not set");
	return application.run(args);
}
