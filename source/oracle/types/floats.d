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

Formats and reads back with the C library (`snprintf`, `strtod`), which
rounds correctly on every platform (Phobos's parser doesn't where `real` is
64 bits, such as macOS on ARM and Windows with LDC).
+/
string floatText(double v, bool single) @safe
{
    import std.math : isInfinity, isNaN;

    if (isNaN(v))
        return "Nan";
    if (isInfinity(v))
        return v < 0 ? "-Inf" : "Inf";
    string s;
    foreach (digits; 1 .. 18)
    {
        s = formatDigits(v, digits);
        if (single ? parseFloat(s) == cast(float) v : parseDouble(s) == v)
            break;
    }
    return s;
}

/// `v` with `digits` significant digits (`%.*g`).
private string formatDigits(double v, int digits) @trusted
{
    import core.stdc.stdio : snprintf;

    char[40] buffer;
    const n = snprintf(buffer.ptr, buffer.length, "%.*g", digits, v); // fits: at most 17 digits and an exponent
    return buffer[0 .. n].idup;
}

package double parseDouble(string s) @trusted
{
    import core.stdc.stdlib : strtod;
    import std.string : toStringz;

    return strtod(s.toStringz, null); // reads the NUL-terminated copy
}

private float parseFloat(string s) @trusted
{
    import core.stdc.stdlib : strtof;
    import std.string : toStringz;

    return strtof(s.toStringz, null); // reads the NUL-terminated copy
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
    assert(floatText(double.min_normal * double.epsilon, false) == "5e-324"); // the smallest subnormal
}
