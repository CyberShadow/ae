/// OS-dependent entry point.
module ng.core.main;

version(Windows)
	import ng.core.windows.main;
else
	import ng.core.posix.main;

import ng.core.application;

int ngmain(string[] args)
{
	if (application is null)
		throw new Exception("Application object not set");
	return application.run(args);
}
