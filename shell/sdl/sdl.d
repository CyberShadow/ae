module ae.shell.sdl.sdl;

import std.conv;

import derelict.sdl.sdl;

import ae.shell.shell;

final class SDLShell : Shell
{
	void initVideo()
	{
		auto surface = SDL_GetVideoSurface();
		if (surface)
			SDL_FreeSurface(surface);

		if (fullScreen)
		{
			search:
			for (int size=0;;size++)
				for (int x=WIDTH;x<=WIDTH+size;x++)
				{
					int y = HEIGHT + size-(x-WIDTH);
					if (SDL_VideoModeOK(x, y, 8, SDL_HWSURFACE | SDL_HWPALETTE | SDL_FULLSCREEN))
					{
						//writefln(x, " ", y);
						screenWidth  = x;
						screenHeight = y;
						break search;
					}
				}
		}
		else
			screenWidth  = WIDTH,
			screenHeight = HEIGHT;

		surface = SDL_SetVideoMode( screenWidth, screenHeight, 8, SDL_HWSURFACE | SDL_HWPALETTE | (fullScreen?SDL_FULLSCREEN:0) );
		if ( !surface )
			throw new Exception("SDL video mode failed: " ~ toString(SDL_GetError()));

		setPalette();

		SDL_ShowCursor(!fullScreen || needsMouse);
	}

	override void run()
	{
		DerelictSDL.load();
		//DerelictSDLMixer.load();

		if ( SDL_Init( SDL_INIT_VIDEO | SDL_INIT_AUDIO ) < 0)
			throw new Exception("SDL initialization failed: " ~ to!string(SDL_GetError()));

		setTitle(title);

		SDL_EnableKeyRepeat(SDL_DEFAULT_REPEAT_DELAY, SDL_DEFAULT_REPEAT_INTERVAL);

		foreach(handler;handleLoad)
			handler();
		
		auto lastTicks = SDL_GetTicks();
		bool done;
		int frame;
		while( !quitting )
		{	
			char* sdl_error;												//SDL error storaging variable
			SDL_Event event;												//SDL event storing variable

			uint ticks = SDL_GetTicks();
			renderer(ticks - lastTicks);
 
			auto surface = SDL_GetVideoSurface();
			if ( SDL_MUSTLOCK( surface ) )
				if ( SDL_LockSurface( surface ) < 0 )
					throw new Exception("Lock failed");
 
			if (fullScreen)
				for(int y=0;y<HEIGHT;y++)
				{
					auto row = cast(ubyte*)surface.pixels + (screenWidth*(y+(screenHeight-HEIGHT)/2) + (screenWidth-WIDTH)/2);
					row[0..WIDTH] = mainscreen[y][];
				}
			else
				(cast(ubyte[WIDTH]*)surface.pixels)[0..HEIGHT] = mainscreen[];

			if ( SDL_MUSTLOCK( surface ) ) 
				SDL_UnlockSurface( surface );

			SDL_Flip( surface );
			
			sdl_error = SDL_GetError( );								//Check for SDL error conditions.	
			if( sdl_error[0] != 0 )
				throw new Exception("SDL error: " ~ .toString(sdl_error));	//If we got DLL errors, print 
		
			SDL_Delay( 0 );												//Set a delay, usefull on really fast Computers
			while( SDL_PollEvent( &event ) )						  //Check if there's a pending event.
				done = done || HandleEvent(&event);						  //Handle them.
			
			frame++;
			if (lastTicks/1000 != ticks/1000)
			{
				writef("%5d FPS (%8dns)\r", frame, 1000000/frame); fflush(stdout);
				frame=0;
			}
			lastTicks = ticks;
		}
		SDL_Quit();
	}
}
