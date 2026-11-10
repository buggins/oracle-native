/++
BINARY_FLOAT and BINARY_DOUBLE values: the IEEE 754 bits, big-endian, with
the sign bit flipped for positive numbers and all bits inverted for negative
ones (so that the bytes sort like the numbers).

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module oracle.types.floats;

import oracle.exception : ProtocolException;
import dbwire.types.floattext : ShortestDigits;
import oracle.types.number : DecodedNumber;

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

The digits are the fewest that, correctly rounded, read back (as C's
`%.*g` with increasing precisions finds them, and as `JSON_SERIALIZE`
writes them; see `floatDigits`), laid out as `%g` with as many significant
digits: plain when the decimal exponent X (value = d.ddd × 10^X) is at least
-4 and below the number of digits, else `d.ddde±XX` (at least two exponent
digits). Independent of the C locale.
+/
string floatText(double v, bool single) @safe
{
    import std.math : isInfinity, isNaN, signbit;
    import dbwire.types.floattext : digits;

    if (single)
        v = cast(float) v; // what is written: also infinity or zero for doubles out of float range
    if (isNaN(v))
        return "Nan";
    if (isInfinity(v))
        return v < 0 ? "-Inf" : "Inf";
    if (v == 0)
        return signbit(v) ? "-0" : "0";
    const d = nearestDigits(v, single);
    const significant = d.digits;
    const exponent = d.pointPos - 1; // value = d.ddd × 10^exponent
    // at most a sign, 17 digits, a point and "e-324", or a sign, "0.000" and 17 digits
    char[32] text = void;
    size_t n;
    void put(const(char)[] part...)
    {
        text[n .. n + part.length] = part[];
        n += part.length;
    }

    if (signbit(v))
        put('-');
    if (exponent < -4 || exponent >= cast(int) significant.length)
    {
        put(significant[0]);
        if (significant.length > 1)
        {
            put('.');
            put(significant[1 .. $]);
        }
        const magnitude = exponent < 0 ? -exponent : exponent;
        put('e', exponent < 0 ? '-' : '+');
        if (magnitude >= 100)
            put(cast(char)('0' + magnitude / 100));
        put(cast(char)('0' + magnitude / 10 % 10), cast(char)('0' + magnitude % 10));
    }
    else if (exponent < 0)
    {
        put('0', '.');
        foreach (i; 0 .. -exponent - 1)
            put('0');
        put(significant);
    }
    else
    {
        put(significant[0 .. exponent + 1]);
        if (exponent + 1 < significant.length)
        {
            put('.');
            put(significant[exponent + 1 .. $]);
        }
    }
    return text[0 .. n].idup;
}

/++
The digits of a finite `v` (as a `float` when `single`) that `floatText`
writes, as a `DecodedNumber` (sign, digits, decimal point position; no
digits for zero): the fewest that, correctly rounded, read back exactly.

They are dbwire's `shortestDigits` (ties to even), except at powers of two,
where the gap to the next lower value is half the gap above: there the
shortest digits may lie above the value while the nearest ones of that length
don't read back, and `%.*g` (and the server) take one digit more:
`5.9604644775390625e-08` for 2^-24, not `5.960464477539063e-08`.
+/
package(oracle) DecodedNumber floatDigits(double v, bool single) @safe
{
    import std.math : signbit;
    import dbwire.types.floattext : digits;

    DecodedNumber n;
    n.negative = signbit(v) != 0;
    if (single)
        v = cast(float) v;
    if (v == 0)
        return n;
    const d = nearestDigits(v, single);
    n.digits = d.digits.idup;
    n.pointPosition = d.pointPos;
    return n;
}

// The digits of floatDigits, without allocating except at powers of two.
private ShortestDigits nearestDigits(double v, bool single) @safe
{
    import std.math : abs, ilogb, ldexp;
    import dbwire.types.floattext : shortestDigits;

    const result = single ? shortestDigits(cast(float) v) : shortestDigits(v);
    // a power of two above the smallest normal value (whose gaps below and above are equal)
    const x = abs(single ? cast(double) cast(float) v : v);
    const exponent = ilogb(x);
    const smallest = (single ? float.min_exp : double.min_exp) - 1; // the smallest normal is 2^smallest
    if (exponent <= smallest || ldexp(1.0, exponent) != x)
        return result;
    // the exact value's digits, rounded to nearest (ties to even) at that length, else one digit more
    string exact;
    int exactPoint;
    exactDigits(exponent, exact, exactPoint);
    foreach (length; result.length .. (single ? 9 : 17) + 1)
    {
        ShortestDigits r;
        roundTo(exact, exactPoint, length, r);
        if (readsBack(r, abs(v), single))
            return r;
    }
    return result; // not reached: 17 (9) correctly rounded digits always read back
}

// The digits of 2^k, exactly: 2^k for k >= 0, 5^-k × 10^k below.
private void exactDigits(int k, out string digits, out int pointPos) @safe pure nothrow
{
    import std.bigint : BigInt, toDecimalString;
    import std.exception : assumeWontThrow;

    BigInt b = 1;
    if (k >= 0)
        b <<= k;
    else
        b = BigInt(5) ^^ -k;
    digits = assumeWontThrow(toDecimalString(b));
    pointPos = cast(int) digits.length + (k < 0 ? k : 0);
}

// `digits` (value = 0.digits × 10^pointPos) rounded to `length` digits, ties to even, into `r`.
private void roundTo(string digits, int pointPos, size_t length, ref ShortestDigits r) @safe pure nothrow @nogc
{
    r.pointPos = pointPos;
    if (digits.length <= length)
    {
        r.length = cast(ubyte) digits.length;
        r.buffer[0 .. r.length] = digits[];
        return;
    }
    r.length = cast(ubyte) length;
    r.buffer[0 .. length] = digits[0 .. length];
    const next = digits[length];
    bool tie = next == '5';
    foreach (c; digits[length + 1 .. $])
        tie = tie && c == '0';
    if (next < '5' || (tie && (r.buffer[length - 1] - '0') % 2 == 0))
        return;
    size_t i = length;
    while (i > 0 && r.buffer[i - 1] == '9')
        r.buffer[--i] = '0';
    if (i == 0)
    {
        r.buffer[0] = '1'; // 99…9 rounds up to 10…0
        r.length = 1;
        r.pointPos++;
        return;
    }
    r.buffer[i - 1]++;
    size_t last = r.length; // drop the zeros the carry left at the end
    while (last > 1 && r.buffer[last - 1] == '0')
        last--;
    r.length = cast(ubyte) last;
}

// Whether the digits read back as `v` (positive), as strtod (strtof for floats) reads them.
private bool readsBack(const ref ShortestDigits d, double v, bool single) @safe
{
    import std.conv : to;
    import dbwire.types.floattext : digits;

    const text = "0." ~ d.digits ~ "e" ~ d.pointPos.to!string;
    return single ? parseC!float(text) == cast(float) v : parseC!double(text) == v;
}

/++
Reads a decimal number (`1.5`, `-2e+300`) as C's `strtod` does: correctly
rounded on every platform (Phobos's parser isn't where `real` is 64 bits,
such as macOS on ARM and Windows with LDC), whatever the C locale's decimal
point (`LC_NUMERIC`: "." unless the application called `setlocale`).
+/
package(oracle) double parseDouble(string s) @safe
{
    return parseC!double(s);
}

// strtod (strtof for float) with the C locale's decimal point for ".".
private T parseC(T)(const(char)[] s) if (is(T == float) || is(T == double))
{
    import std.array : replace;

    const point = decimalPoint();
    return strtodCopy!T(point == "." ? s : s.replace(".", point));
}

// strtod (strtof) on a NUL-terminated copy of `text`, on the stack when it is short.
private T strtodCopy(T)(const(char)[] text) @safe
{
    import core.stdc.stdlib : strtod, strtof;

    char[64] stack = void;
    char[] z = text.length < stack.length ? stack[0 .. text.length + 1] : new char[text.length + 1];
    z[0 .. $ - 1] = text[];
    z[$ - 1] = 0;
    // reads the NUL-terminated copy, keeps no pointer to it
    static if (is(T == float))
        return (() @trusted => strtof(z.ptr, null))();
    else
        return (() @trusted => strtod(z.ptr, null))();
}

// The decimal point of the C library's locale (`printf` writes it, `strtod` reads it).
package(oracle) string decimalPoint() @trusted
{
    import core.stdc.locale : localeconv;
    import std.string : fromStringz;

    // localeconv's strings stay valid until the next setlocale: copied
    const lc = localeconv();
    if (lc is null || lc.decimal_point is null)
        return ".";
    const point = fromStringz(lc.decimal_point);
    return point == "." ? "." : point.idup;
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

// At powers of two the gap below is half the gap above: the nearest digits of the shortest length may not read
// back, and one digit more is taken (as %.*g and JSON_SERIALIZE do), not the shortest digits above the value
@safe unittest
{
    import std.math : ldexp;

    assert(floatText(ldexp(1.0, -24), false) == "5.9604644775390625e-08"); // the shortest is 5.960464477539063e-08
    assert(floatText(ldexp(1.0, 89), false) == "6.1897001964269014e+26");
    assert(floatText(ldexp(1.0f, 87), true) == "1.54742505e+26"); // the shortest is 1.5474251e+26
    assert(floatText(ldexp(1.0, 10), false) == "1024" && floatText(ldexp(1.0, -1074), false) == "5e-324");
    assert(floatText(-ldexp(1.0, -24), false) == "-5.9604644775390625e-08");
    assert(floatDigits(ldexp(1.0, -24), false).toString() == "0.000000059604644775390625");
    assert(floatText(-0.0, false) == "-0" && floatText(100, false) == "1e+02" && floatText(0.0001, false) == "0.0001");
    assert(floatText(123_456, false) == "123456" && floatText(1.5e-5, false) == "1.5e-05");
    assert(parseDouble("1.5") == 1.5 && parseDouble("-2e+300") == -2e300);
    assert(floatDigits(0.0, false).digits.length == 0 && floatDigits(-1.25, false).toString() == "-1.25");
}

// Independent of the C locale: with a decimal comma (where the system has such a locale)
@system unittest
{
    import core.stdc.locale : LC_NUMERIC, setlocale;
    import std.string : fromStringz, toStringz;
    import oracle.types.oson : encodeOson, osonToText;

    const saved = fromStringz(setlocale(LC_NUMERIC, null)).idup;
    scope (exit)
        setlocale(LC_NUMERIC, saved.toStringz);
    foreach (name; ["de_DE.UTF-8", "de_DE.utf8", "fr_FR.UTF-8", "German_Germany.1252"])
        if (setlocale(LC_NUMERIC, name.toStringz) !is null)
        {
            assert(floatText(1.5e-7, false) == "1.5e-07" && floatText(0.25, true) == "0.25");
            assert(parseDouble("1.5") == 1.5 && parseDouble("1.5e300") == 1.5e300);
            assert(osonToText(encodeOson(`{"a":1.5,"b":1.5e300}`, false)) == `{"a":1.5,"b":1.5E+300}`);
            break;
        }
}

// floatText for a float (single) given a double out of float range: the float it becomes
@safe unittest
{
    assert(floatText(1e300, true) == "Inf" && floatText(-1e300, true) == "-Inf" && floatText(1e-50, true) == "0");
    assert(floatDigits(1e-50, true).digits.length == 0);
}
