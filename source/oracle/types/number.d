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

import std.conv : to;
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
    string toString() const @safe pure nothrow
    {
        if (infinite)
            return negative ? "-~" : "~";
        return plainText(negative, digits, pointPosition);
    }
}

/++
`0.digits × 10^pointPosition` in plain notation (`-12.5`, `0.001`, `100`;
`0` for no digits), built in a stack buffer (one allocation).
+/
package(oracle) string plainText(bool negative, scope const(char)[] digits, int pointPosition) @safe pure nothrow
{
    import std.array : replicate;
    import oracle.types.temporal : TextBufferOf;

    if (digits.length == 0)
        return "0";
    const zeros = pointPosition <= 0 ? 2 - pointPosition : pointPosition > digits.length
        ? pointPosition - digits.length : 1;
    if (1 + digits.length + zeros > 400) // a DecodedNumber made by hand (more than the buffer below holds)
    {
        string s = negative ? "-" : "";
        if (pointPosition <= 0)
            return s ~ "0." ~ "0".replicate(-pointPosition) ~ digits;
        if (pointPosition >= digits.length)
            return s ~ digits ~ "0".replicate(pointPosition - digits.length);
        return s ~ digits[0 .. pointPosition] ~ "." ~ digits[pointPosition .. $];
    }
    TextBufferOf!400 t; // NUMBERs need at most 175 characters, doubles 343
    if (negative)
        t.put('-');
    if (pointPosition <= 0)
    {
        t.put("0.");
        t.fill('0', -pointPosition);
        t.put(digits);
    }
    else if (pointPosition >= digits.length)
    {
        t.put(digits);
        t.fill('0', pointPosition - digits.length);
    }
    else
    {
        t.put(digits[0 .. pointPosition]);
        t.put('.');
        t.put(digits[pointPosition .. $]);
    }
    return t.text;
}

/// A NUMBER's sign and decimal digits, without allocating: `buffer[0 .. length]`, at most 40 digits.
package(oracle) struct NumberDigits
{
    bool negative; ///
    bool infinite; ///
    char[40] buffer; ///
    ubyte length; ///
    int pointPosition; /// The value is 0.digits × 10^pointPosition.
}

/++
Decodes a NUMBER.

Throws: `ProtocolException` if the bytes are not a valid NUMBER.
+/
DecodedNumber decodeNumber(scope const(ubyte)[] b) @safe pure
{
    NumberDigits d;
    parseNumber(b, d);
    return DecodedNumber(d.negative, d.infinite, d.buffer[0 .. d.length].idup, d.pointPosition);
}

/++
Decodes a NUMBER into `n` (no allocation).

Throws: `ProtocolException` if the bytes are not a valid NUMBER.
+/
package(oracle) void parseNumber(scope const(ubyte)[] b, out NumberDigits n) @safe pure
{
    if (b.length == 0 || b.length > 22)
        throw new ProtocolException("Invalid NUMBER length " ~ to!string(b.length));
    if (b.length == 1 && b[0] == 0x80)
        return; // zero
    if (b.length == 1 && b[0] == 0x00)
    {
        n.negative = n.infinite = true;
        return;
    }
    if (b.length == 2 && b[0] == 0xFF && b[1] == 0x65)
    {
        n.infinite = true;
        return;
    }
    n.negative = (b[0] & 0x80) == 0;
    const exponentByte = n.negative ? cast(ubyte)(~cast(int) b[0]) : b[0];
    const e = (exponentByte & 0x7F) - 65;
    auto mantissa = b[1 .. $];
    if (n.negative && mantissa.length && mantissa[$ - 1] == 102)
        mantissa = mantissa[0 .. $ - 1];
    if (mantissa.length == 0)
        throw new ProtocolException("Invalid NUMBER: no digits");
    if (mantissa.length > 20)
        throw new ProtocolException("Invalid NUMBER: more than 20 digit pairs");
    char[] digits = n.buffer[0 .. 2 * mantissa.length];
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
    // move the digits to the front of the buffer
    foreach (i; start .. end)
        n.buffer[i - start] = n.buffer[i];
    n.length = cast(ubyte)(end - start);
    n.pointPosition = point;
    if (n.length == 0)
        n.negative = false; // a zero mantissa (not produced by the server)
}

/// The text of a NUMBER (as `DecodedNumber.toString`), with one allocation.
package(oracle) string numberText(scope const(ubyte)[] b) @safe pure
{
    NumberDigits n;
    parseNumber(b, n);
    if (n.infinite)
        return n.negative ? "-~" : "~";
    return plainText(n.negative, n.buffer[0 .. n.length], n.pointPosition);
}

/++
The NUMBER as a `long`.

Throws: `ClientException` if the value has a fractional part or doesn't fit;
`ProtocolException` if the bytes are not a valid NUMBER.
+/
long numberToLong(scope const(ubyte)[] b) @safe pure
{
    NumberDigits n;
    parseNumber(b, n);
    const digits = n.buffer[0 .. n.length];
    if (n.infinite || n.pointPosition < cast(int) digits.length)
    {
        if (digits.length == 0 && !n.infinite)
            return 0;
        throw new ClientException("NUMBER " ~ numberText(b) ~ " is not an integer");
    }
    if (n.pointPosition > 19)
        throw new ClientException("NUMBER " ~ numberText(b) ~ " does not fit in a long");
    ulong magnitude;
    foreach (i; 0 .. n.pointPosition)
    {
        const d = i < digits.length ? digits[i] - '0' : 0;
        if (magnitude > (ulong.max - d) / 10)
            throw new ClientException("NUMBER " ~ numberText(b) ~ " does not fit in a long");
        magnitude = magnitude * 10 + d;
    }
    if (n.negative ? magnitude > cast(ulong) long.max + 1 : magnitude > long.max)
        throw new ClientException("NUMBER " ~ numberText(b) ~ " does not fit in a long");
    return n.negative ? -cast(long) magnitude : cast(long) magnitude;
}

/++
The NUMBER as a `double` (the nearest one; infinity for `~`).

Throws: `ProtocolException` if the bytes are not a valid NUMBER.
+/
double numberToDouble(scope const(ubyte)[] b) @safe
{
    import oracle.types.floats : parseDouble;

    NumberDigits n;
    parseNumber(b, n);
    if (n.infinite)
        return n.negative ? -double.infinity : double.infinity;
    const digits = n.buffer[0 .. n.length];
    if (digits.length == 0)
        return 0.0;
    // Exact: up to 15 digits are an exact integer m, and 10^k for |k| <= 22 is an exact double, so
    // m × 10^k (or m / 10^-k) is a single correctly rounded operation
    static immutable double[23] powersOfTen = [
        1e0, 1e1, 1e2, 1e3, 1e4, 1e5, 1e6, 1e7, 1e8, 1e9, 1e10, 1e11, 1e12, 1e13, 1e14, 1e15, 1e16,
        1e17, 1e18,
        1e19, 1e20, 1e21, 1e22
    ];
    const k = n.pointPosition - cast(int) digits.length; // value = m × 10^k
    if (digits.length <= 15 && k >= -22 && k <= 22)
    {
        long m;
        foreach (c; digits)
            m = m * 10 + (c - '0');
        const magnitude = k >= 0 ? m * powersOfTen[k] : m / powersOfTen[-k];
        return n.negative ? -magnitude : magnitude;
    }
    // otherwise C's strtod, correctly rounded (Phobos's parser isn't always)
    return parseDouble((n.negative ? "-0." : "0.") ~ digits ~ "e" ~ to!string(n.pointPosition));
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

// numberToDouble: exact for up to 15 digits and powers of ten within ±22, else strtod; both correctly rounded
@safe unittest
{
    import oracle.types.encode : encodeNumber;

    assert(numberToDouble(encodeNumber(false, "1234567", 4)) == 1234.567);
    assert(numberToDouble(encodeNumber(true, "1", -2)) == -0.001);
    assert(numberToDouble(encodeNumber(false, "21642", -78)) == 2.1642e-79); // 1 ulp off through Phobos's parser
    // 6.864489925e57 correctly rounded (the compiler's parser makes the decimal literal 1 ulp larger)
    assert(numberToDouble(encodeNumber(false, "6864489925", 58)) == 0x1.17f49e6ca075bp+192);
    // 12345678901234567890 rounded to a double (a decimal constant may be compared at real precision)
    assert(numberToDouble(encodeNumber(false, "12345678901234567890", 20)) == 0x1.56a95319d63e1p+63);
    assert(numberText(encodeNumber(true, "125", 0)) == "-0.125" && numberText(encodeNumber(false, "1", 3)) == "100");
}
