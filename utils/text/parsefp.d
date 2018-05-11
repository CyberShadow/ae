// Written in the D programming language.

/**
Pure D code to parse floating-point values.
Adapted to nothrow/@nogc from std.conv.

Copyright: Copyright Digital Mars 2007-.

License:   $(HTTP boost.org/LICENSE_1_0.txt, Boost License 1.0).

Authors:   $(HTTP digitalmars.com, Walter Bright),
           $(HTTP erdani.org, Andrei Alexandrescu),
           Shin Fujishiro,
           Adam D. Ruppe,
           Kenji Hara,
           Vladimir Panteleev <vladimir@thecybershadow.net>
*/

module ae.utils.text.parsefp;

import std.exception : enforce;
import std.range.primitives;
import std.traits;

/**
 * Parses a character range to a floating point number.
 *
 * Params:
 *     source = the lvalue of the range to _parse
 *     target = floating point value to store the result in
 *
 * Returns:
 *     `true` if a number was successfully parsed.
 */
bool tryParse(Source, Target)(ref Source source, out Target target) pure nothrow @nogc
if (isInputRange!Source && isSomeChar!(ElementType!Source) && !is(Source == enum) &&
    isFloatingPoint!Target && !is(Target == enum))
{
    import core.stdc.math : HUGE_VAL;
    import std.ascii : isDigit, isAlpha, toLower, toUpper, isHexDigit;
    import std.exception : enforce;

    static if (isNarrowString!Source)
    {
        import std.string : representation;
        auto p = source.representation;
    }
    else
    {
        alias p = source;
    }

    static immutable real[14] negtab =
        [ 1e-4096L,1e-2048L,1e-1024L,1e-512L,1e-256L,1e-128L,1e-64L,1e-32L,
                1e-16L,1e-8L,1e-4L,1e-2L,1e-1L,1.0L ];
    static immutable real[13] postab =
        [ 1e+4096L,1e+2048L,1e+1024L,1e+512L,1e+256L,1e+128L,1e+64L,1e+32L,
                1e+16L,1e+8L,1e+4L,1e+2L,1e+1L ];

    if (p.empty) return false;

    bool sign = false;
    switch (p.front)
    {
    case '-':
        sign = true;
        p.popFront();
        if (p.empty) return false;
        if (toLower(p.front) == 'i')
            goto case 'i';
        if (p.empty) return false;
        break;
    case '+':
        p.popFront();
        if (p.empty) return false;
        break;
    case 'i': case 'I':
        p.popFront();
        if (p.empty) return false;
        if (toLower(p.front) == 'n')
        {
            p.popFront();
            if (p.empty) return false;
            if (toLower(p.front) == 'f')
            {
                // 'inf'
                p.popFront();
                static if (isNarrowString!Source)
                    source = cast(Source) p;
                target = sign ? -Target.infinity : Target.infinity;
                return true;
            }
        }
        goto default;
    default: {}
    }

    bool isHex = false;
    bool startsWithZero = p.front == '0';
    if (startsWithZero)
    {
        p.popFront();
        if (p.empty)
        {
            static if (isNarrowString!Source)
                source = cast(Source) p;
            target = sign ? -0.0 : 0.0;
            return true;
        }

        isHex = p.front == 'x' || p.front == 'X';
    }

    real ldval = 0.0;
    char dot = 0;                        /* if decimal point has been seen */
    int exp = 0;
    long msdec = 0, lsdec = 0;
    ulong msscale = 1;

    if (isHex)
    {
        /*
         * The following algorithm consists of mainly 3 steps (and maybe should
         * be refactored into functions accordingly)
         * 1) Parse the textual input into msdec and exp variables:
         *    input is 0xaaaaa...p+000... where aaaa is the mantissa in hex and
         *    000 is the exponent in decimal format.
         * 2) Rounding, ...
         * 3) Convert msdec and exp into native real format
         */

        int guard = 0;
        // Used to enforce that any mantissa digits are present
        bool anydigits = false;
        // Number of mantissa digits (digit: base 16) we have processed,
        // ignoring leading 0s
        uint ndigits = 0;

        p.popFront();
        while (!p.empty)
        {
            int i = p.front;
            while (isHexDigit(i))
            {
                anydigits = true;
                /*
                 * convert letter to binary representation: First clear bit
                 * to convert lower space chars to upperspace, then -('A'-10)
                 * converts letter A to 10, letter B to 11, ...
                 */
                i = isAlpha(i) ? ((i & ~0x20) - ('A' - 10)) : i - '0';
                // 16*4 = 64: The max we can store in a long value
                if (ndigits < 16)
                {
                    // base 16: Y = ... + y3*16^3 + y2*16^2 + y1*16^1 + y0*16^0
                    msdec = msdec * 16 + i;
                    // ignore leading zeros
                    if (msdec)
                        ndigits++;
                }
                // All 64 bits of the long have been filled in now
                else if (ndigits == 16)
                {
                    while (msdec >= 0)
                    {
                        exp--;
                        msdec <<= 1;
                        i <<= 1;
                        if (i & 0x10)
                            msdec |= 1;
                    }
                    guard = i << 4;
                    ndigits++;
                    exp += 4;
                }
                else
                {
                    guard |= i;
                    exp += 4;
                }
                exp -= dot;
                p.popFront();
                if (p.empty)
                    break;
                i = p.front;
                if (i == '_')
                {
                    p.popFront();
                    if (p.empty)
                        break;
                    i = p.front;
                }
            }
            if (i == '.' && !dot)
            {
                p.popFront();
                dot = 4;
            }
            else
                break;
        }

        // Round up if (guard && (sticky || odd))
        if (guard & 0x80 && (guard & 0x7F || msdec & 1))
        {
            msdec++;
            if (msdec == 0)                 // overflow
            {
                msdec = 0x8000000000000000L;
                exp++;
            }
        }

        // Have we seen any mantissa digits so far?
        if (!anydigits) return false;
        if(p.empty || (p.front != 'p' && p.front != 'P'))
            return false; // Floating point parsing: exponent is required
        char sexp;
        int e;

        sexp = 0;
        p.popFront();
        if (!p.empty)
        {
            switch (p.front)
            {
                case '-':    sexp++;
                             goto case;
                case '+':    p.popFront(); if (p.empty) return false;
                             break;
                default: {}
            }
        }
        ndigits = 0;
        e = 0;
        while (!p.empty && isDigit(p.front))
        {
            if (e < 0x7FFFFFFF / 10 - 10) // prevent integer overflow
            {
                e = e * 10 + p.front - '0';
            }
            p.popFront();
            ndigits = 1;
        }
        exp += (sexp) ? -e : e;
        if (!ndigits) return false;

        //import std.math : floatTraits, RealFormat;

        static if (floatTraits!real.realFormat == RealFormat.ieeeQuadruple)
        {
            if (msdec)
            {
                /*
                 * For quad precision, we currently allow max mantissa precision
                 * of 64 bits, simply so we don't have to change the mantissa parser
                 * in the code above. Feel free to adapt the parser to support full
                 * 113 bit precision.
                 */

                // Exponent bias + 112:
                // After shifting 112 times left, exp must be 1
                int e2 = 0x3FFF + 112;

                /*
                 * left justify mantissa: The implicit bit (bit 112) must be 1
                 * after this, (it is implicit and always defined as 1, so making
                 * sure we end up with 1 at 112 means we adjust mantissa and eponent
                 * to fit the ieee format)
                 * For quadruple, this is especially fun as we have to use 2 longs
                 * to store the mantissa and care about endianess...
                 * quad_mant[0]               | quad_mant[1]
                 * S.EEEEEEEEEEEEEEE.MMMMM .. | MMMMM .. 00000
                 *                48       0  |
                 */
                ulong[2] quad_mant;
                quad_mant[1] = msdec;
                while ((quad_mant[0] & 0x0001_0000_0000_0000) == 0)
                {
                    // Shift high part one bit left
                    quad_mant[0] <<= 1;
                    // Transfer MSB from quad_mant[1] as new LSB
                    quad_mant[0] |= (quad_mant[1] & 0x8000_0000_0000_0000) ? 0b1 : 0b0;
                    // Now shift low part one bit left
                    quad_mant[1] <<= 1;
                    // Finally, decrease the exponent, as we increased the value
                    // by shifting of the mantissa
                    e2--;
                }

                ()@trusted {
                    ulong* msw, lsw;
                    version (LittleEndian)
                    {
                        lsw = &(cast(ulong*)&ldval)[0];
                        msw = &(cast(ulong*)&ldval)[1];
                    }
                    else
                    {
                        msw = &(cast(ulong*)&ldval)[0];
                        lsw = &(cast(ulong*)&ldval)[1];
                    }

                    // Stuff mantissa directly into double
                    // (first including implicit bit)
                    *msw = quad_mant[0];
                    *lsw = quad_mant[1];

                    // Store exponent, now overwriting implicit bit
                    *msw &= 0x0000_FFFF_FFFF_FFFF;
                    *msw |= ((e2 & 0xFFFFUL) << 48);
                }();

                import std.math : ldexp;

                // Exponent is power of 2, not power of 10
                ldval = ldexp(ldval, exp);
            }
        }
        else static if (floatTraits!real.realFormat == RealFormat.ieeeExtended)
        {
            if (msdec)
            {
                int e2 = 0x3FFF + 63;

                // left justify mantissa
                while (msdec >= 0)
                {
                    msdec <<= 1;
                    e2--;
                }

                // Stuff mantissa directly into real
                ()@trusted{ *cast(long*)&ldval = msdec; }();
                ()@trusted{ (cast(ushort*)&ldval)[4] = cast(ushort) e2; }();

                import std.math : ldexp;

                // Exponent is power of 2, not power of 10
                ldval = ldexp(ldval,exp);
            }
        }
        else static if (floatTraits!real.realFormat == RealFormat.ieeeDouble)
        {
            if (msdec)
            {
                // Exponent bias + 52:
                // After shifting 52 times left, exp must be 1
                int e2 = 0x3FF + 52;

                // right justify mantissa
                // first 11 bits must be zero, rest is implied bit + mantissa
                // shift one time less, do rounding, shift again
                while ((msdec & 0xFFC0_0000_0000_0000) != 0)
                {
                    msdec  = ((cast(ulong) msdec) >> 1);
                    e2++;
                }

                // Have to shift one more time
                // and do rounding
                if ((msdec & 0xFFE0_0000_0000_0000) != 0)
                {
                    auto roundUp = (msdec & 0x1);

                    msdec  = ((cast(ulong) msdec) >> 1);
                    e2++;
                    if (roundUp)
                    {
                        msdec += 1;
                        // If mantissa was 0b1111... and we added +1
                        // the mantissa should be 0b10000 (think of implicit bit)
                        // and the exponent increased
                        if ((msdec & 0x0020_0000_0000_0000) != 0)
                        {
                            msdec = 0x0010_0000_0000_0000;
                            e2++;
                        }
                    }
                }


                // left justify mantissa
                // bit 11 must be 1
                while ((msdec & 0x0010_0000_0000_0000) == 0)
                {
                    msdec <<= 1;
                    e2--;
                }

                // Stuff mantissa directly into double
                // (first including implicit bit)
                ()@trusted{ *cast(long *)&ldval = msdec; }();
                // Store exponent, now overwriting implicit bit
                ()@trusted{ *cast(long *)&ldval &= 0x000F_FFFF_FFFF_FFFF; }();
                ()@trusted{ *cast(long *)&ldval |= ((e2 & 0xFFFUL) << 52); }();

                import std.math : ldexp;

                // Exponent is power of 2, not power of 10
                ldval = ldexp(ldval,exp);
            }
        }
        else
            static assert(false, "Floating point format of real type not supported");

        goto L6;
    }
    else // not hex
    {
        if (toUpper(p.front) == 'N' && !startsWithZero)
        {
            // nan
            p.popFront();
            if (p.empty || toUpper(p.front) != 'A') return false;
            p.popFront();
            if (p.empty || toUpper(p.front) != 'N') return false;
            // skip past the last 'n'
            p.popFront();
            static if (isNarrowString!Source)
                source = cast(Source) p;
            target = typeof(target).nan;
            return true;
        }

        bool sawDigits = startsWithZero;

        while (!p.empty)
        {
            int i = p.front;
            while (isDigit(i))
            {
                sawDigits = true;        /* must have at least 1 digit   */
                if (msdec < (0x7FFFFFFFFFFFL-10)/10)
                    msdec = msdec * 10 + (i - '0');
                else if (msscale < (0xFFFFFFFF-10)/10)
                {
                    lsdec = lsdec * 10 + (i - '0');
                    msscale *= 10;
                }
                else
                {
                    exp++;
                }
                exp -= dot;
                p.popFront();
                if (p.empty)
                    break;
                i = p.front;
                if (i == '_')
                {
                    p.popFront();
                    if (p.empty)
                        break;
                    i = p.front;
                }
            }
            if (i == '.' && !dot)
            {
                p.popFront();
                dot++;
            }
            else
            {
                break;
            }
        }
        if (!sawDigits) return false; // no digits seen
    }
    if (!p.empty && (p.front == 'e' || p.front == 'E'))
    {
        char sexp;
        int e;

        sexp = 0;
        p.popFront();
        if (p.empty) return false; // Unexpected end of input
        switch (p.front)
        {
            case '-':    sexp++;
                         goto case;
            case '+':    p.popFront();
                         break;
            default: {}
        }
        bool sawDigits = 0;
        e = 0;
        while (!p.empty && isDigit(p.front))
        {
            if (e < 0x7FFFFFFF / 10 - 10)   // prevent integer overflow
            {
                e = e * 10 + p.front - '0';
            }
            p.popFront();
            sawDigits = 1;
        }
        exp += (sexp) ? -e : e;
        if (!sawDigits) return false; // no digits seen
    }

    ldval = msdec;
    if (msscale != 1)               /* if stuff was accumulated in lsdec */
        ldval = ldval * msscale + lsdec;
    if (ldval)
    {
        uint u = 0;
        int pow = 4096;

        while (exp > 0)
        {
            while (exp >= pow)
            {
                ldval *= postab[u];
                exp -= pow;
            }
            pow >>= 1;
            u++;
        }
        while (exp < 0)
        {
            while (exp <= -pow)
            {
                ldval *= negtab[u];
                if (ldval == 0) return false; // Range error
                exp += pow;
            }
            pow >>= 1;
            u++;
        }
    }
  L6: // if overflow occurred
    if (ldval == HUGE_VAL) return false; // Range error

  L1:
    static if (isNarrowString!Source)
        source = cast(Source) p;
    target = sign ? -ldval : ldval;
    return true;
}

private Target parse(Target, Source)(ref Source source)
if (isInputRange!Source && isSomeChar!(ElementType!Source) && !is(Source == enum) &&
    isFloatingPoint!Target && !is(Target == enum))
{
    Target target;
    import std.conv : ConvException;
    enforce!ConvException(tryParse(source, target), "Failed parsing " ~ Target.stringof);
    return target;
}

private Target to(Target, Source)(Source source)
if (isInputRange!Source && isSomeChar!(ElementType!Source) && !is(Source == enum) &&
    isFloatingPoint!Target && !is(Target == enum))
{
    import std.conv : ConvException;
    scope(success) enforce!ConvException(source.empty, "Did not consume entire source");
    return parse!Target(source);
}

private Target to(Target, Source)(Source source)
if (is(Target == string) &&
    isFloatingPoint!Source && !is(Source == enum))
{
    import std.conv;
    return std.conv.to!Target(source);
}

    ///
@safe unittest
{
    import std.math : approxEqual;
    auto str = "123.456";

    assert(parse!double(str).approxEqual(123.456));
}

@safe unittest
{
    import std.exception;
    import std.math : isNaN, fabs;
    import std.meta : AliasSeq;
    import std.conv : ConvException;

    // Compare reals with given precision
    bool feq(in real rx, in real ry, in real precision = 0.000001L)
    {
        if (rx == ry)
            return 1;

        if (isNaN(rx))
            return cast(bool) isNaN(ry);

        if (isNaN(ry))
            return 0;

        return cast(bool)(fabs(rx - ry) <= precision);
    }

    // Make given typed literal
    F Literal(F)(F f)
    {
        return f;
    }

    static foreach (Float; AliasSeq!(float, double, real))
    {
        assert(to!Float("123") == Literal!Float(123));
        assert(to!Float("+123") == Literal!Float(+123));
        assert(to!Float("-123") == Literal!Float(-123));
        assert(to!Float("123e2") == Literal!Float(123e2));
        assert(to!Float("123e+2") == Literal!Float(123e+2));
        assert(to!Float("123e-2") == Literal!Float(123e-2));
        assert(to!Float("123.") == Literal!Float(123.0));
        assert(to!Float(".375") == Literal!Float(.375));

        assert(to!Float("1.23375E+2") == Literal!Float(1.23375E+2));

        assert(to!Float("0") is 0.0);
        assert(to!Float("-0") is -0.0);

        assert(isNaN(to!Float("nan")));

        assertThrown!ConvException(to!Float("\x00"));
    }

    // min and max
    float f = to!float("1.17549e-38");
    assert(feq(cast(real) f, cast(real) 1.17549e-38));
    assert(feq(cast(real) f, cast(real) float.min_normal));
    f = to!float("3.40282e+38");
    assert(to!string(f) == to!string(3.40282e+38));

    // min and max
    double d = to!double("2.22508e-308");
    assert(feq(cast(real) d, cast(real) 2.22508e-308));
    assert(feq(cast(real) d, cast(real) double.min_normal));
    d = to!double("1.79769e+308");
    assert(to!string(d) == to!string(1.79769e+308));
    assert(to!string(d) == to!string(double.max));

    assert(to!string(to!real(to!string(real.max / 2L))) == to!string(real.max / 2L));

    // min and max
    real r = to!real(to!string(real.min_normal));
    version(NetBSD)
    {
        // NetBSD notice
        // to!string returns 3.3621e-4932L. It is less than real.min_normal and it is subnormal value
        // Simple C code
        //     long double rd = 3.3621e-4932L;
        //     printf("%Le\n", rd);
        // has unexpected result: 1.681050e-4932
        //
        // Bug report: http://gnats.netbsd.org/cgi-bin/query-pr-single.pl?number=50937
    }
    else
    {
        assert(to!string(r) == to!string(real.min_normal));
    }
    r = to!real(to!string(real.max));
    assert(to!string(r) == to!string(real.max));
}

// Tests for the double implementation
@system unittest
{
    // @system because strtod is not @safe.
    static if (real.mant_dig == 53)
    {
        import core.stdc.stdlib, std.exception, std.math;

        //Should be parsed exactly: 53 bit mantissa
        string s = "0x1A_BCDE_F012_3456p10";
        auto x = parse!real(s);
        assert(x == 0x1A_BCDE_F012_3456p10L);
        //1 bit is implicit
        assert(((*cast(ulong*)&x) & 0x000F_FFFF_FFFF_FFFF) == 0xA_BCDE_F012_3456);
        assert(strtod("0x1ABCDEF0123456p10", null) == x);

        //Should be parsed exactly: 10 bit mantissa
        s = "0x3FFp10";
        x = parse!real(s);
        assert(x == 0x03FFp10);
        //1 bit is implicit
        assert(((*cast(ulong*)&x) & 0x000F_FFFF_FFFF_FFFF) == 0x000F_F800_0000_0000);
        assert(strtod("0x3FFp10", null) == x);

        //60 bit mantissa, round up
        s = "0xFFF_FFFF_FFFF_FFFFp10";
        x = parse!real(s);
        assert(approxEqual(x, 0xFFF_FFFF_FFFF_FFFFp10));
        //1 bit is implicit
        assert(((*cast(ulong*)&x) & 0x000F_FFFF_FFFF_FFFF) == 0x0000_0000_0000_0000);
        assert(strtod("0xFFFFFFFFFFFFFFFp10", null) == x);

        //60 bit mantissa, round down
        s = "0xFFF_FFFF_FFFF_FF90p10";
        x = parse!real(s);
        assert(approxEqual(x, 0xFFF_FFFF_FFFF_FF90p10));
        //1 bit is implicit
        assert(((*cast(ulong*)&x) & 0x000F_FFFF_FFFF_FFFF) == 0x000F_FFFF_FFFF_FFFF);
        assert(strtod("0xFFFFFFFFFFFFF90p10", null) == x);

        //61 bit mantissa, round up 2
        s = "0x1F0F_FFFF_FFFF_FFFFp10";
        x = parse!real(s);
        assert(approxEqual(x, 0x1F0F_FFFF_FFFF_FFFFp10));
        //1 bit is implicit
        assert(((*cast(ulong*)&x) & 0x000F_FFFF_FFFF_FFFF) == 0x000F_1000_0000_0000);
        assert(strtod("0x1F0FFFFFFFFFFFFFp10", null) == x);

        //61 bit mantissa, round down 2
        s = "0x1F0F_FFFF_FFFF_FF10p10";
        x = parse!real(s);
        assert(approxEqual(x, 0x1F0F_FFFF_FFFF_FF10p10));
        //1 bit is implicit
        assert(((*cast(ulong*)&x) & 0x000F_FFFF_FFFF_FFFF) == 0x000F_0FFF_FFFF_FFFF);
        assert(strtod("0x1F0FFFFFFFFFFF10p10", null) == x);

        //Huge exponent
        s = "0x1F_FFFF_FFFF_FFFFp900";
        x = parse!real(s);
        assert(strtod("0x1FFFFFFFFFFFFFp900", null) == x);

        //exponent too big -> converror
        s = "";
        assertThrown!ConvException(x = parse!real(s));
        assert(strtod("0x1FFFFFFFFFFFFFp1024", null) == real.infinity);

        //-exponent too big -> 0
        s = "0x1FFFFFFFFFFFFFp-2000";
        x = parse!real(s);
        assert(x == 0);
        assert(strtod("0x1FFFFFFFFFFFFFp-2000", null) == x);
    }
}

@system unittest
{
    import core.stdc.errno;
    import core.stdc.stdlib;
    //import std.math : floatTraits, RealFormat;

    errno = 0;  // In case it was set by another unittest in a different module.
    struct longdouble
    {
        static if (floatTraits!real.realFormat == RealFormat.ieeeQuadruple)
        {
            ushort[8] value;
        }
        else static if (floatTraits!real.realFormat == RealFormat.ieeeExtended)
        {
            ushort[5] value;
        }
        else static if (floatTraits!real.realFormat == RealFormat.ieeeDouble)
        {
            ushort[4] value;
        }
        else
            static assert(false, "Not implemented");
    }

    real ld;
    longdouble x;
    real ld1;
    longdouble x1;
    int i;

    static if (floatTraits!real.realFormat == RealFormat.ieeeQuadruple)
        // Our parser is currently limited to ieeeExtended precision
        enum s = "0x1.FFFFFFFFFFFFFFFEp-16382";
    else static if (floatTraits!real.realFormat == RealFormat.ieeeExtended)
        enum s = "0x1.FFFFFFFFFFFFFFFEp-16382";
    else static if (floatTraits!real.realFormat == RealFormat.ieeeDouble)
        enum s = "0x1.FFFFFFFFFFFFFFFEp-1000";
    else
        static assert(false, "Floating point format for real not supported");

    auto s2 = s.idup;
    ld = parse!real(s2);
    assert(s2.empty);
    x = *cast(longdouble *)&ld;

    static if (floatTraits!real.realFormat == RealFormat.ieeeExtended)
    {
        version (CRuntime_Microsoft)
            ld1 = 0x1.FFFFFFFFFFFFFFFEp-16382L; // strtold currently mapped to strtod
        else version (CRuntime_Bionic)
            ld1 = 0x1.FFFFFFFFFFFFFFFEp-16382L; // strtold currently mapped to strtod
        else
            ld1 = strtold(s.ptr, null);
    }
    else
        ld1 = strtold(s.ptr, null);

    x1 = *cast(longdouble *)&ld1;
    assert(x1 == x && ld1 == ld);

    assert(!errno);

    s2 = "1.0e5";
    ld = parse!real(s2);
    assert(s2.empty);
    x = *cast(longdouble *)&ld;
    ld1 = strtold("1.0e5", null);
    x1 = *cast(longdouble *)&ld1;
}

@safe pure unittest
{
    import std.exception;
    import std.conv : ConvException;

    // Bugzilla 4959
    {
        auto s = "0 ";
        auto x = parse!double(s);
        assert(s == " ");
        assert(x == 0.0);
    }

    // Bugzilla 3369
    assert(to!float("inf") == float.infinity);
    assert(to!float("-inf") == -float.infinity);

    // Bugzilla 6160
    assert(6_5.536e3L == to!real("6_5.536e3"));                     // 2^16
    assert(0x1000_000_000_p10 == to!real("0x1000_000_000_p10"));    // 7.03687e+13

    // Bugzilla 6258
    assertThrown!ConvException(to!real("-"));
    assertThrown!ConvException(to!real("in"));

    // Bugzilla 7055
    assertThrown!ConvException(to!float("INF2"));

    //extra stress testing
    auto ssOK    = ["1.", "1.1.1", "1.e5", "2e1e", "2a", "2e1_1",
                    "inf", "-inf", "infa", "-infa", "inf2e2", "-inf2e2"];
    auto ssKO    = ["", " ", "2e", "2e+", "2e-", "2ee", "2e++1", "2e--1", "2e_1", "+inf"];
    foreach (s; ssOK)
        parse!double(s);
    foreach (s; ssKO)
        assertThrown!ConvException(parse!double(s));
}

private:
// From std.math, where they are package-protected:

// Underlying format exposed through floatTraits
enum RealFormat
{
    ieeeHalf,
    ieeeSingle,
    ieeeDouble,
    ieeeExtended,   // x87 80-bit real
    ieeeExtended53, // x87 real rounded to precision of double.
    ibmExtended,    // IBM 128-bit extended
    ieeeQuadruple,
}

// Constants used for extracting the components of the representation.
// They supplement the built-in floating point properties.
template floatTraits(T)
{
    // EXPMASK is a ushort mask to select the exponent portion (without sign)
    // EXPSHIFT is the number of bits the exponent is left-shifted by in its ushort
    // EXPBIAS is the exponent bias - 1 (exp == EXPBIAS yields ×2^-1).
    // EXPPOS_SHORT is the index of the exponent when represented as a ushort array.
    // SIGNPOS_BYTE is the index of the sign when represented as a ubyte array.
    // RECIP_EPSILON is the value such that (smallest_subnormal) * RECIP_EPSILON == T.min_normal
    enum T RECIP_EPSILON = (1/T.epsilon);
    static if (T.mant_dig == 24)
    {
        // Single precision float
        enum ushort EXPMASK = 0x7F80;
        enum ushort EXPSHIFT = 7;
        enum ushort EXPBIAS = 0x3F00;
        enum uint EXPMASK_INT = 0x7F80_0000;
        enum uint MANTISSAMASK_INT = 0x007F_FFFF;
        enum realFormat = RealFormat.ieeeSingle;
        version(LittleEndian)
        {
            enum EXPPOS_SHORT = 1;
            enum SIGNPOS_BYTE = 3;
        }
        else
        {
            enum EXPPOS_SHORT = 0;
            enum SIGNPOS_BYTE = 0;
        }
    }
    else static if (T.mant_dig == 53)
    {
        static if (T.sizeof == 8)
        {
            // Double precision float, or real == double
            enum ushort EXPMASK = 0x7FF0;
            enum ushort EXPSHIFT = 4;
            enum ushort EXPBIAS = 0x3FE0;
            enum uint EXPMASK_INT = 0x7FF0_0000;
            enum uint MANTISSAMASK_INT = 0x000F_FFFF; // for the MSB only
            enum realFormat = RealFormat.ieeeDouble;
            version(LittleEndian)
            {
                enum EXPPOS_SHORT = 3;
                enum SIGNPOS_BYTE = 7;
            }
            else
            {
                enum EXPPOS_SHORT = 0;
                enum SIGNPOS_BYTE = 0;
            }
        }
        else static if (T.sizeof == 12)
        {
            // Intel extended real80 rounded to double
            enum ushort EXPMASK = 0x7FFF;
            enum ushort EXPSHIFT = 0;
            enum ushort EXPBIAS = 0x3FFE;
            enum realFormat = RealFormat.ieeeExtended53;
            version(LittleEndian)
            {
                enum EXPPOS_SHORT = 4;
                enum SIGNPOS_BYTE = 9;
            }
            else
            {
                enum EXPPOS_SHORT = 0;
                enum SIGNPOS_BYTE = 0;
            }
        }
        else
            static assert(false, "No traits support for " ~ T.stringof);
    }
    else static if (T.mant_dig == 64)
    {
        // Intel extended real80
        enum ushort EXPMASK = 0x7FFF;
        enum ushort EXPSHIFT = 0;
        enum ushort EXPBIAS = 0x3FFE;
        enum realFormat = RealFormat.ieeeExtended;
        version(LittleEndian)
        {
            enum EXPPOS_SHORT = 4;
            enum SIGNPOS_BYTE = 9;
        }
        else
        {
            enum EXPPOS_SHORT = 0;
            enum SIGNPOS_BYTE = 0;
        }
    }
    else static if (T.mant_dig == 113)
    {
        // Quadruple precision float
        enum ushort EXPMASK = 0x7FFF;
        enum ushort EXPSHIFT = 0;
        enum ushort EXPBIAS = 0x3FFE;
        enum realFormat = RealFormat.ieeeQuadruple;
        version(LittleEndian)
        {
            enum EXPPOS_SHORT = 7;
            enum SIGNPOS_BYTE = 15;
        }
        else
        {
            enum EXPPOS_SHORT = 0;
            enum SIGNPOS_BYTE = 0;
        }
    }
    else static if (T.mant_dig == 106)
    {
        // IBM Extended doubledouble
        enum ushort EXPMASK = 0x7FF0;
        enum ushort EXPSHIFT = 4;
        enum realFormat = RealFormat.ibmExtended;
        // the exponent byte is not unique
        version(LittleEndian)
        {
            enum EXPPOS_SHORT = 7; // [3] is also an exp short
            enum SIGNPOS_BYTE = 15;
        }
        else
        {
            enum EXPPOS_SHORT = 0; // [4] is also an exp short
            enum SIGNPOS_BYTE = 0;
        }
    }
    else
        static assert(false, "No traits support for " ~ T.stringof);
}
