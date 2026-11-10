/++
Encoding D values in Oracle's wire forms, for bind values: the inverses of
`oracle.types.number`, `oracle.types.floats` and `oracle.types.temporal`.

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module oracle.types.encode;

import std.conv : to;
import core.time : Duration;
import std.datetime.date : DateTime;
import std.datetime.systime : SysTime;
import dbwire.types.decimal : Decimal;
import dbwire.types.interval : MonthInterval;
import dbwire.io.buffer : toBigEndian;
import oracle.exception : ClientException;

/++
A NUMBER from its sign and decimal digits: the value is 0.`digits` ×
10^`pointPosition` (as `DecodedNumber`).

Throws: `ClientException` if the value has more than 40 significant digits
or is out of NUMBER's range (about 1e-130 to 1e126).
+/
immutable(ubyte)[] encodeNumber(bool negative, scope const(char)[] digits, int pointPosition) @safe pure
{
    // drop leading and trailing zeros
    size_t start, end = digits.length;
    while (start < end && digits[start] == '0')
    {
        start++;
        pointPosition--;
    }
    while (end > start && digits[end - 1] == '0')
        end--;
    if (start == end)
        return [0x80]; // zero
    char[] d = digits[start .. end].dup;
    // align the decimal point on a base-100 digit boundary
    if (pointPosition % 2 != 0)
    {
        d = "0" ~ d;
        pointPosition++;
    }
    if (d.length % 2)
        d ~= '0';
    if (d.length > 40) // the last pair is not zero: all digits count
        throw new ClientException("NUMBER holds at most 40 significant digits: too many in " ~ digits.idup);
    const exponent = pointPosition / 2 - 1; // the power of 100 of the first pair
    if (exponent < -65 || exponent > 62)
        throw new ClientException("Value out of NUMBER's range");
    ubyte[22] buffer; // an exponent, 20 base-100 digits, the terminator of negative numbers
    auto b = buffer[0 .. 1 + d.length / 2 + (negative && d.length < 40 ? 1 : 0)];
    const ubyte exponentByte = cast(ubyte)(0xC1 + exponent);
    b[0] = negative ? cast(ubyte)(~cast(int) exponentByte) : exponentByte;
    foreach (i; 0 .. d.length / 2)
    {
        const pair = (d[2 * i] - '0') * 10 + (d[2 * i + 1] - '0');
        b[1 + i] = cast(ubyte)(negative ? 101 - pair : pair + 1);
    }
    if (negative && d.length < 40)
        b[$ - 1] = 102;
    return b.idup;
}

/// A NUMBER from an integer.
immutable(ubyte)[] encodeNumber(long v) @safe pure
{
    if (v == long.min)
        return encodeNumber(true, "9223372036854775808", 19);
    const s = (v < 0 ? -v : v).to!string;
    return encodeNumber(v < 0, s, cast(int) s.length);
}

/// ditto
immutable(ubyte)[] encodeUnsignedNumber(ulong v) @safe pure
{
    const s = v.to!string;
    return encodeNumber(false, s, cast(int) s.length);
}

/++
A NUMBER from a `Decimal`, exactly.

Throws: `ClientException` if it has more than 40 significant digits.
+/
immutable(ubyte)[] encodeNumber(const Decimal v) @safe pure
{
    string s = v.unscaled.toString();
    const negative = s.length && s[0] == '-';
    if (negative)
        s = s[1 .. $];
    return encodeNumber(negative, s, cast(int) s.length - v.scale);
}

/// A BINARY_DOUBLE (8 bytes) or BINARY_FLOAT (4 bytes).
immutable(ubyte)[] encodeBinaryDouble(double v) @safe pure nothrow
{
    return flipped(toBigEndian(v));
}

/// ditto
immutable(ubyte)[] encodeBinaryFloat(float v) @safe pure nothrow
{
    return flipped(toBigEndian(v));
}

/// The IEEE bits (big-endian) with the sign bit flipped for positive numbers, all bits for negative ones.
private immutable(ubyte)[] flipped(scope ubyte[] b) @safe pure nothrow
{
    flipSortable(b);
    return b.idup;
}

/// Turns big-endian IEEE bits into Oracle's sortable form, in place (see `encodeBinaryDouble`).
package(oracle) void flipSortable(scope ubyte[] b) @safe pure nothrow @nogc
{
    if (b[0] & 0x80)
        foreach (ref c; b)
            c ^= 0xFF;
    else
        b[0] |= 0x80;
}

/++
A DATE (7 bytes), or a TIMESTAMP (11 bytes) with `nanoseconds`. Years before
1 are astronomical (`std.datetime`'s year 0 is 1 BC).

Throws: `ClientException` for years outside -4712 to 9999.
+/
immutable(ubyte)[] encodeDate(const DateTime dt) @safe pure
{
    return encodeDateTime(dt, 0, false);
}

/// ditto
immutable(ubyte)[] encodeTimestamp(const DateTime dt, uint nanoseconds) @safe pure
{
    return encodeDateTime(dt, nanoseconds, true);
}

private immutable(ubyte)[] encodeDateTime(const DateTime dt, uint ns, bool withFraction) @safe pure
{
    const year = dt.year <= 0 ? dt.year - 1 : dt.year; // Oracle has no year 0
    if (year < -4712 || year > 9999)
        throw new ClientException("Year " ~ to!string(year) ~ " is outside Oracle's dates (-4712 to 9999)");
    ubyte[11] buffer;
    auto b = buffer[0 .. withFraction ? 11 : 7];
    b[0] = cast(ubyte)(year / 100 + 100);
    b[1] = cast(ubyte)(year % 100 + 100);
    b[2] = dt.month;
    b[3] = dt.day;
    b[4] = cast(ubyte)(dt.hour + 1);
    b[5] = cast(ubyte)(dt.minute + 1);
    b[6] = cast(ubyte)(dt.second + 1);
    if (withFraction)
        foreach (i; 0 .. 4)
            b[7 + i] = cast(ubyte)(ns >> (8 * (3 - i)));
    return b.idup;
}

/++
A TIMESTAMP WITH TIME ZONE (13 bytes): the time in UTC, to 100 ns, with the
time's UTC offset.

Throws: `ClientException` for years outside Oracle's dates.
+/
immutable(ubyte)[] encodeTimestampTz(const SysTime t) @safe
{
    const offset = t.utcOffset.total!"minutes";
    const utc = t.toUTC();
    const ns = cast(uint)(utc.fracSecs.total!"hnsecs" * 100);
    immutable ubyte[2] zone = [cast(ubyte)(offset / 60 + 20), cast(ubyte)(offset % 60 + 60)];
    return encodeTimestamp(cast(DateTime) utc, ns) ~ zone[];
}

/++
An INTERVAL DAY TO SECOND (11 bytes).

Throws: `ClientException` if the days exceed 999,999,999.
+/
immutable(ubyte)[] encodeIntervalDs(const Duration d) @safe pure
{
    const parts = d.split!("days", "hours", "minutes", "seconds", "hnsecs")();
    const days = parts.days;
    if (days > 999_999_999 || days < -999_999_999)
        throw new ClientException("Interval out of range: " ~ to!string(days) ~ " days");
    ubyte[11] b;
    putBiased(b[0 .. 4], days);
    b[4] = cast(ubyte)(parts.hours + 60);
    b[5] = cast(ubyte)(parts.minutes + 60);
    b[6] = cast(ubyte)(parts.seconds + 60);
    putBiased(b[7 .. 11], parts.hnsecs * 100);
    return b[].idup;
}

/// An INTERVAL YEAR TO MONTH (5 bytes).
immutable(ubyte)[] encodeIntervalYm(const MonthInterval m) @safe pure nothrow
{
    ubyte[5] b;
    putBiased(b[0 .. 4], m.years);
    b[4] = cast(ubyte)(m.monthsPart + 60);
    return b[].idup;
}

/// A signed value + 2³¹ as a big-endian u32.
private void putBiased(scope ubyte[] b, long v) @safe pure nothrow @nogc
{
    const u = cast(uint)(v + 0x8000_0000L);
    foreach (i; 0 .. 4)
        b[i] = cast(ubyte)(u >> (8 * (3 - i)));
}

///
@safe unittest
{
    import core.time : days, hnsecs, hours, minutes, seconds;
    import std.datetime.timezone : SimpleTimeZone;
    import oracle.types.number : decodeNumber;
    import oracle.types.temporal : decodeDateTime, decodeDayToSecond, decodeYearToMonth, decodeZone;

    assert(encodeNumber(42L) == [0xC1, 0x2B] && encodeNumber(0L) == [0x80]);
    assert(encodeNumber(-42L) == [0x3E, 0x3B, 0x66]);
    assert(encodeNumber(100L) == [0xC2, 0x02] && encodeNumber(1234L) == [0xC2, 0x0D, 0x23]);
    foreach (long v; [long.max, long.min, 1, -1, 99, 101, 10_000_000_000, -123_456_789])
        assert(decodeNumber(encodeNumber(v)).toString == to!string(v));
    assert(decodeNumber(encodeUnsignedNumber(ulong.max)).toString == "18446744073709551615");
    foreach (s; [
        "0.5", "-12.345", "0.001", "1234567890123456789012345678.0123456789", "-0.000000012"
    ])
        assert(decodeNumber(encodeNumber(Decimal.fromString(s))).toString == s);
    assert(encodeNumber(Decimal.fromString("1.50")) == [0xC1, 0x02, 0x33]); // the same bytes as python's 1.5

    assert(encodeBinaryFloat(1.5f) == [0xBF, 0xC0, 0x00, 0x00] && encodeBinaryFloat(-1f) == [
        0x40, 0x7F, 0xFF, 0xFF
    ]);
    assert(encodeBinaryDouble(-2.25) == [0x3F, 0xFD, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]);

    assert(encodeDate(DateTime(2026, 11, 3, 10, 20, 30)) == [
        0x78, 0x7E, 0x0B, 0x03, 0x0B, 0x15, 0x1F
    ]);
    assert(decodeDateTime(encodeDate(DateTime(-4711, 1, 1))).year == -4712);
    const ts = encodeTimestamp(DateTime(2026, 11, 3, 10, 20, 30), 123_456_789);
    assert(decodeDateTime(ts).nanoseconds == 123_456_789 && ts.length == 11);
    const tz = encodeTimestampTz(SysTime(DateTime(2026, 11, 3, 10, 20, 30), hnsecs(5_000_000),
            new immutable SimpleTimeZone(minutes(150))));
    // the bytes of TIMESTAMP '2026-11-03 10:20:30.5 +02:30' from Oracle 26ai
    assert(tz == [0x78, 0x7E, 0x0B, 0x03, 0x08, 0x33, 0x1F, 0x1D, 0xCD, 0x65, 0x00, 0x16, 0x5A]);
    assert(decodeZone(encodeTimestampTz(SysTime(DateTime(2026, 1, 1), new immutable SimpleTimeZone(minutes(-30)))))
            .offsetMinutes == -30);

    const ds = days(3) + hours(4) + minutes(5) + seconds(6) + hnsecs(7_890_000);
    assert(encodeIntervalDs(ds) == [0x80, 0, 0, 3, 0x40, 0x41, 0x42, 0xAF, 0x07, 0x2F, 0x40]);
    assert(decodeDayToSecond(encodeIntervalDs(-ds)).duration == -ds);
    assert(encodeIntervalYm(MonthInterval(-27)) == [0x7F, 0xFF, 0xFF, 0xFE, 0x39]);
    assert(decodeYearToMonth(encodeIntervalYm(MonthInterval(27))).monthInterval == MonthInterval(27));
}
