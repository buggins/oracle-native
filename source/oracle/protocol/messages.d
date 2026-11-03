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
    fetch = 5, /// fetch rows
    logoff = 9, /// log off
    commit = 14, /// commit
    rollback = 15, /// roll back
    execute = 94, /// execute ("OALL8")
    lobOp = 96, /// LOB operation
    closeCursors = 105, /// close cursors (piggyback)
    authPhase2 = 115, /// authentication, phase 2
    authPhase1 = 118, /// authentication, phase 1
    ping = 147, /// ping
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
}

/++
Reads an ERROR message (after its type byte).

`serverFieldVersion` is the server's own TTC field version: servers from 20.1
on add two fields whatever field version the client announced (checked on
26ai with client field versions 10 to 24). The end-to-end sequence number
that some clients get after the call status is only sent to clients with the
OCI1 capability bit 0x10, which this client doesn't announce.
+/
ErrorInfo readErrorInfo(ref TtcReader r, ubyte serverFieldVersion) @safe
{
    ErrorInfo e;
    e.callStatus = r.ub4();
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
    // batch errors: codes, offsets, messages
    const codes = r.ub2();
    if (codes)
        skipArray(r, codes, 2);
    const offsets = r.ub4();
    if (offsets)
        skipArray(r, offsets, 4);
    const messages = r.ub2();
    if (messages)
    {
        r.u8();
        foreach (_; 0 .. messages)
        {
            r.ub2();
            r.clr();
            r.skip(2);
        }
    }
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

/// An array of batch error codes or offsets: a marker byte (254: each element has a ub4 prefix), elements, an end byte.
private void skipArray(ref TtcReader r, size_t count, size_t width) @safe
{
    const marker = r.u8();
    foreach (_; 0 .. count)
    {
        if (marker == 254)
            r.ub4();
        r.ub(width);
    }
    r.u8();
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

/// Reads a server-side piggyback message (after its type byte) and drops it.
void skipServerPiggyback(ref TtcReader r) @safe
{
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
    case 4: // session return
        r.ub4();
        r.ub4();
        r.ub2();
        r.ub2();
        r.ub8(); // reserved [?]
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
}

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
