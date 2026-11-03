/++
Query results: an input range of rows, fetched from the server in batches.

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module oracle.result;

import core.time : Duration;
import std.datetime.date : Date, DateTime, TimeOfDay;
import std.datetime.systime : SysTime;
import std.datetime.timezone : TimeZone;
import std.typecons : Rebindable;
import std.variant : Variant;
import dbwire.types.decimal : Decimal;
import dbwire.types.interval : MonthInterval;
import oracle.connection : Connection;
import oracle.exception : ClientException;
import oracle.types.typeinfo : ColumnInfo, OracleType;
import oracle.value : Value;

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
        return Row(batch[index], columnInfo, conn.sessionZone, conn.databaseZone);
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

/++
One row of a result. Valid until the result moves past the batch it came in.
The getters are those of `Value` (`row.getLong(i)` is `row[i].getLong()`).
+/
struct Row
{
    private const(immutable(ubyte)[])[] values;
    private const(ColumnInfo)[] columnInfo;
    private Rebindable!(immutable TimeZone) sessionZone;
    private Rebindable!(immutable TimeZone) databaseZone;

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

    /++
    Column `i`.

    Throws: `ClientException` if `i` is out of range.
    +/
    Value opIndex(size_t i) const @safe pure
    {
        if (i >= values.length)
            throw new ClientException("Column index " ~ toText(i) ~ " out of range");
        return Value(columnInfo[i], values[i], sessionZone, databaseZone);
    }

    /// Whether column `i` is NULL (empty strings are NULL in Oracle).
    bool isNull(size_t i) const @safe pure
    {
        return this[i].isNull;
    }

    /// The getters of `Value` for column `i`.
    string getString(size_t i) const @safe
    {
        return this[i].getString();
    }

    /// ditto
    long getLong(size_t i) const @safe
    {
        return this[i].getLong();
    }

    /// ditto
    int getInt(size_t i) const @safe
    {
        return this[i].getInt();
    }

    /// ditto
    bool getBool(size_t i) const @safe
    {
        return this[i].getBool();
    }

    /// ditto
    double getDouble(size_t i) const @safe
    {
        return this[i].getDouble();
    }

    /// ditto
    Decimal getDecimal(size_t i) const @safe
    {
        return this[i].getDecimal();
    }

    /// ditto
    immutable(ubyte)[] getBytes(size_t i) const @safe
    {
        return this[i].getBytes();
    }

    /// ditto
    DateTime getDateTime(size_t i) const @safe
    {
        return this[i].getDateTime();
    }

    /// ditto
    Date getDate(size_t i) const @safe
    {
        return this[i].getDate();
    }

    /// ditto
    TimeOfDay getTime(size_t i) const @safe
    {
        return this[i].getTime();
    }

    /// ditto
    SysTime getSysTime(size_t i) const @safe
    {
        return this[i].getSysTime();
    }

    /// ditto
    int getNanoseconds(size_t i) const @safe
    {
        return this[i].getNanoseconds();
    }

    /// ditto
    Duration getDuration(size_t i) const @safe
    {
        return this[i].getDuration();
    }

    /// ditto
    MonthInterval getMonthInterval(size_t i) const @safe
    {
        return this[i].getMonthInterval();
    }

    /// ditto
    Variant getVariant(size_t i) const @safe
    {
        return this[i].getVariant();
    }
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
