/// Bind variables, array DML, OUT parameters, RETURNING INTO, implicit results, REF cursors, the statement cache.
module integrationtests.binds;

import core.time : days, hnsecs, hours, minutes, seconds;
import std.datetime.date : Date, DateTime;
import std.datetime.systime : SysTime;
import std.datetime.timezone : SimpleTimeZone, UTC;
import std.exception : collectException, enforce;
import std.typecons : Nullable, tuple;
import std.variant : Variant;

import oracle;
import integrationtests.server;

/// Values of every D type, bound and read back unchanged.
void testBindTypes()
{
    import std.conv : to;

    auto conn = connectToServer();
    scope (exit)
        conn.close();
    const ts = SysTime(DateTime(2026, 11, 3, 10, 20, 30), hnsecs(1_234_567),
            new immutable SimpleTimeZone(minutes(150)));
    auto r = conn.query("SELECT :1, :2, :3, :4, :5, :6, :7, :8, :9, :10, :11, :12, :13, :14, :15, :16 FROM dual",
            42, -9_223_372_036_854_775_807L - 1, ulong.max, 1.5f, -2.25, Decimal.fromString("-12.3450"),
            "héllo Привет 😀", cast(ubyte[])[1, 2, 255], Date(2026, 1, 2), DateTime(-4711, 12, 31, 23, 59, 58), ts,
            days(3) + hours(4) + hnsecs(5), MonthInterval(-27), true, null, Nullable!int());
    const row = r.front;
    enforce(row.getLong(0) == 42 && row.getLong(1) == long.min, "integers");
    enforce(row.getString(2) == "18446744073709551615", "ulong: " ~ row.getString(2));
    enforce(row.getDouble(3) == 1.5 && row.columns[3].type == OracleType.binaryFloat, "float");
    enforce(row.getDouble(4) == -2.25 && row.columns[4].type == OracleType.binaryDouble, "double");
    enforce(row.getDecimal(5) == Decimal.fromString("-12.345"), "decimal: " ~ row.getString(5));
    enforce(row.getString(6) == "héllo Привет 😀", "string");
    enforce(row.getBytes(7) == [1, 2, 255], "bytes");
    enforce(row.getDate(8) == Date(2026, 1, 2) && row.getDateTime(9) == DateTime(-4711, 12, 31, 23, 59, 58), "dates");
    enforce(row.getSysTime(10) == ts && row.getSysTime(10).utcOffset == minutes(150), "SysTime: "
            ~ row.getSysTime(10)
                .toISOExtString);
    enforce(row.getDuration(11) == days(3) + hours(4) + hnsecs(5), "Duration");
    enforce(row.getMonthInterval(12) == MonthInterval(-27), "MonthInterval");
    enforce(row.getBool(13) && row.getLong(13) == 1, "bool");
    enforce(row.isNull(14) && row.isNull(15), "NULLs");
    r.close();

    // the same statement again: the cached cursor is re-executed with new values
    foreach (i; 0 .. 5)
        enforce(conn.query("SELECT :1 * 2, :2 FROM dual", i, "v" ~ i.to!string).front.getLong(0) == i * 2,
                "re-executed");
}

/// `:name`, `?`, repeated placeholders, Parameter[] and Variant arguments, argument errors.
void testPlaceholders()
{
    auto conn = connectToServer();
    scope (exit)
        conn.close();
    auto r = conn.query("SELECT :b - :a, :a FROM dual", Parameter.of(1).named("a"), Parameter.of(10).named(":B"));
    enforce(r.front.getLong(0) == 9 && r.front.getLong(1) == 1, "named");
    r.close();
    r = conn.query("SELECT :x + :y + :x FROM dual", 1, 10); // positional by first appearance
    enforce(r.front.getLong(0) == 12, "repeated placeholder in SQL");
    r.close();
    r = conn.query("SELECT ? || '?' || ? FROM dual", "a", "b");
    enforce(r.front.getString(0) == "a?b", "question marks");
    r.close();
    const(Parameter)[] params = [Parameter.of(3), Parameter.of(4)];
    r = conn.query("SELECT :1 * :2 FROM dual", params);
    enforce(r.front.getLong(0) == 12, "Parameter[]");
    r.close();
    r = conn.query("SELECT :1, :2 FROM dual", Variant(5), Variant("five"));
    enforce(r.front.getLong(0) == 5 && r.front.getString(1) == "five", "Variant");
    r.close();
    enforce(collectException!ClientException(conn.query("SELECT :1, :2 FROM dual", 1)) !is null, "too few");
    enforce(collectException!ClientException(conn.query("SELECT :a FROM dual", Parameter.of(1)
            .named("b"))) !is null,
            "unknown name");
    enforce(scalar(conn, "SELECT 'still ok' FROM dual") == "still ok", "usable");
}

/// DML with binds: row counts, NULLs into typed columns, long strings, the statement cache with changing types.
void testBindDml()
{
    import std.array : replicate;

    auto conn = connectToServer();
    scope (exit)
        conn.close();
    dropTable(conn, "itest_bind");
    conn.exec("CREATE TABLE itest_bind (id NUMBER PRIMARY KEY, n NUMBER(10,2), s VARCHAR2(4000), d DATE,"
            ~ " r RAW(100), t TIMESTAMP WITH TIME ZONE)");
    const ins = "INSERT INTO itest_bind (id, n, s, d, r) VALUES (:1, :2, :3, :4, :5)";
    enforce(conn.exec(ins, 1, Decimal.fromString("12.5"), "one", DateTime(2026, 1, 1), cast(ubyte[])[
        1
    ]) == 1, "insert");
    enforce(conn.exec(ins, 2, null, null, null, null) == 1, "NULLs");
    enforce(conn.exec(ins, 3, 7, "x".replicate(4000), Date(2026, 2, 2), new ubyte[100]) == 1, "long values");
    enforce(conn.exec(ins, 4, Nullable!Decimal(), "four", Nullable!DateTime(), Nullable!(ubyte[])()) == 1,
            "typed NULLs");
    enforce(conn.exec("UPDATE itest_bind SET s = :s WHERE id > :id", Parameter.of("upd")
            .named("s"),
            Parameter.of(2).named("id")) == 2, "update count");
    enforce(conn.exec("DELETE FROM itest_bind WHERE id = :1", 99) == 0, "no rows");
    size_t rows;
    foreach (row; conn.query("SELECT id, n, s, d, r FROM itest_bind WHERE id <= :1 ORDER BY id", 2))
    {
        rows++;
        if (row.getLong(0) == 1)
            enforce(row.getString(1) == "12.5" && row.getString(2) == "one" && row.getBytes(4) == [
            1
        ], "row 1");
        else
            enforce(row.isNull(1) && row.isNull(2) && row.isNull(3) && row.isNull(4), "row 2 NULLs");
    }
    enforce(rows == 2, "rows");
    conn.rollback();
}

/// Array DML: row counts per row, batch errors, rows of tuples and arrays.
void testArrayDml()
{
    auto conn = connectToServer();
    scope (exit)
        conn.close();
    dropTable(conn, "itest_many");
    conn.exec("CREATE TABLE itest_many (id NUMBER PRIMARY KEY, s VARCHAR2(20))");
    auto b = conn.execMany("INSERT INTO itest_many VALUES (:1, :2)", [
        tuple(1, "one"), tuple(2, "two"),
        tuple(3, "three")
    ]);
    enforce(b.rowCounts == [1, 1, 1] && b.rowCount == 3 && b.errors.length == 0, "inserted");
    b = conn.execMany("UPDATE itest_many SET s = :1 WHERE id >= :2", [
        [Variant("x"), Variant(1)],
        [Variant("y"), Variant(3)], [Variant("z"), Variant(10)]
    ]);
    enforce(b.rowCounts == [3, 1, 0], "update counts");
    b = conn.execMany("INSERT INTO itest_many VALUES (:1, :2)", [
        tuple(4, "four"), tuple(1, "dup"),
        tuple(5, cast(string) null)
    ], true);
    enforce(b.errors.length == 1 && b.errors[0].offset == 1 && b.errors[0].code == 1, "batch error");
    enforce(scalar(conn, "SELECT COUNT(*) FROM itest_many") == "5", "the other rows are in");
    auto e = collectException!ServerException(conn.execMany("INSERT INTO itest_many VALUES (:1, :2)",
            [tuple(6, "six"), tuple(1, "dup"), tuple(7, "seven")]));
    enforce(e !is null && e.code == 1, "the first error stops the batch");
    enforce(scalar(conn, "SELECT COUNT(*) FROM itest_many WHERE id IN (6, 7)") == "1", "rows before the error");
    const(Parameter[])[] none;
    enforce(conn.execMany("INSERT INTO itest_many VALUES (:1, :2)", none).rowCounts.length == 0, "no rows");
    conn.rollback();
}

/// PL/SQL OUT and IN OUT parameters, RETURNING INTO with one and several rows.
void testOutputs()
{
    auto conn = connectToServer();
    scope (exit)
        conn.close();
    auto r = conn.query("BEGIN :1 := 'out ' || :2; :3 := :3 * 2; :4 := SYSTIMESTAMP; :5 := NULL; END;",
            Parameter.output!string, "in", Parameter.inOut(21), Parameter.output!SysTime, Parameter.output!long);
    enforce(r.output(0).getString == "out in", "OUT string: " ~ r.output(0).getString);
    enforce(r.output("3").getLong == 42, "IN OUT number");
    enforce(r.outputs.length == 4 && r.outputs[2].value.getSysTime.year >= 2026, "OUT timestamp");
    enforce(r.output(":5").isNull, "OUT NULL");
    enforce(!conn.isBusy, "free");

    dropTable(conn, "itest_ret");
    conn.exec("CREATE TABLE itest_ret (id NUMBER, n NUMBER, s VARCHAR2(20))");
    conn.execMany("INSERT INTO itest_ret VALUES (:1, :2, :3)", [
        tuple(1, 10, "a"), tuple(2, 20, "b"), tuple(3, 30, "c")
    ]);
    r = conn.query("UPDATE itest_ret SET n = n + 1 WHERE id = :id RETURNING n, s INTO :n, :s",
            Parameter.of(2).named("id"), Parameter.output!long.named("n"), Parameter.output!string.named("s"));
    enforce(r.rowCount == 1 && r.output("n").getLong == 21 && r.output("s").getString == "b", "RETURNING one row");
    r = conn.query("UPDATE itest_ret SET n = n * 2 RETURNING id, n INTO :1, :2", Parameter.output!long,
            Parameter.output!long);
    enforce(r.rowCount == 3 && r.outputs[1].values.length == 3, "RETURNING several rows");
    long total;
    foreach (v; r.outputs[1].values)
        total += v.getLong;
    enforce(total == 2 * (10 + 21 + 30), "returned values");
    // again: the cached cursor
    r = conn.query("UPDATE itest_ret SET n = n + 1 WHERE id = :id RETURNING n, s INTO :n, :s",
            Parameter.of(3).named("id"), Parameter.output!long.named("n"), Parameter.output!string.named("s"));
    enforce(r.output("n").getLong == 61 && r.output("s").getString == "c", "RETURNING again");
    conn.rollback();
}

/// Implicit results (DBMS_SQL.RETURN_RESULT) and REF cursors (SYS_REFCURSOR OUT parameters).
void testCursors()
{
    auto conn = connectToServer("fetch_size=2");
    scope (exit)
        conn.close();
    auto r = conn.query("DECLARE c1 SYS_REFCURSOR; c2 SYS_REFCURSOR; BEGIN"
            ~ " OPEN c1 FOR SELECT LEVEL AS n FROM dual CONNECT BY LEVEL <= 5; DBMS_SQL.RETURN_RESULT(c1);"
            ~ " OPEN c2 FOR SELECT 'x' AS s, 2 AS t FROM dual; DBMS_SQL.RETURN_RESULT(c2); END;");
    enforce(r.implicitResults.length == 2, "two implicit results");
    long sum;
    foreach (row; r.implicitResults[0])
        sum += row.getLong(0);
    enforce(sum == 15, "first implicit result");
    auto second = r.implicitResults[1];
    enforce(second.columns.length == 2 && second.columns[0].name == "S", "second's columns");
    enforce(second.front.getString(0) == "x", "second implicit result");
    second.close();
    enforce(!conn.isBusy, "free");

    r = conn.query("BEGIN OPEN :1 FOR SELECT LEVEL * 10 FROM dual CONNECT BY LEVEL <= 3; END;",
            Parameter.refCursor);
    auto cursor = r.outputs[0].cursor;
    enforce(cursor !is null, "REF cursor");
    long[] values;
    foreach (row; cursor)
        values ~= row.getLong(0);
    enforce(values == [10, 20, 30], "REF cursor rows");
    enforce(scalar(conn, "SELECT 'after' FROM dual") == "after", "usable");
}

/// The statement cache: cursors reused, a table changed under a cached query, the cache turned off.
void testStatementCache()
{
    auto conn = connectToServer("statement_cache_size=3");
    scope (exit)
        conn.close();
    dropTable(conn, "itest_cache");
    conn.exec("CREATE TABLE itest_cache (a NUMBER)");
    conn.exec("INSERT INTO itest_cache VALUES (1)");
    enforce(scalar(conn, "SELECT * FROM itest_cache") == "1", "first run");
    conn.exec("ALTER TABLE itest_cache ADD (b VARCHAR2(10) DEFAULT 'b')");
    auto r = conn.query("SELECT * FROM itest_cache");
    enforce(r.columns.length == 2 && r.front.getString(1) == "b", "re-parsed after the table changed");
    r.close();
    // more statements than the cache holds, many times: cursors are closed as they are evicted
    foreach (i; 0 .. 200)
        foreach (k; 0 .. 5)
        {
            import std.conv : to;

            enforce(conn.query("SELECT :1 + " ~ k.to!string ~ " FROM dual", i).front.getLong(0) == i + k, "evicted");
        }
    auto off = connectToServer("statement_cache_size=0");
    scope (exit)
        off.close();
    foreach (i; 0 .. 400)
        enforce(off.exec("UPDATE itest_cache SET a = :1", i) == 1, "without a cache");
    conn.rollback();
    off.rollback();
    dropTable(conn, "itest_cache");
}
