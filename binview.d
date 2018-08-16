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
	uint zoom = 4;

	override void render(Renderer s)
	{
		if (dirty == 0 && s.width == lastWidth && s.height == lastHeight)
			return;

		s.clear();
		this.height = s.height / zoom;

		shell.setCaption(format("Offset = 0x%08X Width=0x%X (%d) BPP=%d", offset, width, width, bpp));

		auto start = min(offset, f.length);
		auto length = width * height;
		auto end = min(offset + length * bpp, f.length);

		auto data = f[start .. end];
		data = data[0 .. $ - $ % bpp];

		foreach (i; 0 .. data.length / bpp)
		{
			auto bytes = cast(ubyte[])data[i * bpp .. (i+1) * bpp];
			if (bytes.canFind!identity) // leave 0 as black
			{
				BGRX p;
				if (bpp > 3)
				{
					auto c = crc32Of(bytes);
					p = BGRX(c[0], c[1], c[2]);
				}
				else
				{
					ubyte[3] channels;
					foreach (n, ref c; channels)
						c = bytes[n % $];
					p = BGRX(channels[0], channels[1], channels[2]);
				}

				auto x = cast(int)(i % width);
				auto y = cast(int)(i / width);
				s.fillRect(x * zoom, y * zoom, (x+1) * zoom, (y+1) * zoom, p);
			}
		}

		dirty--;
		lastWidth = s.width;
		lastHeight = s.height;
	}

	override int run(string[] args)
	{
		shell = new SDL2Shell(this);
		shell.video = new SDL2SoftwareVideo();
		shell.run();
		shell.video.shutdown();
		return 0;
	}

	void navigate(uint bytes, bool forward)
	{
		if (forward)
			offset = min(offset + bytes, f.length);
		else
			offset = offset > bytes ? offset - bytes : 0;
	}

	override void handleKeyDown(Key key, dchar character)
	{
		switch (key)
		{
			case Key.esc:
				shell.quit();
				break;
			case Key.left    : navigate(          1         , false); break;
			case Key.right   : navigate(          1         , true ); break;
			case Key.up      : navigate(width * bpp         , false); break;
			case Key.down    : navigate(width * bpp         , true ); break;
			case Key.pageUp  : navigate(width * height * bpp, false); break;
			case Key.pageDown: navigate(width * height * bpp, true ); break;
			case Key.home    : width = width ? width-1 : 0; break;
			case Key.end     : width++; break;
			default:
				switch (character)
				{
					case '1':
						..
					case '9':
						bpp = character - '0';
						break;
					case '+':
					case '=':
						zoom++;
						break;
					case '-':
						if (zoom > 1)
							zoom--;
						break;
					default:
						return;
				}
		}
		dirty = 3;
	}

	override void handleMouseMove(uint x, uint y, MouseButtons buttons)
	{
		auto addr = offset + ((y / zoom) * width + (x / zoom)) * bpp;
		shell.setCaption(format("x=%d y=%d addr=%08X data=%(%02X %)",
				x / zoom, y / zoom, addr, (addr+bpp) < f.length ? cast(ubyte[])f[addr..addr+bpp] : null));
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
