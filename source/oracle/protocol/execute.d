/++
Statement execution: the EXECUTE call ("OALL8") and FETCH, their responses
(describe information, row headers, duplicate-column bit vectors, row data,
return parameters), and closing cursors.

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module oracle.protocol.execute;

import std.conv : to;
import dbwire.io.buffer : toBigEndian;
import oracle.exception : ClientException, ProtocolException;
import oracle.protocol.messages : FunctionCode, functionHeader;
import oracle.protocol.negotiate : MessageType, TtcFieldVersion;
import oracle.protocol.ttc : TtcReader, TtcWriter;
import oracle.params : Parameter;
import oracle.types.typeinfo : CharsetForm, ColumnInfo, OracleType;
import std.datetime.date : DateTime;

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
    /// The binds' metadata (`Parameter.data` unused here), in bind order.
    const(Parameter)[] binds;
    /// The bind values, one row per execution; binds whose value isn't sent (RETURNING targets) are skipped.
    const(Parameter[])[] rows;
    /// Which binds have their value sent (all when empty).
    const(bool)[] sendValue;
    /// Ask for the row count of each execution (array DML).
    bool dmlRowCounts;
    /// Column defines (the DEFINE option): the type each column is to be fetched as.
    const(ColumnInfo)[] defines;
}

/// Execute flags (al8i4[9]).
enum ExecuteFlag : uint
{
    dmlRowCounts = 0x4000, /// return each execution's row count
    implicitResultSet = 0x8000, /// PL/SQL may return implicit results
}

/// The EXECUTE message.
ubyte[] buildExecute(const ref ExecuteRequest r, ubyte sequence, ubyte fieldVersion) @safe pure nothrow
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
    if (r.binds.length)
    {
        w.u8(1);
        w.ub(r.binds.length);
    }
    else
    {
        w.u8(0);
        w.ub(0);
    }
    foreach (_; 0 .. 5)
        w.u8(0); // al8app, al8txn, al8txl, al8kv, al8kvl
    if (r.defines.length) // defines
    {
        w.u8(1);
        w.ub(r.defines.length);
    }
    else
    {
        w.u8(0);
        w.ub(0);
    }
    w.ub(0); // registration ID (low 32 bits)
    w.u8(0); // al8objlist
    w.u8(1); // al8objlen pointer
    w.u8(0); // al8blv
    w.ub(0);
    w.u8(0); // al8dnam
    w.ub(0);
    w.ub(0); // registration ID (high 32 bits)
    if (r.dmlRowCounts) // DML row counts
    {
        w.u8(1);
        w.ub(r.executions);
        w.u8(1);
    }
    else
    {
        w.u8(0);
        w.ub(0);
        w.u8(0);
    }
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
    foreach (ref b; r.binds)
        putBindMetadata(w, b, fieldVersion);
    foreach (ref c; r.defines)
        putDefineMetadata(w, c, fieldVersion);
    putBindRows(w, r.rows, r.sendValue);
    return w.data;
}

/// The buffer size of LOB locators in binds and defines.
enum uint lobLocatorSize = 112;

/// Continuation flag of LOB binds and defines.
enum ulong lobPrefetchFlag = 0x0200_0000;
public import oracle.types.oson : jsonMaxLength;
public import oracle.types.vector : vectorMaxLength;

/++
The define of one column: its wire type (`ColumnInfo.wireType`), with LOBs
fetched as LONG / LONG RAW values or as locators.
+/
void putDefineMetadata(ref TtcWriter w, const ColumnInfo c, ubyte fieldVersion) @safe pure nothrow
{
    import oracle.protocol.negotiate : CharsetId;

    const t = c.wireType;
    const text = t == OracleType.varchar || t == OracleType.char_ || t == OracleType.long_ || t == OracleType.clob;
    // JSON and VECTOR images come with the rows, like LOB data prefetched with the locator
    const prefetch = t == OracleType.json ? jsonMaxLength : t == OracleType.vector ? vectorMaxLength : 0;
    uint size = c.bufferSize;
    if (t == OracleType.long_ || t == OracleType.longRaw)
        size = 0x7FFF_FFFF;
    else if (t == OracleType.clob || t == OracleType.blob)
        size = lobLocatorSize;
    else if (prefetch)
        size = prefetch;
    const prefetched = t == OracleType.clob || t == OracleType.blob || prefetch != 0;
    w.u8(t);
    w.u8(0x01); // use indicators
    w.u8(0); // precision
    w.u8(0); // scale
    w.ub(size);
    w.ub(0); // maximum array elements
    w.ub(prefetched ? lobPrefetchFlag : 0);
    w.ub(0); // object type ID
    w.ub(0); // object type version
    w.ub(text ? CharsetId.al32utf8 : 0);
    w.u8(text ? (c.charsetForm ? c.charsetForm : CharsetForm.implicit) : CharsetForm.none);
    w.ub(prefetch); // LOB prefetch length
    if (fieldVersion >= TtcFieldVersion.v12_2)
        w.ub(0); // oaccolid
}

/// The metadata of one bind.
void putBindMetadata(ref TtcWriter w, const Parameter b, ubyte fieldVersion) @safe pure nothrow
{
    import oracle.protocol.negotiate : CharsetId;

    w.u8(b.type);
    w.u8(0x01); // use indicators
    w.u8(0); // precision
    w.u8(0); // scale
    w.ub(b.bufferSize);
    w.ub(0); // maximum array elements
    const lob = b.type == OracleType.clob || b.type == OracleType.blob || b.type == OracleType.vector
        || b.type == OracleType.json;
    w.ub(lob ? lobPrefetchFlag : 0); // continuation flags
    w.ub(0); // object type ID
    w.ub(0); // object type version
    w.ub(b.isText ? CharsetId.al32utf8 : 0);
    w.u8(b.isText ? CharsetForm.implicit : CharsetForm.none);
    w.ub(b.type == OracleType.vector ? vectorMaxLength : b.type == OracleType.json ? jsonMaxLength : 0); // LOB prefetch length
    if (fieldVersion >= TtcFieldVersion.v12_2)
        w.ub(0); // oaccolid
}

/// The bind values: a ROW_DATA message per execution.
void putBindRows(ref TtcWriter w, const(Parameter[])[] rows, const(bool)[] sendValue) @safe pure nothrow
{
    foreach (row; rows)
    {
        bool any;
        foreach (i; 0 .. row.length)
            any = any || !sendValue.length || sendValue[i];
        if (!any)
            continue; // no values to send (no binds, or only RETURNING targets): no ROW_DATA
        w.u8(MessageType.rowData);
        // values over the 32767-byte limit (LONG binding) come after all the others
        foreach (pass; 0 .. 2)
            foreach (i, ref p; row)
            {
                if (sendValue.length && !sendValue[i])
                    continue;
                if (isLongBind(p) != (pass == 1))
                    continue;
                putBindValue(w, p);
            }
    }
}

/// Whether a bind is sent as a long value: VARCHAR2 or RAW bigger than 32767 bytes.
bool isLongBind(const ref Parameter p) @safe pure nothrow
{
    return (p.type == OracleType.varchar || p.type == OracleType.raw) && p.bufferSize > 32_767;
}

private void putBindValue(ref TtcWriter w, const ref Parameter p) @safe pure nothrow
{
    if (p.type == OracleType.cursor)
        w.bytes([1, 0]); // a NULL cursor
    else if (p.type == OracleType.boolean && p.isNull)
        w.bytes([253, 1]); // a NULL BOOLEAN
    else if ((p.type == OracleType.vector || p.type == OracleType.json) && !p.isNull)
    {
        // a value-based locator (QLocator, 40 bytes, version 4, a BLOB value), then the image (VECTOR, OSON)
        w.ub(40);
        w.u8(40);
        w.u16be(38);
        w.u16be(4);
        w.u8(0x20 | 0x01 | 0x40); // value based, BLOB, abstract
        w.u8(0x08); // initialized
        w.u16be(0);
        w.u16be(1);
        w.u32be(0);
        w.u32be(cast(uint) p.data.length);
        w.bytes(new ubyte[2 + 2 + 2 + 8 + 8]);
        w.clr(p.data);
    }
    else if (p.type == OracleType.clob || p.type == OracleType.blob || p.type == OracleType.bfile)
        w.bytesWithLength(p.isNull ? null : p.data); // a locator
    else
        w.clr(p.isNull ? null : p.data);
}

/++
A re-execution of a parsed cursor with new bind values: REEXECUTE (DML,
PL/SQL) or REEXECUTE_AND_FETCH (queries, returning `prefetchRows` rows).
+/
ubyte[] buildReexecute(uint cursorId, bool query, uint prefetchRows, bool commit, const(Parameter[])[] rows,
        const(bool)[] sendValue, ubyte sequence, ubyte fieldVersion) @safe pure
{
    TtcWriter w;
    functionHeader(w, query ? FunctionCode.reexecuteAndFetch : FunctionCode.reexecute, sequence, fieldVersion);
    w.ub(cursorId);
    w.ub(query ? prefetchRows : rows.length ? rows.length : 1);
    w.ub(query ? 0x20 : 0); // options 1
    w.ub(commit ? 1 : 0); // options 2
    putBindRows(w, rows, sendValue);
    return w.data;
}

/// The FETCH message: `rows` more rows of `cursorId`.
ubyte[] buildFetch(uint cursorId, uint rows, ubyte sequence, ubyte fieldVersion) @safe pure nothrow
{
    TtcWriter w;
    functionHeader(w, FunctionCode.fetch, sequence, fieldVersion);
    w.ub(cursorId);
    w.ub(rows);
    return w.data;
}

/// A call without arguments (COMMIT, ROLLBACK, PING, LOGOFF).
ubyte[] buildBareCall(FunctionCode code, ubyte sequence, ubyte fieldVersion) @safe pure nothrow
{
    TtcWriter w;
    functionHeader(w, code, sequence, fieldVersion);
    return w.data;
}

/// The close-cursors piggyback, sent before another call.
void putCloseCursors(ref TtcWriter w, scope const uint[] cursorIds, ubyte sequence, ubyte fieldVersion) @safe
pure nothrow
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
    return readDescribeBody(r, fieldVersion);
}

/// Reads describe information without its leading CLR (as in implicit results and REF cursors).
ColumnInfo[] readDescribeBody(ref TtcReader r, ubyte fieldVersion) @safe
{
    r.ub4(); // maximum row size
    const count = r.ub4();
    if (count > 1000)
        throw new ProtocolException("Invalid column count " ~ to!string(count));
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
        const udsFlags = r.ub4();
        c.isJson = (udsFlags & 0x100) != 0;
        c.isOson = (udsFlags & 0x800) != 0;
        if (fieldVersion >= TtcFieldVersion.v23_1)
        {
            c.domainSchema = r.textWithLength();
            c.domainName = r.textWithLength();
        }
        if (fieldVersion >= TtcFieldVersion.v23_1_ext3)
            c.annotations = readAnnotations(r);
        if (fieldVersion >= TtcFieldVersion.v23_4)
        {
            c.vectorDimensions = r.ub4();
            c.vectorFormat = r.u8();
            c.vectorFlags = r.u8();
        }
    }
    r.bytesWithLength(); // current date
    r.ub4(); // DCB flags
    r.ub4(); // maximum fetch length
    r.ub4(); // maximum fetch elements
    r.ub4();
    r.clr();
    return columns;
}

/// Reads the annotations of a column (field version 23.1 extension 3).
private immutable(string[2])[] readAnnotations(ref TtcReader r) @safe
{
    if (r.ub4() == 0)
        return null;
    r.u8();
    const count = r.ub4();
    if (count > 10_000)
        throw new ProtocolException("Invalid annotation count " ~ to!string(count));
    r.u8();
    auto result = new string[2][count];
    foreach (ref a; result)
    {
        a[0] = r.textWithLength();
        a[1] = r.textWithLength();
        r.ub4(); // flags
    }
    r.ub4(); // flags
    return result.idup;
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
    const type = c.wireType;
    if (c.bufferSize == 0 && type != OracleType.long_ && type != OracleType.longRaw && type != OracleType.urowid
            && !c.isLob && type != OracleType.json && type != OracleType.vector)
        return null;
    switch (type)
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
        return r.clr(maxLength, true); // a column value: from the arena
    case OracleType.long_:
    case OracleType.longRaw:
        // chunked, then an indicator and a return code
        const v = r.clr(maxLength);
        r.sb(4);
        r.ub4();
        return v;
    case OracleType.urowid:
        return r.bytesWithLength();
    case OracleType.clob:
    case OracleType.blob:
        // a locator: its length, the LOB's size and chunk size, the locator; kept as u64be size, u32be chunk, locator
        const length = r.ub4();
        if (length == 0)
            return null;
        static ubyte[12] sizes(ulong size, uint chunk) @safe pure nothrow @nogc
        {
            ubyte[12] b;
            b[0 .. 8] = toBigEndian(size);
            b[8 .. 12] = toBigEndian(chunk);
            return b;
        }

        immutable ubyte[12] lengths = sizes(r.ub8(), r.ub4()); // the LOB's size, then its chunk size
        return lengths[] ~ r.clr();
    case OracleType.bfile:
        if (r.ub4() == 0)
            return null;
        return r.clr();
    case OracleType.json:
    case OracleType.vector:
        // like a LOB with its data prefetched: length, size, chunk size, the image, the locator (unused)
        if (r.ub4() == 0)
            return null;
        r.ub8();
        r.ub4();
        const image = r.clr(maxLength);
        r.clr();
        return image;
    case OracleType.rowid:
        // a length byte (0/255: NULL), then block address, partition, a byte, block, slot
        const length = r.u8();
        if (length == 0 || length == 255)
            return null;
        ubyte[13] rowid; // kept as ub4 ub2 ub1 ub4 ub2, big-endian
        rowid[0 .. 4] = toBigEndian(r.ub4());
        rowid[4 .. 6] = toBigEndian(r.ub2());
        rowid[6] = r.u8();
        rowid[7 .. 11] = toBigEndian(r.ub4());
        rowid[11 .. 13] = toBigEndian(r.ub2());
        return rowid[].idup;
    default:
        throw new ClientException("Columns of type " ~ c.typeText() ~ " are not supported yet (column "
                ~ c.name ~ ")");
    }
}

/++
Reads the return parameters of an EXECUTE (PARAMETER message, after its type
byte); returns the row count of each execution when they were asked for.
+/
ulong[] readReturnParameters(ref TtcReader r, bool dmlRowCounts) @safe
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
    ulong[] counts;
    if (dmlRowCounts)
    {
        const n = r.ub4();
        if (n > 1_000_000)
            throw new ProtocolException("Invalid DML row count array length");
        counts = new ulong[n];
        foreach (ref c; counts)
            c = r.ub8();
    }
    return counts;
}

/// Reads an IO_VECTOR (after its type byte): the direction of each bind (`BindDirection` values).
immutable(ubyte)[] readIoVector(ref TtcReader r) @safe
{
    r.u8(); // flag
    const low = r.ub2();
    const high = r.ub4();
    r.ub4();
    r.ub2();
    const bits = r.ub2();
    if (bits)
        r.skip(bits);
    const rowid = r.ub2();
    if (rowid)
        r.skip(rowid);
    const count = high * 256 + low;
    if (count > 65_535)
        throw new ProtocolException("Invalid bind count in an IO vector");
    return r.bytes(count);
}

/// A child cursor (implicit result, REF cursor): its columns and ID.
struct ChildCursor
{
    /// The result columns.
    ColumnInfo[] columns;
    /// The cursor ID.
    uint cursorId;
}

/// Reads an IMPLICIT_RESULTSET message (after its type byte).
ChildCursor[] readImplicitResults(ref TtcReader r, ubyte fieldVersion) @safe
{
    const count = r.ub4();
    if (count > 10_000)
        throw new ProtocolException("Invalid implicit result count");
    auto results = new ChildCursor[count];
    foreach (ref c; results)
    {
        r.skip(r.u8());
        c.columns = readDescribeBody(r, fieldVersion);
        c.cursorId = r.ub2();
    }
    return results;
}

/// Reads a REF cursor value (a column or OUT bind of type `CURSOR`).
ChildCursor readRefCursor(ref TtcReader r, ubyte fieldVersion) @safe
{
    ChildCursor c;
    r.u8(); // a length
    c.columns = readDescribeBody(r, fieldVersion);
    c.cursorId = r.ub2();
    return c;
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

// Bind messages against python-oracledb's bytes for the same calls (Oracle 26ai)
@safe unittest
{
    import dbwire.io.buffer : BufferedReader;
    import dbwire.io.mock : MockTransport;
    import oracle.params : Parameter;

    // bind metadata: a NUMBER, and VARCHAR2 'one' (buffer 3 × 4 bytes, AL32UTF8)
    TtcWriter w;
    putBindMetadata(w, Parameter.of(1), TtcFieldVersion.v19_1_ext1);
    assert(w.data == [0x02, 0x01, 0x00, 0x00, 0x01, 0x16, 0, 0, 0, 0, 0, 0, 0, 0]);
    w = TtcWriter.init;
    putBindMetadata(w, Parameter.of("one"), TtcFieldVersion.v19_1_ext1);
    assert(w.data == [0x01, 0x01, 0x00, 0x00, 0x01, 0x0C, 0, 0, 0, 0, 0x02, 0x03, 0x69, 0x01, 0, 0]);

    // re-executing INSERT ... VALUES (:1, :2, :3, :4) with (2, 20, 'two', DATE '2026-01-02 03:04:05'),
    // as python sends it at field version 24 (with the token number)
    const(Parameter)[] row = [
        Parameter.of(2), Parameter.of(20), Parameter.of("two"),
        Parameter.of(DateTime(2026, 1, 2, 3, 4, 5))
    ];
    assert(buildReexecute(1, false, 0, false, [row], null, 0x0C, 24) == [
        0x03, 0x04, 0x0C, 0x00, 0x01, 0x01, 0x01, 0x01, 0x00, 0x00, 0x07, 0x02, 0xC1, 0x03, 0x02, 0xC1,
        0x15,
        0x03, 0x74, 0x77, 0x6F, 0x07, 0x78, 0x7E, 0x01, 0x02, 0x04, 0x05, 0x06
    ]);

    // the IO vector of BEGIN :1 := 'out ' || :2; :3 := :3 * 2; END; (OUT, IN, IN OUT)
    auto t = new MockTransport;
    t.feed([0x05, 0x01, 0x03, 0x00, 0x01, 0x01, 0x00, 0x00, 0x00, 0x10, 0x20, 0x30]);
    auto r = TtcReader(new BufferedReader(t));
    assert(readIoVector(r) == [0x10, 0x20, 0x30]);
}

@safe unittest
{
    import dbwire.io.buffer : BufferedReader;
    import dbwire.io.mock : MockTransport;
    import oracle.protocol.messages : readErrorInfo;

    // ORA-24381 with one batch error (ORA-00001 in row 1), at server field version 14
    TtcWriter w;
    w.ub(2); // call status
    w.ub(1); // current row
    w.ub(24_381);
    foreach (_; 0 .. 4)
        w.ub(0); // array errors, cursor, position
    w.bytes([0, 0, 0, 0, 0]); // SQL type, fatal, flags, cursor options, UPI parameter
    w.u8(0); // warning flags
    foreach (_; 0 .. 5)
        w.ub(0); // ROWID
    w.ub(0); // OS error
    w.u8(0); // statement number
    w.u8(0); // call number
    w.ub(0); // padding
    w.ub(2); // successful iterations
    w.ub(0); // logical ROWID
    w.ub(1); // codes
    w.u8(2);
    w.ub(1);
    w.ub(1); // offsets
    w.u8(2);
    w.ub(1);
    w.ub(1); // messages
    w.u8(0x16);
    w.ub(19);
    w.clr(cast(const(ubyte)[]) "ORA-00001: unique\n");
    w.bytes([0, 0]);
    w.ub(24_381);
    w.ub(2); // rows
    w.ub(2); // SQL type
    w.ub(0); // checksum
    w.clr(cast(const(ubyte)[]) "ORA-24381: error(s) in array DML\n");
    auto t = new MockTransport;
    t.feed(w.data);
    auto r = TtcReader(new BufferedReader(t));
    const e = readErrorInfo(r, TtcFieldVersion.v20_1, false);
    assert(e.number == 24_381 && e.rowCount == 2 && e.batchErrors.length == 1);
    assert(e.batchErrors[0].offset == 1 && e.batchErrors[0].code == 1);
    assert(e.batchErrors[0].message == "ORA-00001: unique");
}

// Column defines against python-oracledb's bytes for the same queries (Oracle 26ai)
@safe unittest
{
    ColumnInfo c;
    c.type = OracleType.clob;
    c.charsetId = 873;
    c.charsetForm = CharsetForm.implicit;
    c.bufferSize = 4000;
    c.fetchType = OracleType.long_; // contents as values
    TtcWriter w;
    putDefineMetadata(w, c, TtcFieldVersion.v19_1_ext1);
    assert(w.data == [
        0x08, 0x01, 0, 0, 0x04, 0x7F, 0xFF, 0xFF, 0xFF, 0, 0, 0, 0, 0x02, 0x03, 0x69, 0x01, 0, 0
    ]);
    c.fetchType = OracleType.clob; // locators
    w = TtcWriter.init;
    putDefineMetadata(w, c, TtcFieldVersion.v19_1_ext1);
    assert(w.data == [
        0x70, 0x01, 0, 0, 0x01, 0x70, 0, 0x04, 0x02, 0, 0, 0, 0, 0, 0x02, 0x03, 0x69, 0x01, 0, 0
    ]);
    c.charsetForm = CharsetForm.nchar; // NCLOB: the same, form 2
    c.fetchType = OracleType.long_;
    w = TtcWriter.init;
    putDefineMetadata(w, c, TtcFieldVersion.v19_1_ext1);
    assert(w.data[$ - 3] == 0x02);
}
