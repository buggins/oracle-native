/// LOBs: contents as values, locators, temporary LOBs, long binds, BFILE.
module integrationtests.lobs;

import std.array : replicate;
import std.exception : collectException, enforce;
import std.variant : Variant;

import oracle;
import integrationtests.server;

/// Text of `n` characters with 1-, 2-, 3- and 4-byte UTF-8 characters.
private string mixedText(size_t n)
{
    import std.conv : to;
    import std.range : cycle, take;
    import std.utf : byDchar;

    return "aΩ語😀".byDchar.cycle.take(n).to!string;
}

/// CLOB, NCLOB and BLOB contents as values: small, empty, NULL, large, several fetches, re-executed.
void testLobValues()
{
    auto conn = connectToServer("fetch_size=2");
    scope (exit)
        conn.close();
    dropTable(conn, "itest_lob");
    conn.exec("CREATE TABLE itest_lob (id NUMBER, c CLOB, n NCLOB, b BLOB)");
    const big = mixedText(300_000); // about 750 KB of UTF-8, more than 2 MB as UTF-16
    auto bytes = new ubyte[1_500_000];
    foreach (i, ref x; bytes)
        x = cast(ubyte)(i * 7);
    conn.exec("INSERT INTO itest_lob VALUES (1, 'small', N'Ωmega', HEXTORAW('0102'))");
    conn.exec("INSERT INTO itest_lob VALUES (2, EMPTY_CLOB(), EMPTY_CLOB(), EMPTY_BLOB())");
    conn.exec("INSERT INTO itest_lob VALUES (3, NULL, NULL, NULL)");
    // separate placeholders: 21c refuses the same long value bound twice (ORA-22284)
    conn.exec("INSERT INTO itest_lob VALUES (4, :1, :2, :3)", big, big, bytes);
    conn.exec("INSERT INTO itest_lob VALUES (5, 'five', N'five', HEXTORAW('05'))");
    foreach (pass; 0 .. 2) // the second time the statement is re-executed from the cache
    {
        size_t rows;
        foreach (row; conn.query("SELECT id, c, n, b, LENGTH(c) FROM itest_lob ORDER BY id"))
        {
            rows++;
            enforce(row.columns[1].type == OracleType.clob && row.columns[3].type == OracleType.blob, "types");
            switch (row.getLong(0))
            {
            case 1:
                enforce(row.getString(1) == "small" && row.getString(2) == "Ωmega", "small text");
                enforce(row.getBytes(3) == [1, 2], "small bytes");
                break;
            case 2:
                enforce(row.getString(1).length == 0 && row.getBytes(3).length == 0, "empty LOBs");
                break;
            case 3:
                enforce(row.isNull(1) && row.isNull(2) && row.isNull(3), "NULL LOBs");
                break;
            case 4:
                enforce(row.getString(1) == big && row.getString(2) == big, "large text");
                enforce(row.getBytes(3) == bytes, "large bytes");
                enforce(row.getLong(4) == 375_000, "length in UTF-16 units"); // a quarter are outside the BMP
                break;
            default:
                enforce(row.getString(1) == "five" && row.getBytes(3) == [5], "after the large row");
            }
        }
        enforce(rows == 5, "rows");
    }
    auto r = conn.query("SELECT c, b FROM itest_lob WHERE id = 1");
    enforce((() @trusted => r.front.getVariant(0).get!string)() == "small", "CLOB Variant");
    enforce((() @trusted => r.front.getVariant(1).get!(ubyte[]))() == [1, 2], "BLOB Variant");
    enforce(collectException!ClientException(r.front.getLob(0)) !is null, "no locators by default");
    r.close();
    conn.rollback();
    dropTable(conn, "itest_lob");
}

/// Locators (`lob_locators`): length, reads at offsets, writes and trims, reads while iterating.
void testLobLocators()
{
    auto conn = connectToServer("lob_locators=true&fetch_size=2");
    scope (exit)
        conn.close();
    dropTable(conn, "itest_loc");
    conn.exec("CREATE TABLE itest_loc (id NUMBER, c CLOB, n NCLOB, b BLOB)");
    const text = mixedText(100_000);
    conn.exec("INSERT INTO itest_loc VALUES (1, :1, :2, :3)", text, text, new ubyte[70_000]);
    conn.exec("INSERT INTO itest_loc VALUES (2, 'two', N'two', HEXTORAW('02'))");
    conn.exec("INSERT INTO itest_loc VALUES (3, NULL, NULL, NULL)");
    conn.commit();
    size_t rows;
    foreach (row; conn.query("SELECT id, c, n, b FROM itest_loc ORDER BY id"))
    {
        rows++;
        if (row.getLong(0) == 3)
        {
            enforce(row.getLob(1) is null && row.isNull(3), "NULL locators");
            continue;
        }
        auto c = row.getLob(1);
        auto n = row.getLob(2);
        auto b = row.getLob(3);
        enforce(c.type == OracleType.clob && !c.isNational && n.isNational && b.type == OracleType.blob, "kinds");
        if (row.getLong(0) == 1)
        {
            // 100 000 characters, a quarter of them outside the BMP (two UTF-16 units each)
            enforce(c.length == 125_000 && row[1].getLobSize == 125_000, "CLOB length in UTF-16 units");
            enforce(c.readText() == text && n.readText() == text, "whole text");
            enforce(c.readText(1, 6) == "aΩ語😀a", "text from the start");
            enforce(b.length == 70_000 && b.read(69_999).length == 2, "BLOB length and tail");
            enforce(row.getString(1) == text && row.getBytes(3).length == 70_000,
                    "getString, getBytes through the locator");
        }
        else
            enforce(c.readText() == "two" && b.read() == [2], "small LOBs");
    }
    enforce(rows == 3, "rows");

    // write and trim a selected LOB (FOR UPDATE, in a transaction)
    auto r = conn.query("SELECT c, b FROM itest_loc WHERE id = 2 FOR UPDATE");
    auto c = r.front.getLob(0);
    auto b = r.front.getLob(1);
    r.close();
    c.writeText("TWO, written", 1);
    c.trim(3);
    b.write(cast(const(ubyte)[])[9, 8, 7], 2);
    enforce(c.readText() == "TWO" && b.read() == [2, 9, 8, 7], "written and trimmed");
    conn.commit();
    enforce(scalar(conn, "SELECT TO_CHAR(c) FROM itest_loc WHERE id = 2") == "TWO", "committed");
    dropTable(conn, "itest_loc");
}

/// Temporary LOBs: written in pieces, bound, read back, freed.
void testTemporaryLobs()
{
    auto conn = connectToServer();
    scope (exit)
        conn.close();
    dropTable(conn, "itest_tmp");
    conn.exec("CREATE TABLE itest_tmp (id NUMBER, c CLOB, n NCLOB, b BLOB)");
    auto c = conn.createLob(OracleType.clob);
    auto n = conn.createLob(OracleType.clob, true);
    auto b = conn.createLob(OracleType.blob);
    enforce(c.isTemporary && n.isNational && b.type == OracleType.blob, "temporary LOBs");
    const piece = mixedText(10_000);
    ulong at = 1;
    foreach (i; 0 .. 20)
    {
        c.writeText(piece, at);
        at += 12_500; // UTF-16 units of the piece
    }
    n.writeText("national Ωmega");
    foreach (i; 0 .. 20)
        b.write(new ubyte[50_000], i * 50_000 + 1);
    enforce(c.length == 250_000 && b.length == 1_000_000, "written in pieces");
    conn.exec("INSERT INTO itest_tmp VALUES (1, :1, :2, :3)", c, n, b);
    c.free();
    n.free();
    b.free();
    c.free(); // again: nothing
    enforce(collectException!ClientException(c.length) !is null, "freed");
    foreach (row; conn.query("SELECT c, n, DBMS_LOB.GETLENGTH(b) FROM itest_tmp"))
    {
        enforce(row.getString(0) == piece.replicate(20), "bound CLOB");
        enforce(row.getString(1) == "national Ωmega" && row.getLong(2) == 1_000_000, "bound NCLOB and BLOB");
    }
    conn.rollback();
    dropTable(conn, "itest_tmp");
}

/// Strings and bytes over 32767 bytes bound to CLOB, BLOB, LONG and LONG RAW columns.
void testLongBinds()
{
    auto conn = connectToServer();
    scope (exit)
        conn.close();
    dropTable(conn, "itest_lbind");
    dropTable(conn, "itest_long2");
    dropTable(conn, "itest_lraw2");
    conn.exec("CREATE TABLE itest_lbind (id NUMBER, c CLOB, b BLOB, s VARCHAR2(10))");
    conn.exec("CREATE TABLE itest_long2 (id NUMBER, l LONG)");
    conn.exec("CREATE TABLE itest_lraw2 (id NUMBER, l LONG RAW)");
    const text = mixedText(50_000);
    auto bytes = new ubyte[200_000];
    bytes[$ - 1] = 42;
    // a long value between short ones
    conn.exec("INSERT INTO itest_lbind VALUES (:1, :2, :3, :4)", 1, text, bytes, "short");
    conn.exec("INSERT INTO itest_long2 VALUES (1, :1)", text);
    conn.exec("INSERT INTO itest_lraw2 VALUES (1, :1)", bytes);
    foreach (row; conn.query("SELECT c, b, s FROM itest_lbind"))
        enforce(row.getString(0) == text && row.getBytes(1) == bytes && row.getString(2) == "short", "CLOB, BLOB");
    enforce(scalar(conn, "SELECT l FROM itest_long2") == text, "LONG");
    foreach (row; conn.query("SELECT l FROM itest_lraw2"))
        enforce(row.getBytes(0) == bytes, "LONG RAW");
    // the same statement again (the cache) with longer values
    conn.exec("INSERT INTO itest_lbind VALUES (:1, :2, :3, :4)", 2, text ~ text, bytes ~ bytes, "s");
    // 100 000 characters, a quarter of them two UTF-16 units
    enforce(scalar(conn, "SELECT DBMS_LOB.GETLENGTH(c) FROM itest_lbind WHERE id = 2") == "125000", "longer again");
    conn.rollback();
    dropTable(conn, "itest_lbind");
    dropTable(conn, "itest_long2");
    dropTable(conn, "itest_lraw2");
}

/++
BFILE: read through its locator (opened and closed around the read). Needs
the directory object `ITEST_DIR` with `hello.txt` ("hello from a bfile\n")
readable by the test user; skipped without it.
+/
void testBfile()
{
    import std.stdio : writeln;

    auto conn = connectToServer();
    scope (exit)
        conn.close();
    if (scalar(conn, "SELECT COUNT(*) FROM all_directories WHERE directory_name = 'ITEST_DIR'") != "1")
    {
        writeln("  (no directory ITEST_DIR: BFILE not tested)");
        return;
    }
    dropTable(conn, "itest_bfile");
    conn.exec("CREATE TABLE itest_bfile (id NUMBER, f BFILE)");
    conn.exec("INSERT INTO itest_bfile VALUES (1, BFILENAME('ITEST_DIR', 'hello.txt'))");
    conn.exec("INSERT INTO itest_bfile VALUES (2, NULL)");
    auto r = conn.query("SELECT f FROM itest_bfile ORDER BY id");
    auto f = r.front.getLob(0);
    enforce(f.type == OracleType.bfile, "BFILE locator");
    enforce(f.length == 19 && cast(string) f.read() == "hello from a bfile\n", "BFILE contents");
    enforce(cast(string) f.read(7, 4) == "from", "BFILE part");
    enforce(cast(string) r.front.getBytes(0) == "hello from a bfile\n", "getBytes");
    r.popFront();
    enforce(r.front.isNull(0) && r.front.getLob(0) is null, "NULL BFILE");
    r.close();
    conn.rollback();
    dropTable(conn, "itest_bfile");
}
