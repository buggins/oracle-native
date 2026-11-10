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
import oracle.connection : CachedStatement, Connection;
import oracle.lob : Lob;
import oracle.params : BindDirection, Parameter;
public import oracle.protocol.messages : BatchError;
import oracle.exception : ClientException;
import oracle.types.typeinfo : ColumnInfo, OracleType;
import oracle.types.vector : Vector;
import std.json : JSONValue;
import oracle.value : Value;

/++
The result of a statement: the rows of a query (an input range: iterate with
`foreach`; the connection stays busy until all rows are read or `close` is
called), and for other statements their row count, OUT values and implicit
results.
+/
final class QueryResult
{
    private Connection conn;
    private ulong lease; // the connection's lease (pooled connections), for the LOBs of the rows
    package ColumnInfo[] columnInfo;
    package uint cursorId;
    package immutable(ubyte)[][][] batch; // the rows of the last response
    package immutable(ubyte)[][] lastRow; // the last row read, for repeated column values
    private size_t index;
    package bool allFetched; // the server reported the end of the rows
    private bool finished; // the connection is released
    package bool isQuery, isPlsql;
    package CachedStatement statement; // the cache entry whose cursor this is (keepCursor)
    package bool keepCursor; // the cursor stays open for the statement cache
    package bool child; // an implicit result or REF cursor, not fetching yet
    package bool needsExecuteFetch; // a child's first fetch is an EXECUTE with the fetch option
    package const(Parameter)[] binds; // the binds, in bind order
    package string[] bindNames; // their placeholder names
    package bool[] returning; // which are RETURNING INTO targets
    package immutable(ubyte)[] directions; // from the IO vector: BindDirection per bind
    package immutable(ubyte)[][][] outputData; // OUT values per bind (several rows for RETURNING)
    package QueryResult[] outputCursors; // REF cursors returned by OUT binds
    package bool dmlRowCounts; // row counts per execution were asked for
    package ulong[] rowCounts;
    package QueryResult[] implicit;
    package ulong rowCount_;

    package this(Connection conn) @safe pure nothrow
    {
        this.conn = conn;
        lease = conn.lease;
    }

    /// The result columns (none for statements other than queries).
    @property const(ColumnInfo)[] columns() const @safe pure nothrow
    {
        return columnInfo;
    }

    /// The number of rows the statement changed (DML; 0 for queries).
    @property ulong rowCount() const @safe pure nothrow
    {
        return rowCount_;
    }

    package @property void rowCount(ulong n) @safe pure nothrow
    {
        rowCount_ = n;
    }

    /++
    The values of the statement's OUT and IN OUT parameters and of its
    `RETURNING ... INTO` targets, in placeholder order.
    +/
    @property Output[] outputs() @safe
    {
        Output[] result;
        foreach (i, ref b; binds)
        {
            if (!isOutputBind(i))
                continue;
            Output o;
            o.name = bindNames[i];
            const column = Connection.bindColumn(b, o.name);
            if (i < outputData.length)
                foreach (bytes; outputData[i])
                {
                    auto v = Value(column, bytes, conn.sessionZone, conn.databaseZone);
                    v.connection = conn;
                    v.lease = lease;
                    o.values ~= v;
                }
            if (i < outputCursors.length)
                o.cursor = outputCursors[i];
            result ~= o;
        }
        return result;
    }

    /++
    The value of the OUT parameter or `RETURNING` target `name` (with or
    without its colon; case-insensitive), or at position `index` of `outputs`.

    Throws: `ClientException` if there is no such output.
    +/
    Value output(string name) @safe
    {
        import std.uni : icmp;

        const bare = name.length && name[0] == ':' ? name[1 .. $] : name;
        foreach (o; outputs)
            if (icmp(o.name, bare) == 0)
                return o.value;
        throw new ClientException("No output parameter :" ~ bare);
    }

    /// ditto
    Value output(size_t index) @safe
    {
        auto all = outputs;
        if (index >= all.length)
            throw new ClientException("No output parameter " ~ toText(index));
        return all[index].value;
    }

    /++
    The implicit results of a PL/SQL block (`DBMS_SQL.RETURN_RESULT`), in
    order. Each holds the connection while its rows are read, like a query's
    result; read them one after the other.
    +/
    @property QueryResult[] implicitResults() @safe pure nothrow
    {
        return implicit;
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
        if (child && !finished && !allFetched && batch.length == 0 && index == 0 && needsExecuteFetch)
            conn.beginChild();
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
        return Row(batch[index], columnInfo, conn.sessionZone, conn.databaseZone, conn, lease);
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
    closed with the next call (or kept for the statement cache). Calling it
    again does nothing.
    +/
    void close() @safe
    {
        index = batch.length;
        allFetched = true;
        finish();
    }

    /// Releases the connection while keeping the rows (all of them are here).
    package void release() @safe
    {
        finish();
    }

    /// Whether bind `i` returns a value: OUT, IN OUT, or a RETURNING target.
    private bool isOutputBind(size_t i) const @safe pure nothrow
    {
        if (i < returning.length && returning[i])
            return true;
        if (binds[i].direction != BindDirection.input)
            return true;
        return i < directions.length && (directions[i] & BindDirection.output) != 0;
    }

    /// Whether ROW_DATA messages carry OUT values rather than rows.
    package @property bool hasOutputs() const @safe pure nothrow
    {
        import std.algorithm.searching : canFind;

        return !isQuery && (isPlsql || returning.canFind(true));
    }

    /// Forgets what a failed attempt read (before executing the statement again).
    package void reset() @safe pure nothrow
    {
        batch = null;
        lastRow = null;
        index = 0;
        directions = null;
        outputData = null;
        outputCursors = null;
        implicit = null;
        rowCounts = null;
    }

    private void finish() @safe
    {
        if (finished)
            return;
        finished = true;
        if (child && needsExecuteFetch)
        {
            conn.closeChild(cursorId); // never fetched: just close its cursor
            return;
        }
        conn.release(this);
    }
}

/// An OUT parameter or `RETURNING ... INTO` target and its value(s).
struct Output
{
    /// The placeholder's name (upper case unless quoted; `1` for `:1`).
    string name;
    /// The values: one for an OUT parameter, one per changed row for `RETURNING ... INTO`.
    Value[] values;
    /// A REF cursor returned by the parameter (`SYS_REFCURSOR` OUT parameters), or null.
    QueryResult cursor;

    /// The first value (a NULL `Value` if there is none).
    @property Value value() @safe
    {
        return values.length ? values[0] : Value.init;
    }
}

/// The outcome of array DML (`Connection.execMany`).
struct BatchResult
{
    /// The row count of each execution (each row of the batch), when the server reports them.
    ulong[] rowCounts;
    /// The total number of rows changed.
    ulong rowCount;
    /// The rows that failed, with batch errors.
    BatchError[] errors;
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
    private Connection connection;
    private ulong lease;

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
        auto v = Value(columnInfo[i], values[i], sessionZone, databaseZone);
        v.connection = (() @trusted => cast(Connection) connection)(); // a reference kept for LOB reads
        v.lease = lease;
        return v;
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

    /// ditto
    Lob getLob(size_t i) const @safe
    {
        return this[i].getLob();
    }

    /// ditto
    JSONValue getJson(size_t i) const @safe
    {
        return this[i].getJson();
    }

    /// ditto
    Vector getVector(size_t i) const @safe
    {
        return this[i].getVector();
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
