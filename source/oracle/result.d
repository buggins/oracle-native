/++
Query results: an input range of rows, fetched from the server in batches.

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module oracle.result;

import oracle.connection : Connection;
import oracle.exception : ClientException;
import oracle.types.typeinfo : ColumnInfo, OracleType;

/++
The rows of a query. Iterate with `foreach`; the connection stays busy until
all rows are read or `close` is called.
+/
final class QueryResult
{
    private Connection conn;
    package ColumnInfo[] columnInfo;
    package uint cursorId;
    package immutable(ubyte)[][][] batch; // the rows of the last response
    package immutable(ubyte)[][] lastRow; // the last row read, for repeated column values
    private size_t index;
    package bool allFetched; // the server reported the end of the rows
    private bool finished; // the connection is released

    package this(Connection conn) @safe pure nothrow
    {
        this.conn = conn;
    }

    /// The result columns.
    @property const(ColumnInfo)[] columns() const @safe pure nothrow
    {
        return columnInfo;
    }

    /++
    The position of the column called `name` (case-insensitive).

    Throws: `ClientException` if there is no such column.
    +/
    size_t columnIndex(string name) const @safe
    {
        import std.uni : icmp;

        foreach (i, ref c; columnInfo)
            if (icmp(c.name, name) == 0)
                return i;
        throw new ClientException("No column '" ~ name ~ "' in the result");
    }

    /// Whether all rows have been read. Fetches the next batch from the server when needed.
    @property bool empty() @safe
    {
        while (index >= batch.length)
        {
            if (allFetched || finished)
            {
                finish();
                return true;
            }
            batch = null;
            index = 0;
            try
                conn.fetchMore(this);
            catch (Exception e)
            {
                finish(); // a server error ends the rows; other errors closed the connection
                throw e;
            }
        }
        return false;
    }

    /// The current row.
    @property Row front() @safe
    {
        if (empty)
            throw new ClientException("No more rows");
        return Row(batch[index], columnInfo);
    }

    /// Moves to the next row.
    void popFront() @safe
    {
        if (empty)
            throw new ClientException("No more rows");
        index++;
    }

    /++
    Releases the connection. Unread rows are dropped; the server cursor is
    closed with the next call. Calling it again does nothing.
    +/
    void close() @safe
    {
        batch = null;
        finish();
    }

    private void finish() @safe
    {
        if (finished)
            return;
        finished = true;
        conn.release(cursorId);
    }
}

/// One row of a result. Valid until the result moves past the batch it came in.
struct Row
{
    private const(immutable(ubyte)[])[] values;
    private const(ColumnInfo)[] columnInfo;

    /// Number of columns.
    @property size_t length() const @safe pure nothrow
    {
        return values.length;
    }

    /// The result columns.
    @property const(ColumnInfo)[] columns() const @safe pure nothrow
    {
        return columnInfo;
    }

    /// Whether column `i` is NULL (empty strings are NULL in Oracle).
    bool isNull(size_t i) const @safe pure
    {
        return value(i) is null;
    }

    /++
    Column `i` as text: strings as they are, numbers in plain decimal notation
    (`-12.5`, `0.001`), RAW in upper-case hexadecimal, ROWIDs in their
    base-64 form; `null` for NULL.

    Throws: `ClientException` for types without a text form yet.
    +/
    string getString(size_t i) const @safe
    {
        import oracle.types.number : decodeNumber;
        import oracle.types.rowid : rowidText;
        import oracle.protocol.auth : hex;

        const v = value(i);
        if (v is null)
            return null;
        switch (columnInfo[i].type)
        {
        case OracleType.varchar:
        case OracleType.char_:
            return text(v, columnInfo[i]);
        case OracleType.number:
            return decodeNumber(v).toString();
        case OracleType.raw:
            return hex(v);
        case OracleType.rowid:
            return rowidText(v);
        default:
            throw unsupported(i, "string");
        }
    }

    /++
    Column `i` as a `long`.

    Throws: `ClientException` if the value is NULL, not an integer or out of range.
    +/
    long getLong(size_t i) const @safe
    {
        import std.conv : ConvException, to;
        import std.string : strip;
        import oracle.types.number : numberToLong;

        const v = notNull(i);
        switch (columnInfo[i].type)
        {
        case OracleType.number:
            return numberToLong(v);
        case OracleType.varchar:
        case OracleType.char_:
            const s = text(v, columnInfo[i]).strip;
            try
                return s.to!long;
            catch (ConvException)
                throw new ClientException("'" ~ s ~ "' is not an integer (column " ~ columnInfo[i].name ~ ")");
        default:
            throw unsupported(i, "long");
        }
    }

    /++
    Column `i` as a `double`.

    Throws: `ClientException` if the value is NULL or not a number.
    +/
    double getDouble(size_t i) const @safe
    {
        import std.conv : ConvException, to;
        import std.string : strip;
        import oracle.types.number : numberToDouble;

        const v = notNull(i);
        switch (columnInfo[i].type)
        {
        case OracleType.number:
            return numberToDouble(v);
        case OracleType.varchar:
        case OracleType.char_:
            const s = text(v, columnInfo[i]).strip;
            try
                return s.to!double;
            catch (ConvException)
                throw new ClientException("'" ~ s ~ "' is not a number (column " ~ columnInfo[i].name ~ ")");
        default:
            throw unsupported(i, "double");
        }
    }

    /++
    Column `i`'s value in its wire form (e.g. the NUMBER bytes, UTF-8 text);
    `null` for NULL.
    +/
    immutable(ubyte)[] getBytes(size_t i) const @safe pure
    {
        return value(i);
    }

    private immutable(ubyte)[] value(size_t i) const @safe pure
    {
        if (i >= values.length)
            throw new ClientException("Column index " ~ toText(i) ~ " out of range");
        return values[i];
    }

    private immutable(ubyte)[] notNull(size_t i) const @safe pure
    {
        const v = value(i);
        if (v is null)
            throw new ClientException("Column " ~ columnInfo[i].name ~ " is NULL");
        return v;
    }

    private ClientException unsupported(size_t i, string what) const @safe pure
    {
        return new ClientException(
                "Column " ~ columnInfo[i].name ~ " (" ~ columnInfo[i].typeText()
                ~ ") can't be read as a " ~ what);
    }
}

/++
The text of a character value: UTF-8 (the client's character set) or, for
national character data in AL16UTF16, UTF-16 big-endian.
+/
private string text(immutable(ubyte)[] v, const ref ColumnInfo c) @safe pure
{
    import std.utf : UTFException, validate;
    import dbwire.charset.utf16 : decodeUtf16be;
    import oracle.protocol.negotiate : CharsetId;

    if (c.charsetId == CharsetId.al16utf16)
    {
        if (v.length % 2)
            throw new ClientException("Invalid UTF-16 text in column " ~ c.name);
        return decodeUtf16be(v);
    }
    const s = cast(string) v;
    try
        validate(s);
    catch (UTFException)
        throw new ClientException("Invalid UTF-8 text in column " ~ c.name);
    return s;
}

private string toText(T)(T v) @safe pure
{
    import std.conv : to;

    return v.to!string;
}

///
@safe unittest
{
    ColumnInfo n, s;
    n.name = "N";
    n.type = OracleType.number;
    s.name = "S";
    s.type = OracleType.varchar;
    immutable ubyte[] number = [0xC1, 0x2B];
    immutable(ubyte)[][] values = [number, cast(immutable(ubyte)[]) "abc", null];
    const row = Row(values, [n, s, s]);
    assert(row.getLong(0) == 42 && row.getString(0) == "42" && row.getDouble(0) == 42);
    assert(row.getString(1) == "abc" && row.isNull(2) && row.getString(2) is null);
}
