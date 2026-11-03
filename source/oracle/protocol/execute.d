/++
Statement execution: the EXECUTE call ("OALL8") and FETCH, their responses
(describe information, row headers, duplicate-column bit vectors, row data,
return parameters), and closing cursors.

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module oracle.protocol.execute;

import oracle.exception : ClientException, ProtocolException;
import oracle.protocol.messages : FunctionCode, functionHeader;
import oracle.protocol.negotiate : MessageType, TtcFieldVersion;
import oracle.protocol.ttc : TtcReader, TtcWriter;
import oracle.types.typeinfo : CharsetForm, ColumnInfo, OracleType;

/// EXECUTE options.
enum ExecuteOption : uint
{
    parse = 0x01, /// parse the SQL text
    bind = 0x08, /// bind values follow
    define = 0x10, /// column defines follow
    execute = 0x20, /// execute
    fetch = 0x40, /// fetch the first rows
    commit = 0x100, /// commit after a successful execution
    plsqlBind = 0x400, /// PL/SQL binds
    notPlsql = 0x8000, /// not a PL/SQL block
    describe = 0x20000, /// describe only
    batchErrors = 0x80000, /// collect errors per row of array DML
}

/// What an EXECUTE call asks for.
struct ExecuteRequest
{
    /// The SQL text; sent when `options` has `parse`.
    string sql;
    /// The cursor to use (0: a new one).
    uint cursorId;
    /// `ExecuteOption` bits.
    uint options;
    /// Rows to return with the execution (queries).
    uint prefetchRows;
    /// Executions (1 for DML and PL/SQL, 0 for a query's first execution).
    uint executions;
    /// Whether the statement is a query.
    bool isQuery;
    /// Execute flags.
    uint flags;
}

/// The EXECUTE message.
ubyte[] buildExecute(const ref ExecuteRequest r, ubyte sequence, ubyte fieldVersion) @safe pure
{
    TtcWriter w;
    functionHeader(w, FunctionCode.execute, sequence, fieldVersion);
    const parsing = (r.options & ExecuteOption.parse) != 0;
    w.ub(r.options);
    w.ub(r.cursorId);
    w.u8(parsing ? 1 : 0); // SQL text pointer
    w.ub(parsing ? r.sql.length : 0);
    w.u8(1); // al8i4 pointer
    w.ub(13);
    w.u8(0); // al8o4
    w.u8(0); // al8o4l
    w.ub(0); // prefetch buffer size
    w.ub(r.prefetchRows);
    w.ub(0x7FFF_FFFF); // maximum LONG size
    w.u8(0); // binds
    w.ub(0);
    foreach (_; 0 .. 5)
        w.u8(0); // al8app, al8txn, al8txl, al8kv, al8kvl
    w.u8(0); // defines
    w.ub(0);
    w.ub(0); // registration ID (low 32 bits)
    w.u8(0); // al8objlist
    w.u8(1); // al8objlen pointer
    w.u8(0); // al8blv
    w.ub(0);
    w.u8(0); // al8dnam
    w.ub(0);
    w.ub(0); // registration ID (high 32 bits)
    w.u8(0); // DML row counts
    w.ub(0);
    w.u8(0);
    if (fieldVersion >= TtcFieldVersion.v12_2)
    {
        w.u8(0); // al8sqlsig
        w.ub(0);
        w.u8(0); // SQL ID
        w.ub(0);
        w.u8(0);
        if (fieldVersion >= TtcFieldVersion.v12_2_ext1)
        {
            w.u8(0); // chunk IDs
            w.ub(0);
        }
    }
    if (parsing)
    {
        w.clr(cast(const(ubyte)[]) r.sql);
        w.ub(1); // al8i4[0]: parse
    }
    else
        w.ub(0);
    w.ub(r.executions); // al8i4[1]
    foreach (i; 2 .. 13)
    {
        if (i == 7)
            w.ub(r.isQuery ? 1 : 0);
        else if (i == 9)
            w.ub(r.flags);
        else
            w.ub(0); // [5], [6]: SCN; [10], [11]: fetch orientation and position
    }
    return w.data;
}

/// The FETCH message: `rows` more rows of `cursorId`.
ubyte[] buildFetch(uint cursorId, uint rows, ubyte sequence, ubyte fieldVersion) @safe pure
{
    TtcWriter w;
    functionHeader(w, FunctionCode.fetch, sequence, fieldVersion);
    w.ub(cursorId);
    w.ub(rows);
    return w.data;
}

/// A call without arguments (COMMIT, ROLLBACK, PING, LOGOFF).
ubyte[] buildBareCall(FunctionCode code, ubyte sequence, ubyte fieldVersion) @safe pure
{
    TtcWriter w;
    functionHeader(w, code, sequence, fieldVersion);
    return w.data;
}

/// The close-cursors piggyback, sent before another call.
void putCloseCursors(ref TtcWriter w, scope const uint[] cursorIds, ubyte sequence, ubyte fieldVersion) @safe pure
{
    w.u8(MessageType.piggyback);
    w.u8(FunctionCode.closeCursors);
    w.u8(sequence);
    if (fieldVersion >= TtcFieldVersion.v23_1_ext1)
        w.ub(0); // token number
    w.u8(1); // pointer
    w.ub(cursorIds.length);
    foreach (id; cursorIds)
        w.ub(id);
}

/++
Reads DESCRIBE_INFO (after its type byte): the result columns.

Throws: `ProtocolException` for malformed metadata.
+/
ColumnInfo[] readDescribeInfo(ref TtcReader r, ubyte fieldVersion) @safe
{
    r.clr(); // the cursor's identity
    r.ub4(); // maximum row size
    const count = r.ub4();
    if (count > 1000)
        throw new ProtocolException("Invalid column count " ~ toText(count));
    auto columns = new ColumnInfo[count];
    if (count)
        r.u8();
    foreach (ref c; columns)
    {
        c.type = cast(OracleType) r.u8();
        r.u8(); // flags
        c.precision = cast(byte) r.u8();
        c.scale = cast(byte) r.u8();
        c.bufferSize = r.ub4();
        r.ub4(); // maximum array elements
        r.ub8(); // continuation flags
        r.bytesWithLength(); // object type ID
        r.ub2(); // object type version
        c.charsetId = r.ub2();
        c.charsetForm = cast(CharsetForm) r.u8();
        c.maxSize = r.ub4();
        if (fieldVersion >= TtcFieldVersion.v12_2)
            r.ub4(); // oaccolid
        c.nullable = r.u8() != 0;
        r.u8(); // v7 name length
        c.name = r.textWithLength();
        c.typeSchema = r.textWithLength();
        c.typeName = r.textWithLength();
        r.ub2(); // column position
        r.ub4(); // UDS flags
        if (fieldVersion >= TtcFieldVersion.v23_1)
            throw new ClientException("TTC field version 23.1 describe fields are not supported");
    }
    r.bytesWithLength(); // current date
    r.ub4(); // DCB flags
    r.ub4(); // maximum fetch length
    r.ub4(); // maximum fetch elements
    r.ub4();
    r.clr();
    return columns;
}

/++
Reads a ROW_HEADER (after its type byte). Returns the bit vector it may carry
for the next row (see `readBitVector`), or null.
+/
immutable(ubyte)[] readRowHeader(ref TtcReader r) @safe
{
    r.u8(); // flags
    r.ub2(); // number of requests
    r.ub4(); // iteration
    r.ub4(); // iteration count
    r.ub2(); // buffer length
    const bits = r.ub4();
    immutable(ubyte)[] bitVector;
    if (bits)
    {
        r.u8(); // the length again
        bitVector = r.bytes(bits);
    }
    r.bytesWithLength(); // rxhrid
    return bitVector;
}

/++
Reads a BIT_VECTOR (after its type byte) for `columns` columns: a set bit
means the column's value is in the next row; a clear one, that it repeats the
previous row's value.
+/
immutable(ubyte)[] readBitVector(ref TtcReader r, size_t columns) @safe
{
    r.ub2(); // number of columns sent
    return r.bytes((columns + 7) / 8);
}

/++
Whether column `i` is sent in a row, according to a bit vector (all are without one).

Throws: `ProtocolException` if the bit vector is too short.
+/
bool columnSent(scope const(ubyte)[] bitVector, size_t i) @safe pure
{
    if (bitVector.length == 0)
        return true;
    if (i / 8 >= bitVector.length)
        throw new ProtocolException("The bit vector is shorter than the row");
    return (bitVector[i / 8] & (1 << (i % 8))) != 0;
}

/++
Reads one column value of a row: the value's bytes in the type's wire form,
`null` for NULL.

Throws: `ClientException` for column types this client can't read yet;
`ProtocolException` for malformed values.
+/
immutable(ubyte)[] readColumnValue(ref TtcReader r, const ref ColumnInfo c, size_t maxLength) @safe
{
    // a column with no size (e.g. a NULL literal) is always NULL and sends nothing
    if (c.bufferSize == 0 && c.type != OracleType.long_ && c.type != OracleType.longRaw
            && c.type != OracleType.urowid)
        return null;
    switch (c.type)
    {
    case OracleType.varchar:
    case OracleType.number:
    case OracleType.date:
    case OracleType.raw:
    case OracleType.char_:
    case OracleType.binaryFloat:
    case OracleType.binaryDouble:
    case OracleType.timestamp:
    case OracleType.timestampTz:
    case OracleType.timestampLtz:
    case OracleType.intervalYm:
    case OracleType.intervalDs:
    case OracleType.boolean:
        return r.clr(maxLength);
    case OracleType.rowid:
        // a length byte (0/255: NULL), then block address, partition, a byte, block, slot
        const length = r.u8();
        if (length == 0 || length == 255)
            return null;
        TtcWriter w; // kept as ub4 ub2 ub1 ub4 ub2, big-endian, 13 bytes
        w.u32be(r.ub4());
        w.u16be(r.ub2());
        w.u8(r.u8());
        w.u32be(r.ub4());
        w.u16be(r.ub2());
        return (() @trusted => cast(immutable(ubyte)[]) w.data)();
    default:
        throw new ClientException("Columns of type " ~ c.typeText() ~ " are not supported yet (column "
                ~ c.name ~ ")");
    }
}

/// Reads the return parameters of an EXECUTE (PARAMETER message, after its type byte).
void skipReturnParameters(ref TtcReader r) @safe
{
    const count = r.ub2(); // al8o4
    foreach (_; 0 .. count)
        r.ub4();
    const context = r.ub2(); // transaction context
    if (context)
        r.skip(context);
    const pairs = r.ub2();
    foreach (_; 0 .. pairs)
    {
        if (r.ub2())
            r.clr(); // text value
        if (r.ub2())
            r.clr(); // binary value
        r.ub2(); // keyword
    }
    const registration = r.ub2();
    if (registration)
        r.skip(registration);
}

private string toText(T)(T v) @safe pure
{
    import std.conv : to;

    return v.to!string;
}

///
@safe unittest
{
    ExecuteRequest q;
    q.sql = "select 1 from dual";
    q.options = ExecuteOption.parse | ExecuteOption.execute | ExecuteOption.fetch | ExecuteOption.notPlsql;
    q.prefetchRows = 2;
    q.isQuery = true;
    const m = buildExecute(q, 3, TtcFieldVersion.v19_1_ext1);
    // header, options 0x8061, cursor 0, SQL pointer and length, al8i4 pointer and length 13
    assert(m[0 .. 13] == [3, 94, 3, 2, 0x80, 0x61, 0, 1, 1, 18, 1, 1, 13]);
    // al8i4[0] parse, [1] executions 0, ..., [7] query
    assert(m[$ - 15 .. $] == [1, 1, 0, 0, 0, 0, 0, 0, 1, 1, 0, 0, 0, 0, 0]);
    assert(buildFetch(1, 100, 4, TtcFieldVersion.v19_1_ext1) == [3, 5, 4, 1, 1, 1, 100]);
    TtcWriter w;
    putCloseCursors(w, [1, 300], 5, TtcFieldVersion.v19_1_ext1);
    assert(w.data == [17, 105, 5, 1, 1, 2, 1, 1, 2, 1, 44]);
}

@safe unittest
{
    import dbwire.io.buffer : BufferedReader;
    import dbwire.io.mock : MockTransport;

    // describe info of "select 42, 'abc' from dual" from Oracle 26ai, at field version 13
    const ubyte[] bytes = [
        0x17, 0x94, 0x57, 0xC5, 0x2D, 0x78, 0x58, 0x59, 0xBF, 0x1A, 0x78, 0xFE, 0xFA, 0x71, 0x9C, 0xAC,
        0xCC, 0x78,
        0x7E, 0x0B, 0x03, 0x09, 0x0C, 0x3A, 0x01, 0x05, 0x01, 0x02, 0x59, 0x02, 0x00, 0x00, 0x81, 0x01,
        0x02, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x02, 0x01, 0x02, 0x02, 0x34, 0x32, 0x00, 0x00,
        0x00, 0x00,
        0x60, 0x80, 0x00, 0x00, 0x01, 0x03, 0x00, 0x00, 0x00, 0x00, 0x02, 0x03, 0x69, 0x01, 0x01, 0x03,
        0x02, 0x3F,
        0xFE, 0x01, 0x05, 0x01, 0x05, 0x05, 0x27, 0x41, 0x42, 0x43, 0x27, 0x00, 0x00, 0x01, 0x01, 0x00,
        0x01, 0x07,
        0x07, 0x78, 0x7E, 0x0B, 0x03, 0x09, 0x0D, 0x08, 0x00, 0x02, 0x1F, 0xE8, 0x01, 0x02, 0x01, 0x02,
        0x00,
        // ROW_HEADER, ROW_DATA
        0x06, 0x22, 0x01, 0x02, 0x00, 0x01, 0x02, 0x00, 0x00, 0x00, 0x07, 0x02, 0xC1, 0x2B, 0x03, 0x61,
        0x62, 0x63
    ];
    auto t = new MockTransport;
    t.feed(bytes);
    auto r = TtcReader(new BufferedReader(t));
    const columns = readDescribeInfo(r, TtcFieldVersion.v19_1_ext1);
    assert(columns.length == 2 && columns[0].name == "42" && columns[0].type == OracleType.number);
    assert(columns[0].scale == -127 && columns[0].typeText == "NUMBER");
    assert(columns[1].name == "'ABC'" && columns[1].type == OracleType.char_ && columns[1].charsetId == 873);
    assert(columns[1].typeText == "CHAR(3)" && columns[1].nullable);
    assert(r.u8() == MessageType.rowHeader);
    assert(readRowHeader(r) is null);
    assert(r.u8() == MessageType.rowData);
    assert(readColumnValue(r, columns[0], 100) == [0xC1, 0x2B]);
    assert(readColumnValue(r, columns[1], 100) == "abc");

    // a row header with a bit vector (from Oracle 26ai): columns 0 and 2 of 4 are sent
    const ubyte[] header = [0x02, 0x01, 0x02, 0x00, 0x01, 0x01, 0x00, 0x01, 0x01, 0x01, 0x05, 0x00];
    t.feed(header);
    const bits = readRowHeader(r);
    assert(bits == [0x05] && columnSent(bits, 0) && !columnSent(bits, 1) && columnSent(bits, 2));
}
