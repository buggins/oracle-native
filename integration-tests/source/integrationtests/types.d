/// Data types: values, getters, and texts compared with the server's.
module integrationtests.types;

import core.time : days, hnsecs, hours, minutes, seconds;
import std.datetime.date : Date, DateTime, TimeOfDay;
import std.datetime.systime : SysTime;
import std.datetime.timezone : UTC;
import std.exception : collectException, enforce;
import std.uni : toUpper;
import std.variant : Variant;

import oracle;
import integrationtests.server;

/// The major version of the server.
private int majorVersion(Connection conn)
{
    import std.algorithm.searching : findSplitBefore;
    import std.conv : to;

    return conn.serverVersion.findSplitBefore(".")[0].to!int;
}

/// `get!T` of a `Variant` (it is @system).
private T variantValue(T)(Variant v) @trusted
{
    return v.get!T;
}

/// BINARY_FLOAT and BINARY_DOUBLE: special values, extremes, texts that read back exactly.
void testFloats()
{
    import std.conv : to;
    import std.math : isNaN;

    auto conn = connectToServer();
    scope (exit)
        conn.close();
    auto r = conn.query("SELECT TO_BINARY_FLOAT('1.5'), TO_BINARY_DOUBLE('-2.25'), TO_BINARY_DOUBLE('0.1'),"
            ~ " TO_BINARY_DOUBLE('NaN'), TO_BINARY_DOUBLE('Inf'), TO_BINARY_DOUBLE('-Inf'),"
            ~ " TO_BINARY_DOUBLE('1.7976931348623157E+308'), TO_BINARY_DOUBLE('4.9E-324'), TO_BINARY_FLOAT('0.1'),"
            ~ " TO_BINARY_FLOAT('3.40282347E+38'), TO_BINARY_DOUBLE('7') FROM dual");
    const row = r.front;
    enforce(row.columns[0].type == OracleType.binaryFloat && row.columns[1].type == OracleType.binaryDouble, "types");
    enforce(row.getDouble(0) == 1.5 && row.getDouble(1) == -2.25 && row.getDouble(2) == 0.1, "values");
    enforce(isNaN(row.getDouble(3)) && row.getString(3) == "Nan", "NaN");
    enforce(row.getString(4) == "Inf" && row.getString(5) == "-Inf", "infinities");
    enforce(row.getDouble(6) == double.max && row.getString(6).to!double == double.max, "maximum");
    enforce(row.getDouble(7) == double.min_normal * double.epsilon, "smallest subnormal");
    enforce(row.getString(8) == "0.1" && row.getString(2) == "0.1", "shortest text");
    enforce(cast(float) row.getDouble(9) == float.max, "float maximum");
    enforce(row.getLong(10) == 7 && row.getDecimal(1).toString == "-2.25", "long and decimal");
    enforce(variantValue!float(row.getVariant(0)) == 1.5f, "float Variant");
    enforce(variantValue!double(row.getVariant(1)) == -2.25, "double Variant");
    r.close();
}

/// NUMBER as exact decimals; Variant types by column type.
void testDecimals()
{
    auto conn = connectToServer();
    scope (exit)
        conn.close();
    dropTable(conn, "itest_dec");
    conn.exec("CREATE TABLE itest_dec (a NUMBER(38,10), b NUMBER(10), c NUMBER, d NUMBER(19))");
    conn.exec("INSERT INTO itest_dec VALUES (1234567890123456789012345678.0123456789, -1234567890, 1e-130, 1e18)");
    auto r = conn.query("SELECT a, b, c, d, TO_CHAR(a) FROM itest_dec");
    const row = r.front;
    enforce(row.getDecimal(0).toString == "1234567890123456789012345678.0123456789", "38 digits: "
            ~ row.getDecimal(0)
                .toString);
    enforce(row.getDecimal(0) == Decimal.fromString(row.getString(4)), "the same as the server's text");
    enforce(row.getDecimal(1) == Decimal.fromLong(-1_234_567_890), "integer");
    enforce(row.getDecimal(2).scale == 130, "1e-130");
    enforce(variantValue!long(row.getVariant(1)) == -1_234_567_890, "NUMBER(10) is a long");
    enforce(variantValue!Decimal(row.getVariant(0)) == row.getDecimal(0), "NUMBER(38,10) is a Decimal");
    enforce(variantValue!Decimal(row.getVariant(3)) == Decimal.fromString("1000000000000000000"),
            "NUMBER(19) is a Decimal");
    r.close();
    dropTable(conn, "itest_dec");
}

/// DATE and TIMESTAMP: texts as the server writes them, SysTime, nanoseconds, years before 1.
void testDatesAndTimestamps()
{
    auto conn = connectToServer();
    scope (exit)
        conn.close();
    // value, the server's format for the same text
    static immutable string[2][] values = [
        ["DATE '2026-11-03'", "YYYY-MM-DD HH24:MI:SS"],
        ["TO_DATE('2026-02-28 23:59:59', 'YYYY-MM-DD HH24:MI:SS')", "YYYY-MM-DD HH24:MI:SS"],
        ["TO_DATE('-4712-01-01 13:14:15', 'SYYYY-MM-DD HH24:MI:SS')", "SYYYY-MM-DD HH24:MI:SS"],
        ["DATE '9999-12-31'", "YYYY-MM-DD HH24:MI:SS"], [
            "DATE '0001-01-01'", "YYYY-MM-DD HH24:MI:SS"
        ],
        ["TIMESTAMP '2026-11-03 10:20:30.123456789'", "YYYY-MM-DD HH24:MI:SS.FF"],
        ["TIMESTAMP '2026-11-03 10:20:30'", "YYYY-MM-DD HH24:MI:SS.FF"],
        ["CAST(TIMESTAMP '2026-07-03 10:20:30.5' AS TIMESTAMP(0))", "YYYY-MM-DD HH24:MI:SS"],
        ["CAST(TIMESTAMP '2026-07-03 10:20:30.5' AS TIMESTAMP(3))", "YYYY-MM-DD HH24:MI:SS.FF"],
        ["TIMESTAMP '1999-12-31 23:59:59.999999999'", "YYYY-MM-DD HH24:MI:SS.FF"],
        ["TIMESTAMP '1582-10-15 00:00:00.000001'", "YYYY-MM-DD HH24:MI:SS.FF"],
    ];
    foreach (v; values)
    {
        auto r = conn.query("SELECT " ~ v[0] ~ ", TO_CHAR(" ~ v[0] ~ ", '" ~ v[1] ~ "') FROM dual");
        const row = r.front;
        enforce(row.getString(0) == row.getString(1), v[0] ~ ": " ~ row.getString(0) ~ " vs " ~ row.getString(1));
        r.close();
    }
    auto r = conn.query("SELECT TIMESTAMP '2026-11-03 10:20:30.123456789', DATE '2026-11-03',"
            ~ " TO_DATE('-0001-12-31', 'SYYYY-MM-DD') FROM dual");
    const row = r.front;
    enforce(row.getSysTime(0) == SysTime(DateTime(2026, 11, 3, 10, 20, 30), hnsecs(1_234_567), UTC()), "SysTime");
    enforce(row.getNanoseconds(0) == 123_456_789 && row.getNanoseconds(1) == 0, "nanoseconds");
    enforce(row.getDate(1) == Date(2026, 11, 3) && row.getTime(0) == TimeOfDay(10, 20, 30), "date and time");
    enforce(row.getDateTime(2) == DateTime(0, 12, 31), "1 BC is year 0");
    enforce(variantValue!DateTime(row.getVariant(1)) == DateTime(2026, 11, 3), "DATE Variant");
    r.close();
}

/// TIMESTAMP WITH TIME ZONE (offsets and regions) and WITH LOCAL TIME ZONE.
void testTimeZones()
{
    import std.algorithm.searching : canFind, endsWith;
    import std.conv : to;

    auto conn = connectToServer();
    scope (exit)
        conn.close();
    static immutable string[] values = [
        "TIMESTAMP '2026-11-03 10:20:30.5 +02:30'", "TIMESTAMP '2026-11-03 10:20:30 -08:00'",
        "TIMESTAMP '2026-07-03 10:20:30.25 Europe/Lisbon'",
        "TIMESTAMP '2026-01-03 10:20:30 Europe/Lisbon'",
        "TIMESTAMP '2026-07-03 10:20:30 America/New_York'", "TIMESTAMP '2026-07-03 10:20:30 UTC'",
        "TIMESTAMP '2026-07-03 23:59:59.999 Asia/Kolkata'", "TIMESTAMP '2026-07-03 00:00:00 -00:30'",
    ];
    foreach (v; values)
    {
        version (Windows)
            if (v.canFind("/"))
                continue; // no time zone database for the local time of regions
        auto r = conn.query("SELECT " ~ v ~ ", TO_CHAR(" ~ v ~ ", 'YYYY-MM-DD HH24:MI:SS.FF TZR'),"
                ~ " TO_CHAR(SYS_EXTRACT_UTC(" ~ v ~ "), 'YYYY-MM-DD HH24:MI:SS') FROM dual");
        const row = r.front;
        enforce(row.getString(0).toUpper == row.getString(1), v ~ ": " ~ row.getString(0) ~ " vs " ~ row.getString(1));
        const utc = row.getSysTime(0).toUTC;
        enforce((cast(DateTime) utc).toISOExtString.replace("T", " ") == row.getString(2), v ~ ": instant "
                ~ utc.toISOExtString);
        r.close();
    }
    // every region the server knows has a name in the client's table; the local time needs the
    // system's time zone database, without which the text is the UTC time. The server's time
    // zone file and the system's differ for a few regions' history (e.g. Asia/Choibalsan in 2000).
    size_t regions, local, different;
    foreach (row; conn.query("SELECT tzname, FROM_TZ(TIMESTAMP '2000-01-01 00:00:00', tzname),"
            ~ " TO_CHAR(SYS_EXTRACT_UTC(FROM_TZ(TIMESTAMP '2000-01-01 00:00:00', tzname)), 'YYYY-MM-DD HH24:MI:SS')"
            ~ " FROM (SELECT DISTINCT tzname FROM v$timezone_names)"))
    {
        const text = row.getString(1);
        if (text == "2000-01-01 00:00:00.000000000 " ~ row.getString(0))
            local++;
        else if (text.endsWith(" " ~ row.getString(0)))
            different++;
        else
            enforce(text == row.getString(2) ~ ".000000000 UTC", "region " ~ row.getString(0) ~ ": " ~ text);
        regions++;
    }
    enforce(regions > 500, "regions: " ~ regions.to!string);
    enforce(different <= regions / 50, "regions whose rules differ: " ~ different.to!string);
    version (Posix)
        enforce(local > 400, "regions with a local time: " ~ local.to!string);

    // WITH LOCAL TIME ZONE: shown in the session time zone
    foreach (zone; ["%2B02:00", "Europe/Lisbon"])
    {
        auto c = connectToServer("time_zone=" ~ zone);
        scope (exit)
            c.close();
        auto r = c.query("SELECT CAST(TIMESTAMP '2026-07-03 10:20:30.5 UTC' AS TIMESTAMP(3) WITH LOCAL TIME ZONE),"
                ~ " TO_CHAR(CAST(TIMESTAMP '2026-07-03 10:20:30.5 UTC' AS TIMESTAMP(3) WITH LOCAL TIME ZONE),"
                ~ " 'YYYY-MM-DD HH24:MI:SS.FF') FROM dual");
        const row = r.front;
        enforce(row.getString(0) == row.getString(1), "local time zone text: " ~ row.getString(
                0) ~ " vs "
                ~ row.getString(1));
        enforce(row.getDateTime(0) == DateTime(2026, 7, 3, zone == "Europe/Lisbon" ? 11 : 12, 20, 30), "local time");
        enforce(row.getSysTime(0) == SysTime(DateTime(2026, 7, 3, 10, 20, 30), hnsecs(5_000_000), UTC()),
                "local time zone instant");
        r.close();
    }
}

/// INTERVAL YEAR TO MONTH and DAY TO SECOND.
void testIntervals()
{
    auto conn = connectToServer();
    scope (exit)
        conn.close();
    static immutable string[] values = [
        "INTERVAL '2-3' YEAR TO MONTH", "INTERVAL '-2-3' YEAR(4) TO MONTH",
        "INTERVAL '0-0' YEAR TO MONTH",
        "INTERVAL '999999999-11' YEAR(9) TO MONTH", "INTERVAL '3 04:05:06.789' DAY TO SECOND",
        "INTERVAL '-3 04:05:06.789' DAY(3) TO SECOND(9)", "INTERVAL '0 0:0:1' DAY TO SECOND(0)",
        "INTERVAL '-0 0:0:0.25' DAY TO SECOND", "INTERVAL '99 23:59:59.999999' DAY TO SECOND",
    ];
    foreach (v; values)
    {
        auto r = conn.query("SELECT " ~ v ~ ", TO_CHAR(" ~ v ~ ") FROM dual");
        const row = r.front;
        enforce(row.getString(0) == row.getString(1), v ~ ": " ~ row.getString(0) ~ " vs " ~ row.getString(1));
        r.close();
    }
    auto r = conn.query("SELECT INTERVAL '-2-3' YEAR TO MONTH, INTERVAL '3 04:05:06.789' DAY TO SECOND,"
            ~ " INTERVAL '-0 0:0:0.25' DAY TO SECOND FROM dual");
    const row = r.front;
    enforce(row.getMonthInterval(0) == MonthInterval(-27) && row.getMonthInterval(0).toString == "-2-3", "months");
    enforce(row.getDuration(1) == days(3) + hours(4) + minutes(5) + seconds(6) + hnsecs(7_890_000), "duration");
    enforce(row.getDuration(2) == -hnsecs(2_500_000) && row.getNanoseconds(2) == -250_000_000, "negative fraction");
    enforce(variantValue!MonthInterval(row.getVariant(0)) == MonthInterval(-27), "Variant");
    r.close();
    r = conn.query("SELECT INTERVAL '999999999-11' YEAR(9) TO MONTH FROM dual");
    enforce(collectException!ClientException(r.front.getMonthInterval(0)) !is null, "beyond MonthInterval");
    r.close();
}

/// RAW, LONG, LONG RAW, ROWID and UROWID.
void testBinaryLongAndRowids()
{
    import std.array : replicate;

    auto conn = connectToServer();
    scope (exit)
        conn.close();
    dropTable(conn, "itest_long");
    dropTable(conn, "itest_lraw");
    dropTable(conn, "itest_iot");
    conn.exec("CREATE TABLE itest_long (id NUMBER, l LONG, r RAW(16))");
    conn.exec("CREATE TABLE itest_lraw (id NUMBER, lr LONG RAW)");
    conn.exec("CREATE TABLE itest_iot (id NUMBER PRIMARY KEY, v VARCHAR2(10)) ORGANIZATION INDEX");
    // 20 000 characters (over 4000 bytes: through PL/SQL), several packets
    conn.exec("DECLARE v LONG := 'Ω' || RPAD('x', 20000, 'abcdefg'); BEGIN"
            ~ " INSERT INTO itest_long VALUES (1, v, HEXTORAW('00FF10')); END;");
    const long_ = "Ωx" ~ "abcdefg".replicate(3000)[0 .. 19_999];
    conn.exec("INSERT INTO itest_long VALUES (2, NULL, NULL)");
    conn.exec("INSERT INTO itest_lraw VALUES (1, HEXTORAW('DEADBEEF'))");
    conn.exec("INSERT INTO itest_iot SELECT LEVEL, 'v' || LEVEL FROM dual CONNECT BY LEVEL <= 3");
    conn.commit();
    foreach (row; conn.query("SELECT l, r, RAWTOHEX(r), id FROM itest_long ORDER BY id"))
    {
        if (row.getLong(3) == 1)
        {
            enforce(row.getString(0) == long_ && row.columns[0].type == OracleType.long_, "LONG");
            enforce(row.getBytes(1) == [0x00, 0xFF, 0x10] && row.getString(1) == row.getString(2), "RAW");
            enforce(variantValue!(ubyte[])(row.getVariant(1)) == [0x00, 0xFF, 0x10], "RAW Variant");
        }
        else
            enforce(row.isNull(0) && row.isNull(1), "NULL LONG and RAW");
    }
    foreach (row; conn.query("SELECT lr FROM itest_lraw"))
        enforce(row.getString(0) == "DEADBEEF" && row.columns[0].type == OracleType.longRaw, "LONG RAW");
    size_t rows;
    foreach (row; conn.query("SELECT ROWID, CAST(ROWID AS VARCHAR2(100)), id FROM itest_iot ORDER BY id"))
    {
        enforce(row.columns[0].type == OracleType.urowid, "UROWID type");
        enforce(row.getString(0) == row.getString(1), "UROWID text: " ~ row.getString(0) ~ " vs " ~ row.getString(1));
        rows++;
    }
    enforce(rows == 3, "IOT rows");
    foreach (row; conn.query("SELECT ROWID, ROWIDTOCHAR(ROWID) FROM itest_long"))
        enforce(row.getString(0) == row.getString(1), "ROWID text");
    dropTable(conn, "itest_long");
    dropTable(conn, "itest_lraw");
    dropTable(conn, "itest_iot");
}

/// Booleans: numbers and strings as bool; BOOLEAN columns (23ai), which this client receives as numbers.
void testBooleans()
{
    auto conn = connectToServer();
    scope (exit)
        conn.close();
    auto r = conn.query("SELECT 1, 0, 'Y', 'false', NULL FROM dual");
    const row = r.front;
    enforce(row.getBool(0) && !row.getBool(1) && row.getBool(2) && !row.getBool(3) && !row.getBool(4), "bool getters");
    r.close();
    if (majorVersion(conn) < 23)
        return;
    dropTable(conn, "itest_bool");
    conn.exec("CREATE TABLE itest_bool (id NUMBER, b BOOLEAN)");
    conn.exec("INSERT INTO itest_bool VALUES (1, TRUE)");
    conn.exec("INSERT INTO itest_bool VALUES (2, FALSE)");
    conn.exec("INSERT INTO itest_bool VALUES (3, NULL)");
    bool[] got;
    foreach (b; conn.query("SELECT b FROM itest_bool ORDER BY id"))
        got ~= b.isNull(0) ? false : b.getBool(0);
    enforce(got == [true, false, false], "BOOLEAN column");
    dropTable(conn, "itest_bool");
}

/// NULLs read through every getter give the type's default.
void testNullGetters()
{
    auto conn = connectToServer();
    scope (exit)
        conn.close();
    auto r = conn.query("SELECT CAST(NULL AS NUMBER), CAST(NULL AS DATE), CAST(NULL AS TIMESTAMP WITH TIME ZONE),"
            ~ " CAST(NULL AS INTERVAL DAY TO SECOND), CAST(NULL AS RAW(10)), CAST(NULL AS BINARY_DOUBLE) FROM dual");
    const row = r.front;
    enforce(row.getLong(0) == 0 && row.getDecimal(0) == Decimal.init && row.getString(0) is null, "NUMBER");
    enforce(row.getDateTime(1) == DateTime.init && row.getSysTime(2) == SysTime.init, "dates");
    enforce(row.getDuration(3) == typeof(row.getDuration(3)).zero && row.getBytes(4) is null, "interval and RAW");
    enforce(row.getDouble(5) == 0 && !row.getVariant(5).hasValue, "double and Variant");
    foreach (i; 0 .. 6)
        enforce(row.isNull(i), "isNull");
    r.close();
}

private string replace(string s, string from, string to)
{
    import std.array : replace;

    return s.replace(from, to);
}
