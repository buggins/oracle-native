/// Queries and statements: values, transactions, errors, fetching, cursors.
module integrationtests.basic;

import std.exception : collectException, enforce;

import oracle;
import integrationtests.server;

/// NUMBER values as text, long and double, including the extremes.
void testNumbers()
{
    import std.math : isClose;

    auto conn = connectToServer();
    scope (exit)
        conn.close();
    static immutable string[2][] cases = [
        ["0", "0"], ["1", "1"], ["-1", "-1"], ["42", "42"], ["0.5", "0.5"], ["-0.001", "-0.001"],
        ["123.456", "123.456"], ["100", "100"], ["1e10", "10000000000"], [
            "-98765.4321", "-98765.4321"
        ],
        ["12345678901234567890123456789012345678", "12345678901234567890123456789012345678"],
        ["0.000000000000000000000000000000000000012", "0.000000000000000000000000000000000000012"],
        ["9223372036854775807", "9223372036854775807"],
        ["-9223372036854775808", "-9223372036854775808"],
    ];
    foreach (c; cases)
    {
        auto r = conn.query("SELECT " ~ c[0] ~ " FROM dual");
        const row = r.front;
        enforce(row.columns[0].type == OracleType.number, "NUMBER type");
        enforce(row.getString(0) == c[1], c[0] ~ " read as " ~ row.getString(0));
        r.close();
    }
    auto r = conn.query(
            "SELECT 9223372036854775807, -9223372036854775808, 9223372036854775808, 0.1, 2.5,"
            ~ " 1e125, -1e-130 FROM dual");
    const row = r.front;
    enforce(row.getLong(0) == long.max && row.getLong(1) == long.min, "long extremes");
    enforce(collectException!ClientException(row.getLong(2)) !is null, "beyond long");
    enforce(collectException!ClientException(row.getLong(4)) !is null, "not an integer");
    enforce(row.getDouble(3) == 0.1 && row.getDouble(4) == 2.5, "doubles");
    enforce(isClose(row.getDouble(5), 1e125) && isClose(row.getDouble(6), -1e-130), "double extremes");
    r.close();

    dropTable(conn, "itest_numbers");
    conn.exec("CREATE TABLE itest_numbers (a NUMBER(10,2), b NUMBER, c FLOAT(10), d NUMBER(5))");
    conn.exec("INSERT INTO itest_numbers VALUES (12345678.91, 1, 1.5, -99999)");
    r = conn.query("SELECT a, b, c, d FROM itest_numbers");
    const t = r.front;
    enforce(t.columns[0].typeText == "NUMBER(10,2)" && t.columns[1].typeText == "NUMBER", "column types");
    enforce(t.columns[2].typeText == "FLOAT(10)" && t.columns[3].typeText == "NUMBER(5,0)", "column types");
    enforce(t.getString(0) == "12345678.91" && t.getLong(3) == -99_999, "table values");
    r.close();
    dropTable(conn, "itest_numbers");
}

/// VARCHAR2 and CHAR values: UTF-8 text with 2-, 3- and 4-byte characters, CHAR padding.
void testStrings()
{
    auto conn = connectToServer();
    scope (exit)
        conn.close();
    static immutable texts = [
        "plain", "héllo wörld", "Привет, мир", "日本語のテキスト", "emoji 😀👍",
        "quote ' here"
    ];
    foreach (s; texts)
    {
        import std.array : replace;

        enforce(scalar(conn, "SELECT '" ~ s.replace("'", "''") ~ "' FROM dual") == s, "literal " ~ s);
    }
    dropTable(conn, "itest_strings");
    conn.exec("CREATE TABLE itest_strings (id NUMBER, v VARCHAR2(100 CHAR), c CHAR(5), n NVARCHAR2(20))");
    conn.exec("INSERT INTO itest_strings VALUES (1, 'Привет 😀', 'ab', N'Ωμέγα')");
    auto r = conn.query("SELECT v, c, n, LENGTH(v) FROM itest_strings");
    const row = r.front;
    enforce(row.getString(0) == "Привет 😀", "VARCHAR2: " ~ row.getString(0));
    enforce(row.getString(1) == "ab   ", "CHAR padding: '" ~ row.getString(1) ~ "'");
    enforce(row.getString(2) == "Ωμέγα", "NVARCHAR2: " ~ row.getString(2));
    enforce(row.columns[0].typeText == "VARCHAR2(100)" && row.columns[1].typeText == "CHAR(5)", "types");
    enforce(row.getLong(3) == 8, "length in characters");
    r.close();
    dropTable(conn, "itest_strings");
}

/// NULLs of every kind, empty strings (NULL in Oracle) and ROWIDs.
void testNullsAndRowids()
{
    auto conn = connectToServer();
    scope (exit)
        conn.close();
    auto r = conn.query("SELECT NULL, CAST(NULL AS NUMBER), CAST(NULL AS VARCHAR2(10)), '', 1 FROM dual");
    const row = r.front;
    foreach (i; 0 .. 4)
        enforce(row.isNull(i) && row.getString(i) is null, "NULL value");
    enforce(collectException!ClientException(row.getLong(1)) !is null, "NULL as long");
    enforce(row.getLong(4) == 1, "value after NULLs");
    r.close();

    dropTable(conn, "itest_rowids");
    conn.exec("CREATE TABLE itest_rowids (id NUMBER)");
    conn.exec("INSERT INTO itest_rowids VALUES (1)");
    const rowid = scalar(conn, "SELECT ROWID FROM itest_rowids");
    enforce(rowid.length == 18, "ROWID text: " ~ rowid);
    enforce(scalar(conn, "SELECT ROWIDTOCHAR(ROWID) FROM itest_rowids") == rowid, "ROWID matches the server's text");
    enforce(scalar(conn, "SELECT id FROM itest_rowids WHERE ROWID = '" ~ rowid ~ "'") == "1", "ROWID lookup");
    dropTable(conn, "itest_rowids");
}

/// Row counts of DML, transactions ended by commit and rollback, `inTransaction`.
void testTransactions()
{
    auto conn = connectToServer();
    scope (exit)
        conn.close();
    auto other = connectToServer();
    scope (exit)
        other.close();
    dropTable(conn, "itest_tx");
    conn.exec("CREATE TABLE itest_tx (id NUMBER PRIMARY KEY, name VARCHAR2(20))");
    enforce(!conn.inTransaction, "no transaction after DDL");
    enforce(conn.exec("INSERT INTO itest_tx SELECT LEVEL, 'n' || LEVEL FROM dual CONNECT BY LEVEL <= 20") == 20,
            "inserted rows");
    enforce(conn.inTransaction, "in a transaction");
    enforce(scalar(other, "SELECT COUNT(*) FROM itest_tx") == "0", "not visible before the commit");
    conn.commit();
    enforce(!conn.inTransaction, "committed");
    enforce(scalar(other, "SELECT COUNT(*) FROM itest_tx") == "20", "visible after the commit");
    enforce(conn.exec("UPDATE itest_tx SET name = 'x' WHERE id <= 5") == 5, "updated rows");
    enforce(conn.exec("DELETE FROM itest_tx WHERE id > 15") == 5, "deleted rows");
    conn.rollback();
    enforce(scalar(conn, "SELECT COUNT(*) FROM itest_tx WHERE name = 'x'") == "0", "rolled back");
    enforce(scalar(conn, "SELECT COUNT(*) FROM itest_tx") == "20", "rolled back");
    enforce(conn.exec("BEGIN UPDATE itest_tx SET name = 'p' WHERE id = 1; END;") == 1, "PL/SQL block");
    conn.rollback();
    enforce(conn.exec("UPDATE itest_tx SET name = 'y' WHERE id = 0") == 0, "no rows");
    dropTable(conn, "itest_tx");
}

/// With `auto_commit`, every statement is committed at once.
void testAutoCommit()
{
    auto conn = connectToServer("auto_commit=true");
    scope (exit)
        conn.close();
    auto other = connectToServer();
    scope (exit)
        other.close();
    dropTable(conn, "itest_auto");
    conn.exec("CREATE TABLE itest_auto (id NUMBER)");
    conn.exec("INSERT INTO itest_auto VALUES (1)");
    enforce(!conn.inTransaction, "committed");
    enforce(scalar(other, "SELECT COUNT(*) FROM itest_auto") == "1", "visible at once");
    dropTable(conn, "itest_auto");
}

/// Server errors: code, text and position; the connection stays usable.
void testServerErrors()
{
    import std.algorithm.searching : canFind, startsWith;

    auto conn = connectToServer();
    scope (exit)
        conn.close();
    auto e = collectException!ServerException(conn.query("SELECT * FROM itest_no_such_table"));
    enforce(e !is null && e.code == 942 && e.msg.startsWith("ORA-00942"), e is null ? "no error" : e.msg);
    enforce(e.offset == 14, "error position");
    enforce(!conn.isBusy && scalar(conn, "SELECT 'still ok' FROM dual") == "still ok", "usable after the error");
    e = collectException!ServerException(conn.exec("INSERT INTO itest_no_such_table VALUES (1)"));
    enforce(e !is null && e.code == 942, "exec error");
    e = collectException!ServerException(conn.query("SELECT 1/0 FROM dual"));
    enforce(e !is null && e.code == 1476, e is null ? "no error" : e.msg);
    e = collectException!ServerException(conn.exec("BEGIN RAISE_APPLICATION_ERROR(-20001, 'custom failure'); END;"));
    enforce(e !is null && e.code == 20_001 && e.msg.canFind("custom failure"), e is null ? "no error" : e.msg);
    e = collectException!ServerException(conn.exec("SELEC 1"));
    enforce(e !is null && e.code == 900, e is null ? "no error" : e.msg);
    // an error in the middle of the rows: the first fetch succeeds, a later one fails
    e = collectException!ServerException({
        foreach (row; conn.query("SELECT 1 / (LEVEL - 150) FROM dual CONNECT BY LEVEL <= 200"))
        {
        }
    }());
    enforce(e !is null && e.code == 1476, e is null ? "no error in a later fetch" : e.msg);
    enforce(scalar(conn, "SELECT 'still ok' FROM dual") == "still ok", "usable after the fetch error");
}

/// Small and large fetch sizes; repeated column values (duplicate-column bit vectors).
void testFetchBatches()
{
    import std.conv : to;

    foreach (size; ["1", "7", "1000"])
    {
        auto conn = connectToServer("fetch_size=" ~ size);
        scope (exit)
            conn.close();
        long sum;
        size_t rows;
        foreach (row; conn.query("SELECT LEVEL, 'same', MOD(LEVEL, 3), NULL FROM dual CONNECT BY LEVEL <= 250"))
        {
            rows++;
            sum += row.getLong(0);
            enforce(row.getString(1) == "same" && row.getLong(2) == row.getLong(0) % 3 && row.isNull(3),
                    "row " ~ rows.to!string);
        }
        enforce(rows == 250 && sum == 250 * 251 / 2, "all rows with fetch size " ~ size);
    }
}

/// Results closed early, columns by name, and more statements than the open-cursor limit.
void testCursors()
{
    auto conn = connectToServer("fetch_size=10");
    scope (exit)
        conn.close();
    auto r = conn.query("SELECT LEVEL AS n, 'v' || LEVEL AS label FROM dual CONNECT BY LEVEL <= 100");
    enforce(r.columnIndex("LABEL") == 1 && r.columnIndex("n") == 0, "column names");
    enforce(r.front.getString(1) == "v1", "first row");
    r.close();
    enforce(!conn.isBusy, "released by close");
    // the server allows 300 open cursors by default: each statement's cursor must be closed
    foreach (i; 0 .. 400)
    {
        auto q = conn.query("SELECT 1 FROM dual");
        foreach (row; q)
        {
        }
    }
    foreach (i; 0 .. 400)
        conn.exec("BEGIN NULL; END;");
    foreach (i; 0 .. 400)
        conn.query("SELECT LEVEL FROM dual CONNECT BY LEVEL <= 50").close();
    enforce(scalar(conn, "SELECT 'ok' FROM dual") == "ok", "cursors are closed");
}

/// A busy connection refuses other calls; a closed one refuses everything.
void testBusy()
{
    auto conn = connectToServer("fetch_size=5");
    auto r = conn.query("SELECT LEVEL FROM dual CONNECT BY LEVEL <= 20");
    enforce(conn.isBusy, "busy with an open result");
    enforce(collectException!ClientException(conn.query("SELECT 1 FROM dual")) !is null, "query while busy");
    enforce(collectException!ClientException(conn.exec("BEGIN NULL; END;")) !is null, "exec while busy");
    enforce(collectException!ClientException(conn.commit()) !is null, "commit while busy");
    size_t n;
    foreach (row; r)
        n++;
    enforce(n == 20 && !conn.isBusy, "released after the last row");
    conn.close();
    enforce(collectException!ClientException(conn.query("SELECT 1 FROM dual")) !is null, "query when closed");
    enforce(collectException!ClientException(conn.ping()) !is null, "ping when closed");
}
