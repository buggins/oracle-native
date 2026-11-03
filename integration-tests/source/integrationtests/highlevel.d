/// The high-level API: the connection pool, struct mapping.
module integrationtests.highlevel;

import core.time : msecs, minutes;
import std.conv : to;
import std.datetime.date : Date, DateTime, TimeOfDay;
import std.datetime.systime : SysTime;
import std.datetime.timezone : SimpleTimeZone;
import std.exception : collectException, enforce;
import std.string : indexOf;
import std.typecons : Nullable;
import std.uuid : UUID;

import oracle;
import integrationtests.server;

/++
DRCP (Database Resident Connection Pooling): single connections and a pool
with `server=pooled`; sessions released and attached again, the same or
another one (cached cursors dropped then), rollback on release. Needs
`ORACLE_DRCP=1` (the database pool started with
`DBMS_CONNECTION_POOL.START_POOL`); skipped otherwise.
+/
void testDrcp()
{
    import std.process : environment;
    import std.stdio : writeln;

    if (environment.get("ORACLE_DRCP", "").length == 0)
    {
        writeln("  (ORACLE_DRCP not set: DRCP not tested)");
        return;
    }
    enum sidQuery = "SELECT SYS_CONTEXT('USERENV', 'SID') FROM dual WHERE 1 = :1";
    void checkSid(Connection c, string how)
    {
        const sid = c.queryValue!string(sidQuery, 1);
        enforce(sid == c.sessionId.to!string, how ~ ": SID " ~ sid ~ ", sessionId " ~ c.sessionId.to!string);
    }

    // a single connection: a fresh session, ended on close (no logoff)
    foreach (_; 0 .. 2)
    {
        auto c = connectToServer("server=pooled");
        enforce(c.queryValue!long("SELECT 42 FROM dual") == 42, "single connection");
        checkSid(c, "single connection");
        c.close();
    }

    // two connections of one class: a released session can go to the other one
    {
        auto a = connectToServer("server=pooled&pool_connection_class=itest&pool_purity=self");
        auto b = connectToServer("server=pooled&pool_connection_class=itest&pool_purity=self");
        scope (exit)
        {
            a.close();
            b.close();
        }
        checkSid(a, "a");
        checkSid(a, "a, cached cursor");
        a.releaseSession();
        enforce(a.isSessionReleased, "released");
        b.releaseSession();
        checkSid(b, "b takes a session"); // possibly a's
        checkSid(a, "a attached again"); // another session: its cached cursors are gone
        enforce(!a.isSessionReleased, "attached");
        checkSid(a, "a, cursor cached again");
        foreach (_; 0 .. 20)
        {
            a.releaseSession();
            checkSid(a, "a, released and attached again");
        }
        // an open transaction is rolled back on release
        dropTable(a, "itest_drcp");
        a.exec("CREATE TABLE itest_drcp (v NUMBER)");
        a.exec("INSERT INTO itest_drcp VALUES (1)");
        a.releaseSession();
        enforce(!a.inTransaction && a.queryValue!long("SELECT COUNT(*) FROM itest_drcp") == 0, "rolled back");
        dropTable(a, "itest_drcp");
        a.releaseSession();
        a.releaseSession(); // released already: nothing
    }

    // a pool: sessions go back to the database's pool when connections are returned
    auto pool = new ConnectionPool(serverDsn("server=pooled&pool_max=2"));
    scope (exit)
        pool.close();
    foreach (i; 0 .. 5)
    {
        auto c = pool.lockConnection();
        enforce(i == 0 || c.isSessionReleased, "returned connections release their session");
        checkSid(c, "pooled connection");
        if (i == 0)
            c.exec("ALTER SESSION SET NLS_DATE_FORMAT = 'YYYY-MM'");
    }
    {
        auto a = pool.lockConnection();
        auto b = pool.lockConnection();
        checkSid(a, "pooled a");
        checkSid(b, "pooled b");
        enforce(a.sessionId != b.sessionId, "two sessions");
    }

    // without DRCP, releasing does nothing
    auto plain = connectToServer();
    scope (exit)
        plain.close();
    plain.releaseSession();
    enforce(!plain.isSessionReleased, "not DRCP");
    checkSid(plain, "dedicated server");
}

/// The pool: reuse, uncommitted changes rolled back, busy connections dropped, limits, closing.
void testPool()
{
    auto pool = new ConnectionPool(serverDsn("pool_max=2"));
    scope (exit)
        pool.close();
    {
        auto c = pool.lockConnection();
        dropTable(c, "itest_pooled");
        c.exec("CREATE TABLE itest_pooled (v NUMBER)");
        c.exec("INSERT INTO itest_pooled VALUES (1)"); // not committed
        enforce(pool.activeConnections == 1 && c.inTransaction, "one active, in a transaction");
    }
    enforce(pool.idleConnections == 1 && pool.activeConnections == 0, "returned");
    {
        auto c = pool.lockConnection();
        enforce(!c.inTransaction && scalar(c, "SELECT COUNT(*) FROM itest_pooled") == "0",
                "the previous user's changes rolled back");
        dropTable(c, "itest_pooled");
    }

    // a connection returned busy (an unread result) is closed, not reused
    {
        auto c = pool.lockConnection();
        c.query("SELECT LEVEL FROM dual CONNECT BY LEVEL <= 1000"); // not read
    }
    enforce(pool.idleConnections == 0, "the busy connection was dropped");

    // two in use: a third waits, then fails
    auto o = PoolOptions(2, 300.msecs);
    auto pool2 = new ConnectionPool(serverOptions(), o);
    scope (exit)
        pool2.close();
    auto a = pool2.lockConnection();
    auto b = pool2.lockConnection();
    enforce(collectException!ClientException(pool2.lockConnection()) !is null, "the third waits and fails");
    b.release();
    auto c = pool2.lockConnection();
    enforce(scalar(c, "SELECT 1 FROM dual") == "1", "a freed connection");
    a.release();
    c.release();
    pool2.close();
    enforce(collectException!ClientException(pool2.lockConnection()) !is null, "a closed pool");
}

private enum Color
{
    red = 1,
    green = 2,
}

private struct Everything
{
    int id;
    bool flag;
    ubyte tiny;
    short small;
    long big;
    float single = 0;
    double precise = 0;
    string text;
    @column("bytes") ubyte[] data;
    Decimal amount;
    Date day;
    DateTime moment;
    SysTime instant;
    Duration span;
    MonthInterval months;
    UUID guid;
    Color color;
    @column("color_name") Color namedColor;
    Nullable!int maybe;
    @ignore string notStored;
}

import core.time : Duration;

/// Structs read from and inserted into a table with every mapped type.
void testStructMapping()
{
    auto conn = connectToServer();
    scope (exit)
        conn.close();
    dropTable(conn, "itest_everything");
    conn.exec("CREATE TABLE itest_everything (id NUMBER(10), flag NUMBER(1), tiny NUMBER(3), small NUMBER(5),"
            ~ " big NUMBER(19), single BINARY_FLOAT, precise BINARY_DOUBLE, text VARCHAR2(100), bytes RAW(100),"
            ~ " amount NUMBER(18,4), day DATE, moment DATE, instant TIMESTAMP(6) WITH TIME ZONE,"
            ~ " span INTERVAL DAY TO SECOND, months INTERVAL YEAR TO MONTH, guid RAW(16), color NUMBER(5),"
            ~ " color_name VARCHAR2(10), maybe NUMBER(10))");
    const tz = new immutable SimpleTimeZone(minutes(120));
    import core.time : days, hours;

    Everything[] rows = [
        Everything(1, true, 255, -32_768, long.max, 1.5f, -0.1, "Grüße", [1, 2], Decimal.fromString("-12.3456"),
                Date(2024, 2, 29), DateTime(2024, 1, 31, 12, 0, 0), SysTime(DateTime(2024, 1, 31, 12, 0, 0), tz),
                days(2) + hours(3), MonthInterval(27), UUID("6f9619ff-8b86-d011-b42d-00c04fc964ff"),
                Color.green, Color.red, Nullable!int(5), "not stored"),
        Everything(2),
    ];
    enforce(conn.insert("itest_everything", rows) == 2, "inserted");
    conn.exec("UPDATE itest_everything SET color_name = 'red' WHERE id = 1"); // the enum's name as text
    auto read = conn.query!Everything("SELECT * FROM itest_everything WHERE id = :1", 1);
    enforce(!read.empty, "a row");
    const r = read.front;
    read.close();
    enforce(r.flag && r.tiny == 255 && r.small == -32_768 && r.big == long.max, "integers");
    enforce(r.single == 1.5f && r.precise == -0.1 && r.text == "Grüße" && r.data == [1, 2], "floats, text, bytes");
    enforce(r.amount == Decimal.fromString("-12.3456") && r.day == Date(2024, 2, 29), "decimal, date");
    enforce(r.moment == DateTime(2024, 1, 31, 12, 0, 0) && r.instant == rows[0].instant, "date and time, instant");
    enforce(r.span == days(2) + hours(3) && r.months == MonthInterval(27), "intervals");
    enforce(r.guid == rows[0].guid, "UUID");
    enforce(r.color == Color.green && r.namedColor == Color.red && r.maybe.get == 5, "enums, Nullable");
    enforce(r.notStored == "", "ignored field");
    const empty = conn.queryRow!Everything("SELECT * FROM itest_everything WHERE id = 2");
    enforce(empty.maybe.isNull && empty.text == "" && empty.data == null, "NULLs");

    enforce(conn.queryValue!long("SELECT COUNT(*) FROM itest_everything") == 2, "queryValue");
    enforce(conn.queryValue!(Nullable!int)("SELECT maybe FROM itest_everything WHERE id = :1", 2)
            .isNull,
            "NULL value");
    enforce(collectException!ClientException(
            conn.queryRow!Everything("SELECT * FROM itest_everything WHERE id = 3")) !is null, "no row");
    auto e = collectException!ClientException(conn.query!Everything("SELECT id FROM itest_everything"));
    enforce(e !is null && e.msg.indexOf("'flag'") >= 0, "a missing column");
    enforce(!conn.isBusy, "released after a missing column");
    enforce(collectException!ClientException(conn.queryValue!ubyte("SELECT 300 FROM dual")) !is null,
            "doesn't fit");
    conn.rollback();
    dropTable(conn, "itest_everything");
}

private struct Item
{
    int id;
    string name;
}

/// Many structs inserted in round trips of 1000 rows; the caller's transaction decides.
void testInsertMany()
{
    import std.algorithm.iteration : map;
    import std.array : array;
    import std.range : iota;

    auto conn = connectToServer();
    scope (exit)
        conn.close();
    dropTable(conn, "itest_items");
    conn.exec("CREATE TABLE itest_items (id NUMBER PRIMARY KEY, name VARCHAR2(20))");
    auto items = iota(0, 2500).map!(i => Item(i, "item " ~ i.to!string)).array;
    enforce(conn.insert("itest_items", items) == 2500, "2500 rows");
    enforce(conn.queryValue!long("SELECT COUNT(*) FROM itest_items") == 2500, "all there");
    conn.commit();

    items = iota(2500, 4000).map!(i => Item(i, "x")).array;
    items[1200].id = 0; // a duplicate key in the second round trip
    enforce(collectException!ServerException(conn.insert("itest_items", items)) !is null, "a duplicate");
    conn.rollback();
    enforce(conn.queryValue!long("SELECT COUNT(*) FROM itest_items") == 2500, "rolled back by the caller");

    auto auto_ = connectToServer("auto_commit=true");
    scope (exit)
        auto_.close();
    auto_.insert("itest_items", Item(5000, "committed"));
    enforce(conn.queryValue!long("SELECT COUNT(*) FROM itest_items") == 2501, "auto-commit");
    dropTable(conn, "itest_items");
}

/++
Pipelines: statements, PL/SQL OUT values, queries (more rows than a fetch, a
CLOB column), commits, and both error modes; pipelined on 23ai, one by one
on older servers, with the same results.
+/
void testPipelines()
{
    auto conn = connectToServer();
    scope (exit)
        conn.close();
    dropTable(conn, "itest_pipe");
    conn.exec("CREATE TABLE itest_pipe (id NUMBER PRIMARY KEY, txt VARCHAR2(20), doc CLOB)");
    scope (exit)
        dropTable(conn, "itest_pipe");
    auto r = conn.pipeline()
        .exec("INSERT INTO itest_pipe VALUES (:1, :2, :3)", 1, "one", "first document")
        .exec("INSERT INTO itest_pipe VALUES (:1, :2, :3)", 2, "two", "second document")
        .exec("UPDATE itest_pipe SET txt = txt || '!'")
        .exec("BEGIN :o := :i * 2; END;", Parameter.output!long, 21)
        .query("SELECT LEVEL FROM dual CONNECT BY LEVEL <= 1000")
        .query("SELECT id, txt, doc FROM itest_pipe ORDER BY id")
        .commit()
        .run();
    enforce(r.length == 7 && r[0].ok && r[0].rowCount == 1 && r[2].rowCount == 2, "row counts");
    enforce(r[3].result.output(0).getLong() == 42, "PL/SQL OUT value");
    long n, sum;
    foreach (row; r[4].result)
    {
        n++;
        sum += row.getLong(0);
    }
    enforce(n == 1000 && sum == 500_500, "all rows of a long query");
    string[] docs;
    foreach (row; r[5].result)
        docs ~= row.getString(1) ~ " " ~ row.getString(2);
    enforce(docs == ["one! first document", "two! second document"], "CLOB query");
    enforce(r[6].result is null && r[6].ok, "commit");
    enforce(!conn.isBusy && !conn.inTransaction, "free and committed");

    // every operation runs; the errors are in the results
    auto c = conn.pipeline()
        .exec("INSERT INTO itest_pipe (id) VALUES (1)")
        .exec("INSERT INTO itest_pipe (id) VALUES (3)")
        .query("SELECT COUNT(*) FROM itest_pipe")
        .run(true);
    enforce(!c[0].ok && c[0].error.code == 1 && c[0].result is null, "the failed operation");
    enforce(c[1].ok && c[1].rowCount == 1 && c[2].result.front.getLong(0) == 3, "the later operations ran");
    conn.rollback();

    // the first error stops the pipeline
    auto e = collectException!ServerException(conn.pipeline()
            .exec("INSERT INTO itest_pipe (id) VALUES (1)")
            .exec("INSERT INTO itest_pipe (id) VALUES (4)")
            .query("SELECT 1 FROM dual")
            .run());
    enforce(e !is null && e.code == 1, "abort on error");
    enforce(!conn.isBusy && conn.queryValue!long("SELECT COUNT(*) FROM itest_pipe") == 2,
            "the later operations didn't run");
    conn.rollback();
    enforce(conn.pipeline().run().length == 0, "an empty pipeline");
}
