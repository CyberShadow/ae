module ae.video.video;

class Video
{
	/// Initialise video.
	abstract void initialize();

	/// Start render thread.
	abstract void start();

	/// Stop render thread (may block).
	abstract void stop();
}

__gshared Video video;
