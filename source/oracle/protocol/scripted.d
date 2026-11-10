/++
Scripted server responses for unit tests (unittest builds only): TNS DATA
packets with TTC messages, written with `TtcWriter`, for a `Connection` made
over dbwire's `MockTransport` with `Connection.scripted` (logged in already,
at TTC field version 13 unless told otherwise).

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module oracle.protocol.scripted;

version (unittest)  : import oracle.protocol.negotiate : MessageType;
import oracle.protocol.ttc : TtcWriter;
import oracle.types.typeinfo : OracleType;

/// The field version of the scripted messages: 19c (no token numbers, no 20.1 ERROR fields).
package(oracle) enum ubyte scriptedFieldVersion = 13;

/// A DATA packet (4-byte length, large SDU) with `payload`.
package(oracle) ubyte[] dataPacket(scope const(ubyte)[] payload) @safe pure nothrow
{
    auto p = new ubyte[10 + payload.length];
    const n = p.length;
    p[0] = cast(ubyte)(n >> 24);
    p[1] = cast(ubyte)(n >> 16);
    p[2] = cast(ubyte)(n >> 8);
    p[3] = cast(ubyte) n;
    p[4] = 6; // DATA
    p[10 .. $] = payload[];
    return p;
}

/// `payload` in DATA packets of at most `size` bytes each.
package(oracle) ubyte[] dataPackets(scope const(ubyte)[] payload, size_t size = 8000) @safe pure nothrow
{
    ubyte[] all;
    while (payload.length)
    {
        const n = payload.length < size ? payload.length : size;
        all ~= dataPacket(payload[0 .. n]);
        payload = payload[n .. $];
    }
    return all;
}

/++
An ERROR message ending a response: `number` 0 (more rows to fetch, or a
call that succeeded), 1403 (no more rows) or an ORA error with `message`.
+/
package(oracle) void putError(ref TtcWriter w, uint number, uint cursorId, string message = null,
        ulong rowCount = 0) @safe pure
{
    w.u8(MessageType.error);
    w.ub(0); // call status
    w.ub(0); // end-to-end sequence number
    w.ub(0); // current row
    w.ub(0); // short error number
    w.ub(0);
    w.ub(0);
    w.ub(cursorId);
    w.sb(-1); // error position
    w.bytes([0, 0, 0, 0, 0]);
    w.u8(0); // warning flags
    w.ub(0); // ROWID
    w.ub(0);
    w.u8(0);
    w.ub(0);
    w.ub(0);
    w.ub(0); // OS error
    w.u8(0);
    w.u8(0);
    w.ub(0);
    w.ub(0); // successful iterations
    w.ub(0); // logical ROWID
    w.ub(0); // batch error codes
    w.ub(0); // their offsets
    w.ub(0); // their messages
    w.ub(number);
    w.ub(rowCount);
    if (number)
        w.clr(cast(const(ubyte)[])(message.length ? message : "ORA-error"));
}

/// A column of `putDescribe`.
package(oracle) struct Col
{
    OracleType type; ///
    uint bufferSize; ///
    string name; ///
}

/// A DESCRIBE_INFO message for `cols`.
package(oracle) void putDescribe(ref TtcWriter w, scope const(Col)[] cols) @safe pure
{
    w.u8(MessageType.describeInfo);
    w.clr(null); // the cursor's identity
    w.ub(0); // max row size
    w.ub(cols.length);
    if (cols.length)
        w.u8(0);
    foreach (c; cols)
    {
        w.u8(c.type);
        w.u8(0);
        w.u8(0);
        w.u8(0);
        w.ub(c.bufferSize);
        w.ub(0);
        w.ub(0);
        w.ub(0); // object type ID
        w.ub(0);
        w.ub(c.type == OracleType.varchar ? 873 : 0); // character set
        w.u8(c.type == OracleType.varchar ? 1 : 0); // character set form
        w.ub(c.bufferSize);
        w.ub(0); // oaccolid
        w.u8(1); // nullable
        w.u8(0);
        w.textWithLength(c.name);
        w.textWithLength(null); // type schema
        w.textWithLength(null); // type name
        w.ub(0); // column position
        w.ub(0); // UDS flags
    }
    w.ub(0); // current date
    w.ub(0);
    w.ub(0);
    w.ub(0);
    w.ub(0);
    w.clr(null);
}

/// A ROW_DATA message with one NUMBER column (`value` from 0 to 99).
package(oracle) void putNumberRow(ref TtcWriter w, ubyte value) @safe pure
{
    w.u8(MessageType.rowData);
    if (value == 0)
        w.clr([0x80]);
    else
        w.clr([0xC1, cast(ubyte)(value + 1)]);
}
