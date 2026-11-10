/++
DATE, TIMESTAMP (with time zone, with local time zone) and INTERVAL values in
their wire form.

$(UL
$(LI DATE: 7 bytes: century + 100, year in the century + 100, month, day,
     hour + 1, minute + 1, second + 1. Years before 1 are negative (Oracle
     has no year 0).)
$(LI TIMESTAMP, WITH LOCAL TIME ZONE: the DATE bytes, then the nanoseconds
     as a big-endian u32 (left out when zero).)
$(LI TIMESTAMP WITH TIME ZONE: the date and time in UTC, the nanoseconds,
     then the zone: hours + 20 and minutes + 60, or with the high bit of the
     first byte set a 13-bit region ID (see `oracle.types.tzregions`).)
$(LI INTERVAL YEAR TO MONTH: years + 2³¹ (big-endian u32), months + 60.)
$(LI INTERVAL DAY TO SECOND: days + 2³¹, hours + 60, minutes + 60,
     seconds + 60, nanoseconds + 2³¹.)
)

Dates are labels: Oracle uses the Julian calendar before 1582-10-15 and
`std.datetime` the proleptic Gregorian one, so such dates convert by their
year, month and day, not by the day they denote.

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module oracle.types.temporal;

import std.conv : to;
import core.time : Duration, days, hnsecs, hours, minutes, nsecs, seconds;
import std.datetime.date : Date, DateTime, DateTimeException;
import std.datetime.systime : SysTime;
import std.datetime.timezone : SimpleTimeZone, TimeZone, UTC;
import dbwire.types.interval : MonthInterval;
import oracle.exception : ClientException, ProtocolException;

/// A DATE or TIMESTAMP value, as Oracle labels it.
struct OracleDateTime
{
    /// The year (negative before 1: -1 is 1 BC), month, day, hour, minute, second.
    int year;
    /// ditto
    ubyte month, day, hour, minute, second;
    /// Nanoseconds.
    uint nanoseconds;

    /++
    As a `DateTime`. Years before 1 become astronomical years (1 BC is year 0
    in `std.datetime`).

    Throws: `ClientException` if `std.datetime` can't represent the date
    (e.g. a Julian leap day such as 1500-02-29).
    +/
    DateTime dateTime() const @safe pure
    {
        try
            return DateTime(year < 0 ? year + 1 : year, month, day, hour, minute, second);
        catch (DateTimeException)
            throw new ClientException("Date " ~ text(0) ~ " can't be represented as a std.datetime DateTime");
    }

    /// The fraction of a second as a `Duration`, truncated to 100 ns.
    Duration fraction() const @safe pure nothrow
    {
        return hnsecs(nanoseconds / 100);
    }

    /// `YYYY-MM-DD HH:MI:SS` and, if `fractionDigits` > 0, `.` and that many digits of the fraction.
    string text(int fractionDigits) const @safe pure
    {
        import std.format : format;

        auto s = format("%s%04d-%02d-%02d %02d:%02d:%02d", year < 0 ? "-" : "", year < 0 ? -year : year, month,
                day, hour, minute, second);
        if (fractionDigits > 0)
            s ~= "." ~ format("%09d", nanoseconds)[0 .. fractionDigits > 9 ? 9 : fractionDigits];
        return s;
    }
}

/// The time zone of a TIMESTAMP WITH TIME ZONE: an offset or a region.
struct OracleZone
{
    /// Whether it is a region (else an offset).
    bool isRegion;
    /// The offset from UTC in minutes.
    int offsetMinutes;
    /// The region ID and name.
    ushort regionId;
    /// ditto
    string regionName;

    /// `+02:30`, `-08:00`, or the region name.
    string text() const @safe pure
    {
        import std.format : format;

        if (isRegion)
            return regionName;
        const m = offsetMinutes < 0 ? -offsetMinutes : offsetMinutes;
        return format("%s%02d:%02d", offsetMinutes < 0 ? "-" : "+", m / 60, m % 60);
    }

    /++
    The `std.datetime` time zone: a `SimpleTimeZone` for an offset, the
    system's zone of that name for a region (UTC on systems without a time
    zone database, such as Windows).
    +/
    immutable(TimeZone) timeZone() const @safe
    {
        import dbwire.types.timezone : resolveTimeZone;

        if (isRegion)
            return resolveTimeZone(regionName);
        if (offsetMinutes == 0)
            return UTC();
        return new immutable SimpleTimeZone(minutes(offsetMinutes));
    }
}

/++
Decodes DATE and TIMESTAMP bytes (7 or 11; also the first 11 of a TIMESTAMP
WITH TIME ZONE).

Throws: `ProtocolException` for malformed values.
+/
OracleDateTime decodeDateTime(scope const(ubyte)[] b) @safe pure
{
    if (b.length != 7 && b.length != 11 && b.length != 13)
        throw new ProtocolException("Invalid date/time length " ~ to!string(b.length));
    OracleDateTime d;
    d.year = (b[0] - 100) * 100 + (b[1] - 100);
    d.month = b[2];
    d.day = b[3];
    d.hour = cast(ubyte)(b[4] - 1);
    d.minute = cast(ubyte)(b[5] - 1);
    d.second = cast(ubyte)(b[6] - 1);
    if (b.length >= 11)
        d.nanoseconds = u32(b[7 .. 11]);
    if (d.month < 1 || d.month > 12 || d.day < 1 || d.day > 31 || d.hour > 23 || d.minute > 59 || d.second > 59
            || d.nanoseconds > 999_999_999 || d.year == 0)
        throw new ProtocolException("Invalid date/time value");
    return d;
}

/++
Decodes the zone bytes of a TIMESTAMP WITH TIME ZONE (13 bytes).

Throws: `ProtocolException` for malformed values; `ClientException` for a
region ID this client doesn't know (a newer time zone file).
+/
OracleZone decodeZone(scope const(ubyte)[] b) @safe pure
{
    if (b.length != 13)
        throw new ProtocolException("Invalid TIMESTAMP WITH TIME ZONE length " ~ to!string(b.length));
    OracleZone z;
    if (b[11] & 0x80)
    {
        z.isRegion = true;
        z.regionId = cast(ushort)(((b[11] & 0x7F) << 6) | (b[12] >> 2));
        z.regionName = regionName(z.regionId);
        if (z.regionName is null)
            throw new ClientException("Unknown time zone region ID " ~ to!string(
                    z.regionId)
                    ~ " (from a newer time zone file than this client knows)");
    }
    else
    {
        const h = b[11] - 20, m = b[12] - 60;
        if (h < -15 || h > 15 || m < -59 || m > 59)
            throw new ProtocolException("Invalid time zone offset");
        z.offsetMinutes = h * 60 + m;
    }
    return z;
}

/// The name of a time zone region ID, or null.
string regionName(ushort id) @safe pure nothrow @nogc
{
    import oracle.types.tzregions : timeZoneRegions;

    size_t lo = 0, hi = timeZoneRegions.length;
    while (lo < hi)
    {
        const mid = (lo + hi) / 2;
        if (timeZoneRegions[mid].id < id)
            lo = mid + 1;
        else
            hi = mid;
    }
    return lo < timeZoneRegions.length && timeZoneRegions[lo].id == id ? timeZoneRegions[lo].name : null;
}

/++
Whether the local time of `zone` can be computed here: offsets always; regions
when the system's time zone database has the name (never on Windows).
+/
bool hasLocalTime(const OracleZone zone) @safe
{
    import dbwire.types.timezone : resolveTimeZone;

    return !zone.isRegion || zone.regionName == "UTC" || resolveTimeZone(zone.regionName) !is UTC();
}

/// The instant of a TIMESTAMP WITH TIME ZONE, in its zone (UTC for unknown region names on systems without a tz database).
SysTime zonedSysTime(const OracleDateTime utc, const OracleZone zone) @safe
{
    return (SysTime(utc.dateTime, UTC()) + utc.fraction).toOtherTZ(zone.timeZone);
}

/++
The local date and time of a TIMESTAMP WITH TIME ZONE in its zone, with the
nanoseconds.
+/
OracleDateTime localDateTime(const OracleDateTime utc, const OracleZone zone) @safe
{
    DateTime local;
    if (zone.isRegion)
        local = cast(DateTime) SysTime(utc.dateTime, UTC()).toOtherTZ(zone.timeZone);
    else
        local = utc.dateTime + minutes(zone.offsetMinutes);
    OracleDateTime d;
    d.year = local.year <= 0 ? local.year - 1 : local.year;
    d.month = local.month;
    d.day = local.day;
    d.hour = local.hour;
    d.minute = local.minute;
    d.second = local.second;
    d.nanoseconds = utc.nanoseconds;
    return d;
}

/// An INTERVAL YEAR TO MONTH: years and months, both with the interval's sign.
struct YearToMonth
{
    /// The parts.
    int years;
    /// ditto
    int months;

    /++
    As a `MonthInterval`.

    Throws: `ClientException` if the total number of months doesn't fit in an `int`.
    +/
    MonthInterval monthInterval() const @safe pure
    {
        return MonthInterval.fromYearsMonths(years, months);
    }

    /// As SQL writes it: `+02-03`, the years padded to `yearDigits`.
    string text(int yearDigits) const @safe pure
    {
        import std.format : format;

        return format("%s%0*d-%02d", years < 0 || months < 0 ? "-" : "+", yearDigits, abs(years), abs(months));
    }
}

/++
Decodes an INTERVAL YEAR TO MONTH (5 bytes).

Throws: `ProtocolException` for malformed values.
+/
YearToMonth decodeYearToMonth(scope const(ubyte)[] b) @safe pure
{
    if (b.length != 5)
        throw new ProtocolException("Invalid INTERVAL YEAR TO MONTH length " ~ to!string(b.length));
    const years = cast(long) u32(b[0 .. 4]) - 0x8000_0000L;
    const months = b[4] - 60;
    if (months < -11 || months > 11 || years < -999_999_999 || years > 999_999_999)
        throw new ProtocolException("Invalid INTERVAL YEAR TO MONTH value");
    return YearToMonth(cast(int) years, months);
}

/// An INTERVAL DAY TO SECOND: days, hours, minutes, seconds and nanoseconds, all with the interval's sign.
struct DayToSecond
{
    /// The parts.
    int days;
    /// ditto
    int hours, minutes, seconds;
    /// ditto
    int nanoseconds;

    /// As a `Duration`, truncated to 100 ns.
    Duration duration() const @safe pure nothrow
    {
        return .days(days) + .hours(hours) + .minutes(minutes) + .seconds(seconds) + hnsecs(nanoseconds / 100);
    }

    /// As SQL writes it: `+03 04:05:06.789000`, the days padded to `dayDigits`, `fractionDigits` digits of fraction.
    string text(int dayDigits, int fractionDigits) const @safe pure
    {
        import std.format : format;

        const negative = days < 0 || hours < 0 || minutes < 0 || seconds < 0 || nanoseconds < 0;
        auto s = format("%s%0*d %02d:%02d:%02d", negative ? "-" : "+", dayDigits, abs(days), abs(hours),
                abs(minutes), abs(seconds));
        if (fractionDigits > 0)
            s ~= "." ~ format("%09d", abs(nanoseconds))[0 .. fractionDigits > 9 ? 9 : fractionDigits];
        return s;
    }
}

/++
Decodes an INTERVAL DAY TO SECOND (11 bytes).

Throws: `ProtocolException` for malformed values.
+/
DayToSecond decodeDayToSecond(scope const(ubyte)[] b) @safe pure
{
    if (b.length != 11)
        throw new ProtocolException("Invalid INTERVAL DAY TO SECOND length " ~ to!string(b.length));
    DayToSecond d;
    const days = cast(long) u32(b[0 .. 4]) - 0x8000_0000L;
    const ns = cast(long) u32(b[7 .. 11]) - 0x8000_0000L;
    d.hours = b[4] - 60;
    d.minutes = b[5] - 60;
    d.seconds = b[6] - 60;
    if (days < -1_000_000_000 || days > 1_000_000_000 || ns < -999_999_999 || ns > 999_999_999
            || d.hours < -23 || d.hours > 23 || d.minutes < -59 || d.minutes > 59 || d.seconds < -59
            || d.seconds > 59)
        throw new ProtocolException("Invalid INTERVAL DAY TO SECOND value");
    d.days = cast(int) days;
    d.nanoseconds = cast(int) ns;
    return d;
}

private uint u32(scope const(ubyte)[] b) @safe pure nothrow @nogc
{
    return (cast(uint) b[0] << 24) | (b[1] << 16) | (b[2] << 8) | b[3];
}

private int abs(int v) @safe pure nothrow @nogc
{
    return v < 0 ? -v : v;
}

///
@safe unittest
{
    // values from Oracle 26ai
    const d = decodeDateTime([0x78, 0x7E, 0x0B, 0x03, 0x0B, 0x15, 0x1F, 0x07, 0x5B, 0xCD, 0x15]);
    assert(d.text(9) == "2026-11-03 10:20:30.123456789" && d.text(3) == "2026-11-03 10:20:30.123");
    assert(d.text(0) == "2026-11-03 10:20:30" && d.dateTime == DateTime(2026, 11, 3, 10, 20, 30));
    const bc = decodeDateTime([0x35, 0x58, 0x01, 0x01, 0x01, 0x01, 0x01]);
    assert(bc.year == -4712 && bc.text(0) == "-4712-01-01 00:00:00" && bc.dateTime.year == -4711);

    // 10:20:30.5 +02:30, stored as 07:50:30 UTC
    const ubyte[] tz = [
        0x78, 0x7E, 0x0B, 0x03, 0x08, 0x33, 0x1F, 0x1D, 0xCD, 0x65, 0x00, 0x16, 0x5A
    ];
    const z = decodeZone(tz);
    assert(!z.isRegion && z.offsetMinutes == 150 && z.text == "+02:30");
    assert(localDateTime(decodeDateTime(tz), z).text(1) == "2026-11-03 10:20:30.5");
    const ubyte[] lisbon = [
        0x78, 0x7E, 0x07, 0x03, 0x0A, 0x15, 0x1F, 0x1D, 0xCD, 0x65, 0x00, 0x86, 0x3C
    ];
    assert(decodeZone(lisbon).isRegion && decodeZone(lisbon).text == "Europe/Lisbon");
    assert(regionName(5121) == "UTC" && regionName(0) is null);

    const ym = decodeYearToMonth([0x80, 0, 0, 2, 0x3F]);
    assert(ym.monthInterval == MonthInterval(27) && ym.text(2) == "+02-03");
    const negYm = decodeYearToMonth([0x7F, 0xFF, 0xFF, 0xFE, 0x39]);
    assert(negYm.monthInterval == MonthInterval(-27) && negYm.text(4) == "-0002-03");
    const ds = decodeDayToSecond([0x80, 0, 0, 3, 0x40, 0x41, 0x42, 0xAF, 0x07, 0x2F, 0x40]);
    assert(ds.text(2, 6) == "+03 04:05:06.789000");
    assert(ds.duration == days(3) + hours(4) + minutes(5) + seconds(6) + hnsecs(7_890_000));
    const neg = decodeDayToSecond([0x7F, 0xFF, 0xFF, 0xFD, 0x38, 0x37, 0x36, 0x50, 0xF8, 0xD0, 0xC0]);
    assert(neg.text(3, 9) == "-003 04:05:06.789000000" && neg.duration < Duration.zero);
}
