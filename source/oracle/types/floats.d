/++
BINARY_FLOAT and BINARY_DOUBLE values: the IEEE 754 bits, big-endian, with
the sign bit flipped for positive numbers and all bits inverted for negative
ones (so that the bytes sort like the numbers).

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module oracle.types.floats;

import oracle.exception : ProtocolException;

/++
Decodes a BINARY_FLOAT (4 bytes) or BINARY_DOUBLE (8 bytes).

Throws: `ProtocolException` for other lengths.
+/
double decodeBinaryFloat(scope const(ubyte)[] b) @safe pure
{
    if (b.length != 4 && b.length != 8)
        throw new ProtocolException("Invalid BINARY_FLOAT/BINARY_DOUBLE length");
    ulong bits;
    foreach (x; b)
        bits = (bits << 8) | x;
    const signBit = 1UL << (8 * b.length - 1);
    if (bits & signBit)
        bits &= ~signBit; // positive
    else
        bits = ~bits & (b.length == 4 ? 0xFFFF_FFFFUL : ulong.max); // negative
    if (b.length == 4)
    {
        const uint u = cast(uint) bits;
        return (() @trusted => *cast(const float*)&u)(); // reinterprets the IEEE bits
    }
    return (() @trusted => *cast(const double*)&bits)(); // reinterprets the IEEE bits
}

/++
The shortest decimal text that reads back as the same value (as a `float`
when `single`): `0.1`, `-2.25`, `1e+300`; `Nan`, `Inf` and `-Inf` as Oracle
writes them.
+/
string floatText(double v, bool single) @safe
{
    import std.conv : ConvException, to;
    import std.format : format;
    import std.math : isInfinity, isNaN;

    if (isNaN(v))
        return "Nan";
    if (isInfinity(v))
        return v < 0 ? "-Inf" : "Inf";
    foreach (digits; 1 .. 18)
    {
        const s = format("%.*g", digits, v);
        try
        {
            if (single ? s.to!float == cast(float) v : s.to!double == v)
                return s;
        }
        catch (ConvException)
        {
            // rounded beyond the largest value (e.g. 2e+308): needs more digits
        }
    }
    return format("%.17g", v);
}

///
@safe unittest
{
    // values from Oracle 26ai
    assert(decodeBinaryFloat([0xBF, 0xC0, 0x00, 0x00]) == 1.5f);
    assert(decodeBinaryFloat([0x40, 0x7F, 0xFF, 0xFF]) == -1f);
    assert(decodeBinaryFloat([0x3F, 0xFD, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]) == -2.25);
    assert(decodeBinaryFloat([0x80, 0, 0, 0, 0, 0, 0, 0]) == 0);
    assert(decodeBinaryFloat([0x00, 0x0F, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]) == -double.infinity);
    assert(floatText(decodeBinaryFloat([0xFF, 0xC0, 0x00, 0x00]), true) == "Nan");
    assert(floatText(0.1, false) == "0.1" && floatText(cast(float) 0.1f, true) == "0.1");
    assert(floatText(-2.25, false) == "-2.25" && floatText(1e300, false) == "1e+300");
    assert(floatText(-double.infinity, false) == "-Inf");
    assert(floatText(double.max, false) == "1.7976931348623157e+308" && floatText(float.max, true) == "3.4028235e+38");
}
