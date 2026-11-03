/++
TTC messages shared by all calls: the function call header, key/value
parameters (PARAMETER messages) and the error / end-of-call status (ERROR
messages).

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module oracle.protocol.messages;

import oracle.exception : ProtocolException;
import oracle.protocol.negotiate : MessageType, TtcFieldVersion;
import oracle.protocol.ttc : TtcReader, TtcWriter;

/// Function codes of function calls.
enum FunctionCode : ubyte
{
    reexecute = 4, /// re-execute a parsed cursor
    reexecuteAndFetch = 78, /// re-execute a parsed query and fetch
    fetch = 5, /// fetch rows
    logoff = 9, /// log off
    commit = 14, /// commit
    rollback = 15, /// roll back
    execute = 94, /// execute ("OALL8")
    lobOp = 96, /// LOB operation
    closeCursors = 105, /// close cursors (piggyback)
    setEndToEnd = 135, /// set end-to-end attributes (piggyback)
    pipelineBegin = 199, /// a pipeline begins (piggyback)
    pipelineEnd = 200, /// the pipeline ends
    authPhase2 = 115, /// authentication, phase 2
    authPhase1 = 118, /// authentication, phase 1
    ping = 147, /// ping
    sessionRelease = 163, /// release a DRCP session (one-way: no response)
}

/// Writes the header of a function call: message type, function code, sequence number.
void functionHeader(ref TtcWriter w, FunctionCode code, ubyte sequence, ubyte fieldVersion) @safe pure
{
    w.u8(MessageType.function_);
    w.u8(code);
    w.u8(sequence);
    if (fieldVersion >= TtcFieldVersion.v23_1_ext1)
        w.ub(0); // token number
}

/// One key/value pair of a PARAMETER message.
struct KeyValue
{
    /// The key, e.g. "AUTH_SESSKEY".
    string key;
    /// The value (text).
    string value;
    /// Flags (for AUTH_VFR_DATA: the verifier type).
    uint flags;
}

/// Writes a key/value pair as authentication messages send them.
void keyValue(ref TtcWriter w, string key, scope const(char)[] value, uint flags = 0) @safe pure
{
    w.textWithLength(key);
    w.textWithLength(value);
    w.ub(flags);
}

/// Reads the key/value pairs of a PARAMETER message (after its type byte).
KeyValue[] readKeyValues(ref TtcReader r) @safe
{
    const count = r.ub2();
    auto result = new KeyValue[count];
    foreach (ref kv; result)
    {
        kv.key = r.textWithLength();
        kv.value = r.textWithLength();
        kv.flags = r.ub4();
    }
    return result;
}

/// The error / end-of-call status of a call.
struct ErrorInfo
{
    /// Call status bits (`0x2`: a transaction is in progress).
    uint callStatus;
    /// The cursor the call used.
    ushort cursorId;
    /// Position in the SQL text the error refers to (-1 if none).
    int position = -1;
    /// The error number (0: success; 1403: no more rows).
    uint number;
    /// Rows affected or fetched.
    ulong rowCount;
    /// The error text (`ORA-nnnnn: ...`).
    string message;
    /// The errors of single executions of array DML with batch errors.
    BatchError[] batchErrors;
}

/// The error of one execution of array DML with batch errors.
struct BatchError
{
    /// The execution (row) it happened in, from 0.
    uint offset;
    /// The ORA error number.
    uint code;
    /// The error text.
    string message;
}

/++
Reads an ERROR message (after its type byte).

`serverFieldVersion` is the server's own TTC field version: servers from 20.1
on add two fields whatever field version the client announced (checked on
26ai with client field versions 10 to 24). The end-to-end sequence number
that some clients get after the call status is only sent to clients with the
OCI1 capability bit 0x10, which this client doesn't announce.
+/
ErrorInfo readErrorInfo(ref TtcReader r, ubyte serverFieldVersion, bool endToEndSequence = true) @safe
{
    ErrorInfo e;
    e.callStatus = r.ub4();
    if (endToEndSequence)
        r.ub2(); // end-to-end sequence number (the client sends OCI1 session propagation)
    r.ub4(); // current row number
    const shortNumber = r.ub2();
    r.ub2(); // array element errors
    r.ub2();
    e.cursorId = r.ub2();
    e.position = cast(int) r.sb(2);
    r.skip(5); // SQL type, fatal, flags, user cursor options, UPI parameter
    r.u8(); // warning flags
    skipRowid(r);
    r.ub4(); // OS error
    r.u8(); // statement number
    r.u8(); // call number
    r.ub2(); // padding
    r.ub4(); // successful iterations
    r.bytesWithLength(); // logical rowid
    // batch errors: codes, offsets, messages (array DML with the batch errors option)
    const codes = r.ub2();
    uint[] codeList;
    if (codes)
        codeList = readArray(r, codes, 2);
    const offsets = r.ub4();
    uint[] offsetList;
    if (offsets)
        offsetList = readArray(r, offsets, 4);
    const messages = r.ub2();
    string[] messageList;
    if (messages)
    {
        r.u8(); // packed size
        foreach (_; 0 .. messages)
        {
            r.ub2(); // chunk length
            messageList ~= cast(string) r.clr();
            r.skip(2); // end marker
        }
    }
    foreach (i, code; codeList)
        e.batchErrors ~= BatchError(i < offsetList.length ? offsetList[i] : 0, code,
                i < messageList.length ? stripNewline(messageList[i]) : null);
    e.number = r.ub4();
    if (e.number == 0)
        e.number = shortNumber;
    e.rowCount = r.ub8();
    if (serverFieldVersion >= TtcFieldVersion.v20_1)
    {
        r.ub4(); // SQL type
        r.ub4(); // checksum
    }
    if (e.number != 0)
        e.message = cast(string) r.clr();
    return e;
}

/// Reads (and drops) a ROWID structure: row block address, partition, a byte, block, slot.
void skipRowid(ref TtcReader r) @safe
{
    r.ub4(); // row block address
    r.ub2(); // partition
    r.u8();
    r.ub4(); // block
    r.ub2(); // slot
}

/++
An array of batch error codes or offsets: a first byte (254: each element has
a ub4 prefix, and an end byte follows), then the elements.
+/
private uint[] readArray(ref TtcReader r, size_t count, size_t width) @safe
{
    if (count > 1_000_000)
        throw new ProtocolException("Invalid batch error count");
    const first = r.u8();
    auto values = new uint[count];
    foreach (ref v; values)
    {
        if (first == 254)
            r.ub4();
        v = cast(uint) r.ub(width);
    }
    if (first == 254)
        r.u8();
    return values;
}

private string stripNewline(string s) @safe pure nothrow
{
    while (s.length && (s[$ - 1] == '\n' || s[$ - 1] == '\0'))
        s = s[0 .. $ - 1];
    return s;
}

/// Reads a WARNING message (after its type byte).
void skipWarning(ref TtcReader r) @safe
{
    r.ub2(); // number
    const length = r.ub2();
    r.ub2(); // flags
    if (length)
        r.clr();
}

/// What a server-side piggyback said about the session (DRCP).
struct SessionReturn
{
    /// Whether the piggyback was a session return (the first call after a DRCP session release).
    bool present;
    /// Whether the server attached a different session: the cursors of the old one are gone.
    bool changed;
    /// The attached session's ID and serial number.
    uint sessionId;
    /// ditto
    ushort serialNumber;
}

/// Reads a server-side piggyback message (after its type byte); returns what it said about the session.
SessionReturn readServerPiggyback(ref TtcReader r) @safe
{
    SessionReturn ret;
    const opcode = r.u8();
    switch (opcode)
    {
    case 1: // query cache invalidation
    case 7: // LTXID
        r.clr();
        break;
    case 2: // OS PID
        r.ub2();
        r.clr();
        break;
    case 3: // trace event
    case 9: // ext sync
        r.ub2();
        r.u8();
        break;
    case 4: // session return: key/value pairs, the session flags, ID and serial number
        r.ub2();
        r.u8();
        const elements = r.ub2();
        if (elements)
        {
            r.u8();
            foreach (_; 0 .. elements)
            {
                if (r.ub2())
                    r.clr(); // key
                if (r.ub2())
                    r.clr(); // value
                r.ub2(); // flags
            }
        }
        ret.present = true;
        ret.changed = (r.ub4() & sessionChanged) != 0;
        ret.sessionId = r.ub4();
        ret.serialNumber = r.ub2();
        break;
    case 5: // sync: key/value pairs
        r.ub2();
        r.u8();
        const pairs = r.ub2();
        r.u8();
        foreach (_; 0 .. pairs)
        {
            r.bytesWithLength();
            r.bytesWithLength();
            r.ub4();
        }
        r.ub4();
        break;
    case 8: // application continuity replay context
        r.ub2();
        r.u8();
        r.ub4();
        r.ub4();
        r.bytesWithLength();
        break;
    case 10: // session signature
        r.ub2();
        r.u8();
        r.ub8();
        r.ub8();
        break;
    default:
        throw new ProtocolException("Unknown server piggyback " ~ toText(opcode));
    }
    return ret;
}

/// Session flag of a session return: another session was attached.
private enum uint sessionChanged = 4;

private string toText(T)(T v) @safe pure
{
    import std.conv : to;

    return v.to!string;
}

///
@safe unittest
{
    TtcWriter w;
    functionHeader(w, FunctionCode.ping, 1, TtcFieldVersion.v19_1_ext1);
    assert(w.data == [3, 147, 1]);
    w = TtcWriter.init;
    functionHeader(w, FunctionCode.ping, 2, TtcFieldVersion.v23_1_ext1);
    assert(w.data == [3, 147, 2, 0]); // with a token number
    w = TtcWriter.init;
    keyValue(w, "AUTH_PID", "42");
    assert(w.data == [1, 8, 8, 'A', 'U', 'T', 'H', '_', 'P', 'I', 'D', 1, 2, 2, '4', '2', 0]);
}

/// End-to-end attributes of a session (`V$SESSION`, `SYS_CONTEXT('USERENV', ...)`), sent when they change.
struct EndToEnd
{
    /// The attributes, in `EndToEndAttribute` order; null clears one.
    string[5] values;
    /// Which attributes changed (bit `1 << EndToEndAttribute`).
    uint changed;
}

/// The end-to-end attributes.
enum EndToEndAttribute
{
    clientIdentifier, /// `CLIENT_IDENTIFIER`
    module_, /// `MODULE`
    action, /// `ACTION`
    clientInfo, /// `CLIENT_INFO`
    dbOp, /// `DBOP` (database operation)
}

/// The piggyback that sends the changed end-to-end attributes before a call.
void putEndToEnd(ref TtcWriter w, const ref EndToEnd e, ubyte sequence, ubyte fieldVersion) @safe pure
{
    static immutable uint[5] flagBits = [0x0001, 0x0008, 0x0010, 0x0100, 0x0200];
    w.u8(MessageType.piggyback);
    w.u8(FunctionCode.setEndToEnd);
    w.u8(sequence);
    if (fieldVersion >= TtcFieldVersion.v23_1_ext1)
        w.ub(0); // token number
    w.u8(0); // pointer (name)
    w.u8(0); // pointer (serial number)
    uint flags;
    foreach (i, bit; flagBits)
        if (e.changed & (1 << i))
            flags |= bit;
    w.ub(flags);
    void header(EndToEndAttribute a)
    {
        const changed = (e.changed & (1 << a)) != 0;
        w.u8(changed ? 1 : 0);
        w.ub(changed ? e.values[a].length : 0);
    }

    header(EndToEndAttribute.clientIdentifier);
    header(EndToEndAttribute.module_);
    header(EndToEndAttribute.action);
    w.u8(0); // execution context ID: pointer, length, and two more fields
    w.ub(0);
    w.u8(0);
    w.ub(0);
    header(EndToEndAttribute.clientInfo);
    w.u8(0); // two unused attributes: pointer and length each
    w.ub(0);
    w.u8(0);
    w.ub(0);
    header(EndToEndAttribute.dbOp);
    foreach (a; [
        EndToEndAttribute.clientIdentifier, EndToEndAttribute.module_, EndToEndAttribute.action,
        EndToEndAttribute.clientInfo, EndToEndAttribute.dbOp
    ])
        if ((e.changed & (1 << a)) && e.values[a].length)
            w.clr(cast(const(ubyte)[]) e.values[a]);
}

/// How a pipeline goes on after a failed call.
enum PipelineMode : ubyte
{
    continueOnError = 1, /// the later calls run
    abortOnError = 2, /// the later calls fail too
}

/// The piggyback that begins a pipeline (before its first call).
void putBeginPipeline(ref TtcWriter w, PipelineMode mode, ubyte sequence, ubyte fieldVersion) @safe pure
{
    w.u8(MessageType.piggyback);
    w.u8(FunctionCode.pipelineBegin);
    w.u8(sequence);
    if (fieldVersion >= TtcFieldVersion.v23_1_ext1)
        w.ub(0); // token number
    w.ub(0); // error set ID
    w.u8(0); // error set mode
    w.u8(mode);
}

/// The call that ends a pipeline (after its last call).
ubyte[] buildEndPipeline(ubyte sequence, ubyte fieldVersion) @safe pure
{
    TtcWriter w;
    functionHeader(w, FunctionCode.pipelineEnd, sequence, fieldVersion);
    w.ub(0); // ID (unused)
    return w.data;
}

/// How a DRCP session is released.
enum SessionReleaseMode : uint
{
    keep = 0, /// back to the server's pool, keeping its state, for this connection class
    deauthenticate = 2, /// the session is ended (the connection is about to close)
}

/++
The one-way call that hands the DRCP session back to the server's pool. The
server doesn't answer it; the next call attaches a session again.
+/
ubyte[] buildSessionRelease(SessionReleaseMode mode, ubyte sequence, ubyte fieldVersion) @safe pure
{
    TtcWriter w;
    w.u8(MessageType.oneWayFunction);
    w.u8(FunctionCode.sessionRelease);
    w.u8(sequence);
    if (fieldVersion >= TtcFieldVersion.v23_1_ext1)
        w.ub(0); // token number
    w.u8(0); // tag (none)
    w.u8(0); // tag length
    w.ub(mode);
    return w.data;
}

///
@safe unittest
{
    assert(buildSessionRelease(SessionReleaseMode.keep, 5, TtcFieldVersion.v19_1_ext1) == [
        26, 163, 5, 0, 0, 0
    ]);
    assert(buildSessionRelease(SessionReleaseMode.deauthenticate, 6, TtcFieldVersion.v23_1_ext1) == [
        26, 163, 6, 0,
        0, 0, 1, 2
    ]);
}

@safe unittest
{
    // a session return with one key/value pair, flags "changed", session 77, serial 9
    TtcWriter w;
    w.u8(4);
    w.ub(1);
    w.u8(0);
    w.ub(1);
    w.u8(0);
    w.ub(1);
    w.clr(cast(const(ubyte)[]) "K");
    w.ub(1);
    w.clr(cast(const(ubyte)[]) "V");
    w.ub(0);
    w.ub(4);
    w.ub(77);
    w.ub(9);
    import dbwire.io.buffer : BufferedReader;
    import dbwire.io.mock : MockTransport;

    auto t = new MockTransport;
    t.feed(w.data);
    auto r = TtcReader(new BufferedReader(t));
    const ret = readServerPiggyback(r);
    assert(ret.present && ret.changed && ret.sessionId == 77 && ret.serialNumber == 9);
}
