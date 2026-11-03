/++
Oracle NUMBER values in their wire form: an exponent byte and up to 20
base-100 digits.

Positive numbers: exponent byte `0xC1 + e` (`0x80` set), digits stored plus
one, value = Σ dᵢ × 100^(e − i). Negative numbers: the exponent byte inverted,
digits stored as 101 − d, and a terminating byte 102 when there are fewer
than 20 digits. Zero is the single byte `0x80`; `FF 65` and `00` are
positive and negative infinity.

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module oracle.types.number;

import oracle.exception : ClientException, ProtocolException;

/// A NUMBER decoded into sign, decimal digits and the position of the decimal point.
struct DecodedNumber
{
    /// Negative.
    bool negative;
    /// Infinity (`~` in SQL*Plus).
    bool infinite;
    /// The decimal digits, without leading or trailing zeros; empty for zero.
    string digits;
    /// The value is 0.digits × 10^pointPosition.
    int pointPosition;

    /// The value as text: `-12.5`, `0.001`, `100`, `0`; infinity is `~` or `-~`.
    string toString() const @safe pure
    {
        import std.array : replicate;

        if (infinite)
            return negative ? "-~" : "~";
        if (digits.length == 0)
            return "0";
        string s = negative ? "-" : "";
        if (pointPosition <= 0)
            s ~= "0." ~ "0".replicate(-pointPosition) ~ digits;
        else if (pointPosition >= digits.length)
            s ~= digits ~ "0".replicate(pointPosition - digits.length);
        else
            s ~= digits[0 .. pointPosition] ~ "." ~ digits[pointPosition .. $];
        return s;
    }
}

/++
Decodes a NUMBER.

Throws: `ProtocolException` if the bytes are not a valid NUMBER.
+/
DecodedNumber decodeNumber(scope const(ubyte)[] b) @safe pure
{
    DecodedNumber n;
    if (b.length == 0 || b.length > 22)
        throw new ProtocolException("Invalid NUMBER length " ~ toText(b.length));
    if (b.length == 1 && b[0] == 0x80)
        return n; // zero
    if (b.length == 1 && b[0] == 0x00)
    {
        n.negative = n.infinite = true;
        return n;
    }
    if (b.length == 2 && b[0] == 0xFF && b[1] == 0x65)
    {
        n.infinite = true;
        return n;
    }
    n.negative = (b[0] & 0x80) == 0;
    const exponentByte = n.negative ? cast(ubyte)(~cast(int) b[0]) : b[0];
    const e = (exponentByte & 0x7F) - 65;
    auto mantissa = b[1 .. $];
    if (n.negative && mantissa.length && mantissa[$ - 1] == 102)
        mantissa = mantissa[0 .. $ - 1];
    if (mantissa.length == 0)
        throw new ProtocolException("Invalid NUMBER: no digits");
    char[] digits = new char[2 * mantissa.length];
    foreach (i, x; mantissa)
    {
        const d = n.negative ? 101 - x : x - 1;
        if (d < 0 || d > 99)
            throw new ProtocolException("Invalid NUMBER digit");
        digits[2 * i] = cast(char)('0' + d / 10);
        digits[2 * i + 1] = cast(char)('0' + d % 10);
    }
    // 0.digits × 10^pointPosition, before trimming the leading zero of the first pair
    int point = 2 * (e + 1);
    size_t start;
    while (start < digits.length && digits[start] == '0')
    {
        start++;
        point--;
    }
    size_t end = digits.length;
    while (end > start && digits[end - 1] == '0')
        end--;
    n.digits = digits[start .. end].idup;
    n.pointPosition = point;
    if (n.digits.length == 0)
        n.negative = false; // a zero mantissa (not produced by the server)
    return n;
}

/++
The NUMBER as a `long`.

Throws: `ClientException` if the value has a fractional part or doesn't fit;
`ProtocolException` if the bytes are not a valid NUMBER.
+/
long numberToLong(scope const(ubyte)[] b) @safe pure
{
    const n = decodeNumber(b);
    if (n.infinite || n.pointPosition < cast(int) n.digits.length)
    {
        if (n.digits.length == 0 && !n.infinite)
            return 0;
        throw new ClientException("NUMBER " ~ n.toString() ~ " is not an integer");
    }
    if (n.pointPosition > 19)
        throw new ClientException("NUMBER " ~ n.toString() ~ " does not fit in a long");
    ulong magnitude;
    foreach (i; 0 .. n.pointPosition)
    {
        const d = i < n.digits.length ? n.digits[i] - '0' : 0;
        if (magnitude > (ulong.max - d) / 10)
            throw new ClientException("NUMBER " ~ n.toString() ~ " does not fit in a long");
        magnitude = magnitude * 10 + d;
    }
    if (n.negative ? magnitude > cast(ulong) long.max + 1 : magnitude > long.max)
        throw new ClientException("NUMBER " ~ n.toString() ~ " does not fit in a long");
    return n.negative ? -cast(long) magnitude : cast(long) magnitude;
}

/++
The NUMBER as a `double` (the nearest one; infinity for `~`).

Throws: `ProtocolException` if the bytes are not a valid NUMBER.
+/
double numberToDouble(scope const(ubyte)[] b) @safe pure
{
    import std.conv : to;

    const n = decodeNumber(b);
    if (n.infinite)
        return n.negative ? -double.infinity : double.infinity;
    if (n.digits.length == 0)
        return 0.0;
    const text = (n.negative ? "-0." : "0.") ~ n.digits ~ "e" ~ toText(n.pointPosition);
    return text.to!double;
}

private string toText(T)(T v) @safe pure
{
    import std.conv : to;

    return v.to!string;
}

///
@safe unittest
{
    assert(decodeNumber([0xC1, 0x2B]).toString == "42" && numberToLong([0xC1, 0x2B]) == 42);
    assert(decodeNumber([0x80]).toString == "0" && numberToLong([0x80]) == 0);
    assert(decodeNumber([0x3E, 0x3B, 0x66]).toString == "-42" && numberToLong([0x3E, 0x3B, 0x66]) == -42);
    assert(decodeNumber([0xC0, 0x33]).toString == "0.5" && numberToDouble([0xC0, 0x33]) == 0.5);
    assert(decodeNumber([0xC1, 0x0D, 0x23, 0x33]).toString == "12.345");
    assert(decodeNumber([0xC2, 0x0D, 0x23]).toString == "1234");
    assert(decodeNumber([0xC3, 0x02]).toString == "10000");
    assert(decodeNumber([0xBF, 0x0B]).toString == "0.001");
    assert(decodeNumber([0xFF, 0x65]).toString == "~" && decodeNumber([0x00]).toString == "-~");
}

@safe unittest
{
    import std.exception : assertThrown;

    // 9223372036854775807 = 9 22 33 72 03 68 54 77 58 07 (base 100), e = 9
    const ubyte[] maxLong = [0xCA, 10, 23, 34, 73, 4, 69, 55, 78, 59, 8];
    assert(numberToLong(maxLong) == long.max);
    // -9223372036854775808
    const ubyte[] minLong = [0x35, 92, 79, 68, 29, 98, 33, 47, 24, 43, 93, 102];
    assert(numberToLong(minLong) == long.min);
    assertThrown!ClientException(numberToLong([0xC0, 0x33])); // 0.5
    assertThrown!ClientException(numberToLong([0xCB, 0x02])); // 10^20
    assertThrown!ProtocolException(decodeNumber([]));
    assertThrown!ProtocolException(decodeNumber([0xC1, 0x00]));
}
