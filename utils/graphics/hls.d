module ae.utils.graphics.hls;

import ae.utils.math;

/// RGB <-> HLS conversion
/// based on http://support.microsoft.com/kb/29240

struct HLS(COLOR, HLSTYPE=ushort, HLSTYPE HLSMAX=240)
{
	static assert(HLSMAX <= ushort.max, "TODO");

	// H,L, and S vary over 0-HLSMAX
	// HLSMAX BEST IF DIVISIBLE BY 6

	alias COLOR.BaseType RGBTYPE;

	// R,G, and B vary over 0-RGBMAX
	enum RGBMAX = RGBTYPE.max;

	// Hue is undefined if Saturation is 0 (grey-scale)
	// This value determines where the Hue scrollbar is
	// initially set for achromatic colors
	enum UNDEFINED = HLSMAX*2/3;

	void toHLS(COLOR rgb, out HLSTYPE h, out HLSTYPE l, out HLSTYPE s)
	{
		ushort Rdelta,Gdelta,Bdelta;

		auto R = rgb.r;
		auto G = rgb.g;
		auto B = rgb.b;

		/* calculate lightness */
		auto cMax = max( max(R,G), B); /* max and min RGB values */
		auto cMin = min( min(R,G), B);
		l = ( ((cMax+cMin)*HLSMAX) + RGBMAX )/(2*RGBMAX);

		if (cMax == cMin)              /* r=g=b --> achromatic case */
		{
			s = 0;                     /* saturation */
			h = UNDEFINED;             /* hue */
		}
		else                           /* chromatic case */
		{
			/* saturation */
			if (l <= (HLSMAX/2))
				s = cast(HLSTYPE)(( ((cMax-cMin)*HLSMAX) + ((cMax+cMin)/2) ) / (cMax+cMin));
			else
				s = cast(HLSTYPE)(( ((cMax-cMin)*HLSMAX) + ((2*RGBMAX-cMax-cMin)/2) )
				   / (2*RGBMAX-cMax-cMin));

			/* hue */
			auto Rdelta = ( ((cMax-R)*(HLSMAX/6)) + ((cMax-cMin)/2) ) / (cMax-cMin); /* intermediate value: % of spread from max */
			auto Gdelta = ( ((cMax-G)*(HLSMAX/6)) + ((cMax-cMin)/2) ) / (cMax-cMin);
			auto Bdelta = ( ((cMax-B)*(HLSMAX/6)) + ((cMax-cMin)/2) ) / (cMax-cMin);

			if (R == cMax)
				h = cast(HLSTYPE)(Bdelta - Gdelta);
			else if (G == cMax)
				h = cast(HLSTYPE)((HLSMAX/3) + Rdelta - Bdelta);
			else /* B == cMax */
				h = cast(HLSTYPE)(((2*HLSMAX)/3) + Gdelta - Rdelta);

			if (h < 0)
				h += HLSMAX;
			if (h > HLSMAX)
				h -= HLSMAX;
		}
	}

	/* utility routine for HLStoRGB */
	private HLSTYPE hueToRGB(HLSTYPE n1,HLSTYPE n2,HLSTYPE hue)
	{
		/* range check: note values passed add/subtract thirds of range */
		if (hue < 0)
			hue += HLSMAX;

		if (hue > HLSMAX)
			hue -= HLSMAX;

		/* return r,g, or b value from this tridrant */
		if (hue < (HLSMAX/6))
			return cast(HLSTYPE)( n1 + (((n2-n1)*hue+(HLSMAX/12))/(HLSMAX/6)) );
		if (hue < (HLSMAX/2))
			return cast(HLSTYPE)( n2 );
		if (hue < ((HLSMAX*2)/3))
			return cast(HLSTYPE)( n1 +    (((n2-n1)*(((HLSMAX*2)/3)-hue)+(HLSMAX/12))/(HLSMAX/6)));
		else
			return cast(HLSTYPE)( n1 );
	}

	COLOR fromHLS(HLSTYPE hue, HLSTYPE lum, HLSTYPE sat)
	{
		COLOR c;
		HLSTYPE Magic1, Magic2;       /* calculated magic numbers (really!) */

		if (sat == 0) {            /* achromatic case */
			c.r = c.g = c.b = cast(RGBTYPE)((lum*RGBMAX)/HLSMAX);
			assert(hue == UNDEFINED);
		}
		else  {                    /* chromatic case */
			/* set up magic numbers */
			if (lum <= (HLSMAX/2))
				Magic2 = cast(HLSTYPE)((lum*(HLSMAX + sat) + (HLSMAX/2))/HLSMAX);
			else
				Magic2 = cast(HLSTYPE)(lum + sat - ((lum*sat) + (HLSMAX/2))/HLSMAX);
			Magic1 = cast(HLSTYPE)(2*lum-Magic2);

			/* get RGB, change units from HLSMAX to RGBMAX */
			c.r = cast(RGBTYPE)((hueToRGB(Magic1,Magic2,cast(HLSTYPE)(hue+(HLSMAX/3)))*RGBMAX + (HLSMAX/2))/HLSMAX);
			c.g = cast(RGBTYPE)((hueToRGB(Magic1,Magic2,cast(HLSTYPE)(hue           ))*RGBMAX + (HLSMAX/2))/HLSMAX);
			c.b = cast(RGBTYPE)((hueToRGB(Magic1,Magic2,cast(HLSTYPE)(hue-(HLSMAX/3)))*RGBMAX + (HLSMAX/2))/HLSMAX);
		}
		return c;
	}
}

unittest
{
	import ae.utils.graphics.canvas;
	HLS!RGB hls;
	auto red = hls.fromHLS(0, 120, 240);
	assert(red == RGB(255, 0, 0));
	ushort h,l,s;
	hls.toHLS(red, h, l, s);
	assert(h==0 && l==120 && s==240);
}

unittest
{
	import ae.utils.graphics.canvas;
	enum MAX = 30_000;
	HLS!(RGB, int, MAX) hls;
	auto red = hls.fromHLS(0, MAX/2, MAX);
	assert(red == RGB(255, 0, 0));

	int h,l,s;
	hls.toHLS(red, h, l, s);
	assert(h==0 && l==MAX/2 && s==MAX);
}
