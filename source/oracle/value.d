/++
One column value of a result row, with conversions to D types.

Getters return the type's default value (0, `null`, `.init`) for NULL; check
`isNull` to tell NULL from such values. Conversions that don't make sense for
a column's type throw `ClientException`.

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module oracle.value;

import std.conv : to;
import core.time : Duration;
import std.datetime.date : Date, DateTime, TimeOfDay;
import std.datetime.systime : SysTime;
import std.datetime.timezone : TimeZone, UTC;
import std.typecons : Rebindable;
import std.traits : hasElaborateCopyConstructor, hasElaborateDestructor;
import std.variant : Variant;
import dbwire.types.decimal : Decimal;
import dbwire.types.interval : MonthInterval;
import oracle.exception : ClientException;
import oracle.connection : Connection;
import oracle.lob : Lob;
import oracle.types.typeinfo : CharsetForm, ColumnInfo, OracleType;
import oracle.types.vector : Vector;
import std.json : JSONValue;

// The deepest JSON text `getJson` parses (std.json recurses); as deep as the OSON decoder goes.
private enum maxJsonDepth = 1000;

/// A column value: its metadata and its bytes in the wire form (`null` for NULL).

struct Value
{
    /// The column.
    ColumnInfo column;
    /// The bytes as the server sent them; `null` for NULL.
    immutable(ubyte)[] bytes;
    /++
    The session and database time zones, for TIMESTAMP WITH LOCAL TIME ZONE
    values: they come in the database time zone and are shown in the
    session's (UTC when null).
    +/
    Rebindable!(immutable TimeZone) sessionZone;
    /// ditto
    Rebindable!(immutable TimeZone) databaseZone;
    /// The connection, for reading LOBs fetched as locators, and its lease then (pooled connections).
    package(oracle) Connection connection;
    /// ditto
    package(oracle) ulong lease;

    /// Whether the value is NULL (empty strings are NULL in Oracle).
    @property bool isNull() const @safe pure nothrow
    {
        return bytes is null;
    }

    /++
    The value as text:
    $(UL
    $(LI strings as they are; RAW in upper-case hexadecimal; ROWIDs in their base-64 form;)
    $(LI NUMBER in plain decimal notation (`-12.5`, `0.001`), BINARY_FLOAT and
         BINARY_DOUBLE as the shortest text that reads back exactly (`0.1`, `1e+300`, `Nan`, `Inf`);)
    $(LI dates and timestamps as `YYYY-MM-DD HH:MI:SS` with the column's
         fraction digits, then the offset (`+02:30`) or region (`Europe/Lisbon`)
         of TIMESTAMP WITH TIME ZONE values. The local time of a region comes
         from the system's time zone database; for regions it doesn't know
         (all on Windows) the text is the UTC time followed by `UTC`;)
    $(LI intervals as SQL writes them: `+02-03`, `+03 04:05:06.789000`;)
    $(LI JSON as `JSON_SERIALIZE` writes it (`{"a":1}`; dates and timestamps
         as ISO 8601 strings, RAW as hexadecimal); VECTOR as `FROM_VECTOR`
         writes it (`[1.5E+000,2.0E+000]`, see `Vector.toString`).)
    )
    `null` for NULL.

    Throws: `ClientException` for types without a text form yet.
    +/
    string getString() const @safe
    {
        import oracle.protocol.auth : hex;
        import oracle.types.floats : decodeBinaryFloat, floatText;
        import oracle.types.number : decodeNumber;
        import oracle.types.rowid : rowidText, urowidText;
        import oracle.types.oson : isOson, osonToText;
        import oracle.types.temporal;
        import oracle.types.vector : decodeVector;

        if (isNull)
            return null;
        switch (column.type)
        {
        case OracleType.varchar:
        case OracleType.char_:
        case OracleType.long_:
            return text();
        case OracleType.number:
            return decodeNumber(bytes).toString();
        case OracleType.binaryFloat:
        case OracleType.binaryDouble:
            return floatText(decodeBinaryFloat(bytes), column.type == OracleType.binaryFloat);
        case OracleType.raw:
        case OracleType.longRaw:
            return hex(bytes);
        case OracleType.clob:
            return column.wireType == OracleType.clob ? getLob().readText() : text();
        case OracleType.blob:
            const blob = getBytes();
            return column.isOson && isOson(blob) ? osonToText(blob) : hex(blob); // JSON in a BLOB (older clients)
        case OracleType.bfile:
            return hex(getBytes());
        case OracleType.json:
            return osonToText(bytes);
        case OracleType.vector:
            return decodeVector(bytes).toString();
        case OracleType.rowid:
            return rowidText(bytes);
        case OracleType.urowid:
            return urowidText(bytes);
        case OracleType.date:
            return decodeDateTime(bytes).text(0);
        case OracleType.timestamp:
            return decodeDateTime(bytes).text(column.scale);
        case OracleType.timestampLtz:
            return localTime().text(column.scale);
        case OracleType.timestampTz:
            const utc = decodeDateTime(bytes);
            const zone = decodeZone(bytes);
            if (!hasLocalTime(zone))
                return utc.text(column.scale) ~ " UTC"; // no rules for the region here: the instant, honestly labelled
            return localDateTime(utc, zone).text(column.scale) ~ " " ~ zone.text;
        case OracleType.intervalYm:
            return decodeYearToMonth(bytes).text(column.precision);
        case OracleType.intervalDs:
            return decodeDayToSecond(bytes).text(column.precision, column.scale);
        case OracleType.boolean:
            return getBool() ? "true" : "false";
        default:
            throw unsupported("string");
        }
    }

    /++
    As a `long`: NUMBER (whole numbers), BINARY_FLOAT/DOUBLE (whole
    numbers), strings holding an integer, BOOLEAN (0/1).

    Throws: `ClientException` for other types, fractions, or values out of range.
    +/
    long getLong() const @safe
    {
        import std.conv : ConvException;
        import std.math : isFinite;
        import oracle.types.floats : decodeBinaryFloat;
        import oracle.types.number : numberToLong;

        if (isNull)
            return 0;
        switch (column.type)
        {
        case OracleType.number:
            return numberToLong(bytes);
        case OracleType.binaryFloat:
        case OracleType.binaryDouble:
            const d = decodeBinaryFloat(bytes);
            if (!isFinite(d) || d != cast(long) d || d >= 0x1p63 || d < -0x1p63)
                throw new ClientException("Value " ~ getString() ~ " is not a long (column " ~ column.name ~ ")");
            return cast(long) d;
        case OracleType.varchar:
        case OracleType.char_:
        case OracleType.long_:
            const s = trimmed();
            try
                return s.to!long;
            catch (ConvException)
                throw new ClientException("'" ~ s ~ "' is not an integer (column " ~ column.name ~ ")");
        case OracleType.boolean:
            return getBool() ? 1 : 0;
        default:
            throw unsupported("long");
        }
    }

    /++
    As an `int` (see `getLong`).

    Throws: `ClientException` as `getLong`, or if the value doesn't fit.
    +/
    int getInt() const @safe
    {
        const v = getLong();
        if (v < int.min || v > int.max)
            throw new ClientException("Value " ~ to!string(v) ~ " does not fit in an int (column " ~ column.name ~ ")");
        return cast(int) v;
    }

    /++
    As a `bool`: BOOLEAN; numbers (non-zero is true); strings `true`/`false`,
    `1`/`0`, `Y`/`N`.

    Throws: `ClientException` for other types or texts.
    +/
    bool getBool() const @safe pure
    {
        import std.ascii : toUpper;

        if (isNull)
            return false;
        switch (column.type)
        {
        case OracleType.boolean:
            return bytes.length && bytes[$ - 1] != 0;
        case OracleType.varchar:
        case OracleType.char_:
            // upper case in a stack buffer (the words are ASCII; longer texts match none)
            const t = trimmed();
            char[5] upper;
            const n = t.length <= upper.length ? t.length : 0;
            foreach (i; 0 .. n)
                upper[i] = toUpper(t[i]);
            switch (upper[0 .. n])
            {
            case "TRUE":
            case "1":
            case "Y":
            case "YES":
                return true;
            case "FALSE":
            case "0":
            case "N":
            case "NO":
                return false;
            default:
                throw new ClientException("'" ~ text() ~ "' is not a boolean (column " ~ column.name ~ ")");
            }
        case OracleType.number:
            import oracle.types.number : decodeNumber;

            return decodeNumber(bytes).digits.length != 0;
        case OracleType.binaryFloat:
        case OracleType.binaryDouble:
            return getDouble() != 0;
        default:
            throw unsupported("bool");
        }
    }

    /++
    As a `double`: NUMBER (the nearest double), BINARY_FLOAT/DOUBLE, strings
    holding a number.

    Throws: `ClientException` for other types or texts.
    +/
    double getDouble() const @safe pure
    {
        import std.conv : ConvException;
        import oracle.types.floats : decodeBinaryFloat;
        import oracle.types.number : numberToDouble;

        if (isNull)
            return 0;
        switch (column.type)
        {
        case OracleType.number:
            return numberToDouble(bytes);
        case OracleType.binaryFloat:
        case OracleType.binaryDouble:
            return decodeBinaryFloat(bytes);
        case OracleType.varchar:
        case OracleType.char_:
        case OracleType.long_:
            const s = trimmed();
            try
                return s.to!double;
            catch (ConvException)
                throw new ClientException("'" ~ s ~ "' is not a number (column " ~ column.name ~ ")");
        default:
            throw unsupported("double");
        }
    }

    /++
    As an exact `Decimal`: NUMBER (exactly, its scale being the digits after
    the point), BINARY_FLOAT/DOUBLE (their shortest text), strings holding a number.

    Throws: `ClientException` for other types, infinities and NaN.
    +/
    Decimal getDecimal() const @safe
    {
        import dbwire.types.wideint : Int256;
        import oracle.types.number : decodeNumber;

        if (isNull)
            return Decimal.init;
        switch (column.type)
        {
        case OracleType.number:
            const n = decodeNumber(bytes);
            if (n.infinite)
                throw new ClientException("NUMBER infinity is not a decimal (column " ~ column.name ~ ")");
            if (n.digits.length == 0)
                return Decimal.init;
            return Decimal(Int256.fromString((n.negative ? "-" : "") ~ n.digits),
                    cast(int) n.digits.length - n.pointPosition);
        case OracleType.binaryFloat:
        case OracleType.binaryDouble:
            import std.math : isFinite;
            import oracle.types.floats : decodeBinaryFloat, floatDigits;

            const v = decodeBinaryFloat(bytes);
            if (!isFinite(v))
                throw new ClientException(getString() ~ " is not a decimal (column " ~ column.name ~ ")");
            // the shortest digits that read back, as plain text (`1e-7` is 0.0000001)
            return Decimal.fromString(floatDigits(v, column.type == OracleType.binaryFloat).toString());
        case OracleType.varchar:
        case OracleType.char_:
            return Decimal.fromString(trimmed());
        default:
            throw unsupported("Decimal");
        }
    }

    /++
    The bytes: RAW and LONG RAW as they are; text as UTF-8; other types in
    their wire form (e.g. the NUMBER bytes); `null` for NULL.
    +/
    immutable(ubyte)[] getBytes() const @safe
    {
        if (isNull)
            return null;
        if (column.isLob && column.wireType != OracleType.long_ && column.wireType != OracleType.longRaw)
            return column.type == OracleType.clob ? cast(immutable(ubyte)[]) getLob().readText() : getLob().read();
        if (column.charsetForm != 0 && isText)
            return cast(immutable(ubyte)[]) text();
        return bytes;
    }

    /++
    The LOB of a CLOB, NCLOB or BLOB column fetched as locators
    (`ConnectionOptions.lobLocators`), or of a BFILE column; null for NULL.

    Throws: `ClientException` for other columns (LOB contents fetched as values: use `getString`, `getBytes`).
    +/
    Lob getLob() const @safe pure
    {
        if (isNull)
            return null;
        const t = column.wireType;
        if (t != OracleType.clob && t != OracleType.blob && t != OracleType.bfile)
            throw new ClientException("Column " ~ column.name ~ " has no LOB locators (" ~ (column.isLob
                    ? "LOB contents are fetched as values: set lob_locators for locators)" : "not a LOB)"));
        if (connection is null)
            throw new ClientException("No connection to read the LOB with");
        // CLOB and BLOB values are kept as u64be size, u32be chunk size, locator; BFILE values are the locator
        const locator = t == OracleType.bfile ? bytes : bytes.length >= 12 ? bytes[12 .. $] : null;
        // const only because the value is: no Connection is ever immutable, so the reference may be mutable again
        return new Lob((() @trusted => cast(Connection) connection)(), lease, column.type, column.charsetForm, locator);
    }

    /++
    The size the server reported with a LOB locator (characters or bytes), without a round trip.

    Throws: `ClientException` for values that are not CLOB/NCLOB/BLOB locators.
    +/
    ulong getLobSize() const @safe pure
    {
        if (isNull)
            return 0;
        const t = column.wireType;
        if ((t != OracleType.clob && t != OracleType.blob) || bytes.length < 12)
            throw unsupported("LOB size");
        ulong size;
        foreach (b; bytes[0 .. 8])
            size = (size << 8) | b;
        return size;
    }

    /++
    As a `DateTime` (without the fraction of a second): DATE, TIMESTAMP and
    WITH LOCAL TIME ZONE as they are, WITH TIME ZONE in its own zone.

    Throws: `ClientException` for other types, or dates `std.datetime` can't
    represent.
    +/
    DateTime getDateTime() const @safe
    {
        import oracle.types.temporal;

        if (isNull)
            return DateTime.init;
        switch (column.type)
        {
        case OracleType.date:
        case OracleType.timestamp:
            return decodeDateTime(bytes).dateTime;
        case OracleType.timestampLtz:
            return localTime().dateTime;
        case OracleType.timestampTz:
            return localDateTime(decodeDateTime(bytes), decodeZone(bytes)).dateTime;
        default:
            throw unsupported("DateTime");
        }
    }

    /// The date of `getDateTime`.
    Date getDate() const @safe
    {
        return isNull ? Date.init : getDateTime().date;
    }

    /// The time of day of `getDateTime` (without the fraction of a second).
    TimeOfDay getTime() const @safe
    {
        return isNull ? TimeOfDay.init : getDateTime().timeOfDay;
    }

    /++
    As a `SysTime`, to 100 ns (see `getNanoseconds` for the exact fraction):
    WITH TIME ZONE in its zone (an offset, or the system's zone of that
    region; UTC on systems without a time zone database); WITH LOCAL TIME
    ZONE in the session time zone; DATE and TIMESTAMP, which have no time
    zone, taken as UTC.

    Throws: `ClientException` for other types, or dates `std.datetime` can't
    represent.
    +/
    SysTime getSysTime() const @safe
    {
        import oracle.types.temporal;

        if (isNull)
            return SysTime.init;
        switch (column.type)
        {
        case OracleType.date:
        case OracleType.timestamp:
            const d = decodeDateTime(bytes);
            return SysTime(d.dateTime, d.fraction, UTC());
        case OracleType.timestampLtz:
            return instant().toOtherTZ(zoneOrUtc(sessionZone));
        case OracleType.timestampTz:
            return zonedSysTime(decodeDateTime(bytes), decodeZone(bytes));
        default:
            throw unsupported("SysTime");
        }
    }

    /++
    The fraction of a second in nanoseconds: TIMESTAMP values (all kinds),
    INTERVAL DAY TO SECOND (negative for negative intervals); 0 for DATE.

    Throws: `ClientException` for other types.
    +/
    int getNanoseconds() const @safe pure
    {
        import oracle.types.temporal;

        if (isNull)
            return 0;
        switch (column.type)
        {
        case OracleType.date:
            return 0;
        case OracleType.timestamp:
        case OracleType.timestampLtz:
        case OracleType.timestampTz:
            return decodeDateTime(bytes).nanoseconds;
        case OracleType.intervalDs:
            return decodeDayToSecond(bytes).nanoseconds;
        default:
            throw unsupported("nanoseconds");
        }
    }

    /++
    As a `Duration`, to 100 ns: INTERVAL DAY TO SECOND.

    Throws: `ClientException` for other types, or intervals beyond about 10.7 million days.
    +/
    Duration getDuration() const @safe pure
    {
        import oracle.types.temporal : decodeDayToSecond;

        if (isNull)
            return Duration.zero;
        if (column.type != OracleType.intervalDs)
            throw unsupported("Duration");
        const d = decodeDayToSecond(bytes);
        // Duration counts 100 ns in a long: about 10.7 million days; INTERVAL DAY(9) goes to 999,999,999
        enum maxDays = Duration.max.total!"days" - 1;
        if (d.days > maxDays || d.days < -maxDays)
            throw new ClientException("The interval in column " ~ column.name ~ " is too long for a Duration");
        return d.duration;
    }

    /++
    As a `MonthInterval`: INTERVAL YEAR TO MONTH.

    Throws: `ClientException` for other types, or intervals beyond `int.max` months.
    +/
    MonthInterval getMonthInterval() const @safe pure
    {
        import oracle.types.temporal : decodeYearToMonth;

        if (isNull)
            return MonthInterval.init;
        if (column.type != OracleType.intervalYm)
            throw unsupported("MonthInterval");
        return decodeYearToMonth(bytes).monthInterval;
    }

    /++
    The value of a JSON column as a `std.json` value (numbers become `long`,
    `ulong` or `double`; dates and RAW stay strings: use `getString` for the
    exact text). `JSONValue(null)` for NULL.

    Throws: `ClientException` for other types.
    +/
    JSONValue getJson() const @safe
    {
        import std.json : JSONException, parseJSON;

        if (isNull)
            return JSONValue(null);
        if (column.type != OracleType.json && !column.isJson)
            throw unsupported("JSON");
        import std.conv : ConvException;

        const text = getString();
        try
            return parseJSON(text, maxJsonDepth); // a depth limit: the parser recurses
        catch (JSONException e)
            throw new ClientException("Column " ~ column.name ~ " is not valid JSON: " ~ e.msg);
        catch (ConvException e) // a number out of range, e.g. 1e400
            throw new ClientException("Column " ~ column.name ~ " is not valid JSON: " ~ e.msg);
    }

    /++
    The value of a VECTOR column (`Vector.init` for NULL).

    Throws: `ClientException` for other types.
    +/
    Vector getVector() const @safe pure
    {
        import oracle.types.vector : decodeVector;

        if (isNull)
            return Vector.init;
        if (column.type != OracleType.vector)
            throw unsupported("Vector");
        return decodeVector(bytes);
    }

    /++
    As a `Variant` of the type's natural D type; an empty `Variant` for NULL:
    $(UL
    $(LI NUMBER: `long` for whole-number columns of up to 18 digits
         (`NUMBER(p)`, p ≤ 18), else `Decimal`; BINARY_FLOAT `float`, BINARY_DOUBLE `double`;)
    $(LI character types, CLOB, NCLOB, ROWID, UROWID: `string`; RAW, LONG RAW, BLOB: `ubyte[]`; BFILE: `Lob`;)
    $(LI DATE: `DateTime`; TIMESTAMP (all kinds): `SysTime` (see `getSysTime`);)
    $(LI INTERVAL YEAR TO MONTH: `MonthInterval`; DAY TO SECOND: `Duration`; BOOLEAN: `bool`;)
    $(LI JSON: its text (`string`); VECTOR: `Vector`.)
    )

    Throws: `ClientException` for types that are not supported yet.
    +/
    Variant getVariant() const @safe
    {
        if (isNull)
            return Variant.init;
        switch (column.type)
        {
        case OracleType.number:
            if (column.scale == 0 && column.precision > 0 && column.precision <= 18)
                return makeVariant(getLong());
            return makeVariant(getDecimal());
        case OracleType.binaryFloat:
            return makeVariant(cast(float) getDouble());
        case OracleType.binaryDouble:
            return makeVariant(getDouble());
        case OracleType.varchar:
        case OracleType.char_:
        case OracleType.long_:
        case OracleType.rowid:
        case OracleType.urowid:
            return makeVariant(getString());
        case OracleType.raw:
        case OracleType.longRaw:
            return makeVariant(bytes.dup);
        case OracleType.clob:
            return makeVariant(getString());
        case OracleType.blob:
            return makeVariant(getBytes().dup);
        case OracleType.bfile:
            return makeVariant(getLob());
        case OracleType.date:
            return makeVariant(getDateTime());
        case OracleType.timestamp:
        case OracleType.timestampLtz:
        case OracleType.timestampTz:
            return makeVariant(getSysTime());
        case OracleType.intervalYm:
            return makeVariant(getMonthInterval());
        case OracleType.intervalDs:
            return makeVariant(getDuration());
        case OracleType.boolean:
            return makeVariant(getBool());
        case OracleType.json:
            return makeVariant(getString());
        case OracleType.vector:
            return makeVariant(getVector());
        default:
            throw unsupported("Variant");
        }
    }

    /// The instant of a WITH LOCAL TIME ZONE value (sent in the database time zone).
    private SysTime instant() const @safe
    {
        import oracle.types.temporal : decodeDateTime;

        const d = decodeDateTime(bytes);
        return SysTime(d.dateTime, d.fraction, zoneOrUtc(databaseZone));
    }

    /// A WITH LOCAL TIME ZONE value in the session time zone.
    private auto localTime() const @safe
    {
        import oracle.types.temporal : OracleDateTime, decodeDateTime;

        const local = cast(DateTime) instant().toOtherTZ(zoneOrUtc(sessionZone));
        OracleDateTime d;
        d.year = local.year <= 0 ? local.year - 1 : local.year;
        d.month = local.month;
        d.day = local.day;
        d.hour = local.hour;
        d.minute = local.minute;
        d.second = local.second;
        d.nanoseconds = decodeDateTime(bytes).nanoseconds;
        return d;
    }

    private bool isText() const @safe pure nothrow
    {
        return column.type == OracleType.varchar || column.type == OracleType.char_ || column.type == OracleType.long_;
    }

    /++
    The text of a character value: UTF-8 (the client's character set) or, for
    national character data in AL16UTF16, UTF-16 big-endian.
    +/
    private string text() const @safe pure
    {
        import std.utf : UTFException, validate;
        import dbwire.charset.utf16 : decodeUtf16be;
        import oracle.protocol.negotiate : CharsetId;

        if (column.charsetId == CharsetId.al16utf16)
        {
            if (bytes.length % 2)
                throw new ClientException("Invalid UTF-16 text in column " ~ column.name);
            return decodeUtf16be(bytes);
        }
        const s = cast(string) bytes;
        try
            validate(s);
        catch (UTFException)
            throw new ClientException("Invalid UTF-8 text in column " ~ column.name);
        return s;
    }

    private string trimmed() const @safe pure
    {
        import std.string : strip;

        return text().strip;
    }

    private ClientException unsupported(string what) const @safe pure
    {
        return new ClientException("Column " ~ column.name ~ " (" ~ column.typeText() ~ ") can't be read as a " ~ what);
    }
}

private immutable(TimeZone) zoneOrUtc(const Rebindable!(immutable TimeZone) zone) @safe nothrow
{
    return zone is null ? UTC() : zone.get;
}

/++
Wraps a value in a `Variant`: memory-safe, but `std.variant` is not annotated
`@safe`. Only for types whose copy and destruction are plain (the attribute
would hide a `@system` postblit, copy constructor or destructor of `T`).
+/
package(oracle) Variant makeVariant(T)(T value) @trusted
        if (!hasElaborateCopyConstructor!T && !hasElaborateDestructor!T)
{
    return Variant(value);
}

///
@safe unittest
{
    import core.time : hnsecs;

    ColumnInfo c;
    c.name = "C";
    c.type = OracleType.number;
    immutable ubyte[] fortyTwo = [0xC1, 0x2B];
    assert(Value(c, fortyTwo).getLong() == 42 && Value(c, fortyTwo).getString() == "42");
    assert(Value(c, fortyTwo).getDecimal() == Decimal.fromLong(42) && Value(c, fortyTwo).getBool());
    immutable ubyte[] half = [0xC0, 0x33]; // 0.5
    assert(Value(c, half).getDecimal().toString() == "0.5" && Value(c, half).getDouble() == 0.5);
    assert(Value(c, null).isNull && Value(c, null).getLong() == 0 && Value(c, null).getString() is null);

    c.type = OracleType.timestamp;
    c.scale = 3;
    immutable ubyte[] ts = [0x78, 0x7E, 0x0B, 0x03, 0x0B, 0x15, 0x1F, 0x07, 0x5B, 0xCD, 0x15];
    const v = Value(c, ts);
    assert(v.getString() == "2026-11-03 10:20:30.123" && v.getNanoseconds() == 123_456_789);
    assert(v.getSysTime() == SysTime(DateTime(2026, 11, 3, 10, 20, 30), hnsecs(1_234_567), UTC()));
    assert((() @trusted => v.getVariant().get!SysTime)() == v.getSysTime());

    c.type = OracleType.binaryDouble;
    immutable ubyte[] small = [0xBE, 0x84, 0x21, 0xF5, 0xF4, 0x0D, 0x83, 0x76]; // 1.5e-7
    assert(Value(c, small).getDecimal().toString() == "0.00000015");
}

// getJson: nesting is limited (the parser recurses), out-of-range numbers are a ClientException;
// getDuration: intervals beyond what a Duration holds are refused
@safe unittest
{
    import core.time : days;
    import std.array : replicate;
    import std.exception : assertThrown, collectException;

    ColumnInfo c;
    c.name = "J";
    c.type = OracleType.varchar;
    c.isJson = true;
    c.charsetId = 873;
    assertThrown!ClientException(Value(c, cast(immutable(ubyte)[]) "[".replicate(100_000)).getJson());
    // Phobos 2.106 throws ConvException for it, 2.097 gives infinity
    auto e = collectException(Value(c, cast(immutable(ubyte)[]) `{"a":1e400}`).getJson());
    assert(e is null || cast(ClientException) e !is null, e.msg);
    assert(Value(c, cast(immutable(ubyte)[]) `{"a":[[1]]}`).getJson()["a"][0][0].integer == 1);

    ColumnInfo d;
    d.name = "D";
    d.type = OracleType.intervalDs;
    immutable(ubyte)[] interval(uint days) @safe
    {
        const biased = days + 0x8000_0000u;
        return [
            cast(ubyte)(biased >> 24), cast(ubyte)(biased >> 16), cast(ubyte)(biased >> 8),
            cast(ubyte) biased, 60,
            60, 60, 0x80, 0, 0, 0
        ];
    }

    assert(Value(d, interval(10_000_000)).getDuration() == days(10_000_000));
    assertThrown!ClientException(Value(d, interval(999_999_999)).getDuration());
}
