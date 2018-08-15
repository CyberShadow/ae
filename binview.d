import core.runtime;
import core.time;

import std.algorithm.comparison;
import std.algorithm.searching;
import std.conv;
import std.digest.crc;
import std.exception;
import std.format;
import std.math;
import std.mmfile;

import ae.ui.app.application;
import ae.ui.app.main;
import ae.ui.shell.shell;
import ae.ui.shell.sdl2.shell;
import ae.ui.video.bmfont;
import ae.ui.video.renderer;
import ae.ui.video.sdl2.video;
import ae.utils.fps;
import ae.utils.graphics.fonts.draw;
import ae.utils.graphics.fonts.font8x8;
import ae.utils.math;
import ae.utils.graphics.image;
import ae.utils.meta;

final class MyApplication : Application
{
	override string getName() { return "Albion/BinView"; }
	override string getCompanyName() { return "CyberShadow"; }

	Shell shell;

	MmFile f;

	this()
	{
		enforce(Runtime.args.length == 2, "Usage: binview FILENAME");
		f = new MmFile(Runtime.args[1]);
	}

	size_t offset = 0;
	uint width = 256, height;

	uint dirty = 3;
	uint lastWidth, lastHeight;
	uint bpp = 1;

	override void render(Renderer s)
	{
		if (dirty == 0 && s.width == lastWidth && s.height == lastHeight)
			return;

		s.clear();
		this.height = s.height;

		shell.setCaption(format("Offset = 0x%08X Width=0x%X (%d)", offset, width, width));

		auto start = min(offset, f.length);
		auto length = width * height;
		auto end = min(offset + length * bpp, f.length);

		auto data = f[start .. end];
		data = data[0 .. $ - $ % bpp];

		foreach (i; 0..length)
		{
			auto bytes = cast(ubyte[])data[i * bpp .. (i+1) * bpp];
			if (bytes.canFind!identity) // leave 0 as black
			{
				auto c = crc32Of(bytes);
				s.putPixel(cast(int)(i % width), cast(int)(i / width), BGRX(c[0], c[1], c[2]));
			}
		}

		dirty--;
		lastWidth = s.width;
		lastHeight = s.height;
	}

	override int run(string[] args)
	{
		shell = new SDL2Shell(this);
		shell.video = new SDL2Video();
		shell.run();
		shell.video.shutdown();
		return 0;
	}

	override void handleKeyDown(Key key, dchar character)
	{
		switch (key)
		{
			case Key.esc:
				shell.quit();
				break;
			case Key.left:
				offset = offset > 0            ? offset - 1            : 0;
				break;
			case Key.right:
				offset += 1;
				break;
			case Key.up:
				offset = offset > width        ? offset - width        : 0;
				break;
			case Key.down:
				offset += width;
				break;
			case Key.pageUp:
				offset = offset > width*height ? offset - width*height : 0;
				break;
			case Key.pageDown:
				offset += width*height;
				break;
			case Key.home:
				width = width ? width-1 : 0;
				break;
			case Key.end:
				width++;
				break;
			default:
				switch (character)
				{
					case '1':
						..
					case '9':
						bpp = character - '0';
						break;
					default:
						return;
				}
		}
		dirty = 3;
	}

	override void handleQuit()
	{
		shell.quit();
	}
}

shared static this()
{
	createApplication!MyApplication();
}
