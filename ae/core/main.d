/// OS-dependent entry point.
module ae.core.main;

version(Windows)
	import ae.core.windows.main;
else
	import ae.core.posix.main;

import ae.core.application;

int ngmain(string[] args)
{
	if (application is null)
		throw new Exception("Application object not set");
	return application.run(args);
}
