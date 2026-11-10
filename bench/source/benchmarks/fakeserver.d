/++
An in-memory Oracle server for the benchmarks: a `Transport` that answers the
listener handshake (ACCEPT), the protocol and data-type negotiation and the
O5LOGON exchange (12c verifier, computed with dbwire's crypto, so a real
`Connection` logs in), then hands out scripted responses, one per request.

The scripted responses are TTC messages at field version 13 (19c), built
with the helpers below (`putDescribe`, `putRow`, `putEnd`).

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module benchmarks.fakeserver;

import core.time : Duration;
import dbwire.io.transport : Transport;
import oracle.protocol.negotiate : MessageType;
import oracle.protocol.ttc : TtcWriter;
import oracle.types.typeinfo : OracleType;

/// The TTC field version the fake server announces.
enum ubyte fieldVersion = 13;

/// The password the fake server accepts (any user name).
enum password = "bench";

/// The fake server.
final class FakeServer : Transport
{
    private enum Phase
    {
        connect,
        connectData,
        protocol,
        dataTypes,
        authPhase1,
        authPhase2,
        ready,
    }

    private Phase phase;
    private ubyte[] input; // client bytes of an incomplete packet
    private const(ubyte)[][] output; // server bytes not read yet: packet headers and slices of the responses
    private size_t outputIndex, outputPos;
    private const(ubyte)[][] script; // responses for the next requests
    private size_t scriptPos;
    private bool largeLengths;
    private ubyte[32] serverKey;
    private ubyte[16] salt, cskSalt;
    private ubyte[32] passwordHash;
    private bool closed;

    /// A server that has not been connected to yet.
    this() @safe
    {
        foreach (i, ref b; serverKey)
            b = cast(ubyte)(i * 7 + 1);
        foreach (i, ref b; salt)
            b = cast(ubyte)(0x10 + i);
        foreach (i, ref b; cskSalt)
            b = cast(ubyte)(0x30 + i);
    }

    /// The responses to the next requests, in order (each a sequence of TTC messages).
    void respond(const(ubyte[][]) responses) @safe
    {
        script = responses.dup;
        scriptPos = 0;
    }

    /// Whether every scripted response was asked for.
    @property bool scriptDone() const @safe pure nothrow
    {
        return scriptPos == script.length;
    }

    override size_t read(scope ubyte[] buffer) @safe
    {
        if (outputIndex == output.length)
            return 0; // the end of the stream (nothing scripted)
        const chunk = output[outputIndex];
        const n = chunk.length - outputPos < buffer.length ? chunk.length - outputPos : buffer.length;
        buffer[0 .. n] = chunk[outputPos .. outputPos + n];
        outputPos += n;
        if (outputPos == chunk.length)
        {
            outputIndex++;
            outputPos = 0;
            if (outputIndex == output.length)
            {
                output.length = 0; // all read: reused (its capacity kept)
                (() @trusted => output.assumeSafeAppend())(); // nothing refers to the old elements any more
                outputIndex = 0;
            }
        }
        return n;
    }

    override void write(scope const(ubyte)[] data) @safe
    {
        // whole packets straight from `data`; only an incomplete one is kept
        if (input.length)
        {
            input ~= data;
            data = input;
        }
        for (;;)
        {
            const length = packetLength(data);
            if (length == 0 || data.length < length)
                break;
            packet(data[0 .. length]);
            data = data[length .. $];
        }
        input = data.length ? data.dup : null;
    }

    // The length of the packet at the start of `data`, or 0 if its header is incomplete.
    private size_t packetLength(scope const(ubyte)[] data) const @safe
    {
        if (data.length < 8)
            return 0;
        size_t length;
        foreach (i; 0 .. largeLengths ? 4 : 2)
            length = (length << 8) | data[i];
        return length;
    }

    override bool dataAvailable() @safe
    {
        return outputIndex < output.length;
    }

    override void close() @safe nothrow
    {
        closed = true;
    }

    override bool connected() const @safe nothrow
    {
        return !closed;
    }

    override void setTimeouts(Duration receive, Duration send) @safe
    {
    }

    private void packet(scope const(ubyte)[] p) @safe
    {
        enum ubyte connectPacket = 1, dataPacket = 6;
        final switch (phase)
        {
        case Phase.connect:
            assert(p[4] == connectPacket, "expected CONNECT");
            const dataLength = (p[24] << 8) | p[25];
            if (dataLength && p.length == 74)
                phase = Phase.connectData; // the connect data follow in a DATA packet
            else
                accept();
            break;
        case Phase.connectData:
            assert(p[4] == dataPacket, "expected the connect data");
            accept();
            break;
        case Phase.protocol:
            send(protocolResponse());
            phase = Phase.dataTypes;
            break;
        case Phase.dataTypes:
            send([MessageType.dataTypes, 0, 0]);
            phase = Phase.authPhase1;
            break;
        case Phase.authPhase1:
            send(phase1Response());
            phase = Phase.authPhase2;
            break;
        case Phase.authPhase2:
            send(phase2Response(p[10 .. $]));
            phase = Phase.ready;
            break;
        case Phase.ready:
            if (p[4] != dataPacket || p.length <= 10 || (p[8] & 0x40)) // markers, EOF
                return;
            if (scriptPos < script.length)
                send(script[scriptPos++]);
            break;
        }
    }

    private void accept() @safe
    {
        auto a = new ubyte[45];
        a[0] = 0;
        a[1] = cast(ubyte) a.length;
        a[4] = 2; // ACCEPT
        a[8] = 318 >> 8; // TNS version 318: 32-bit lengths and SDU, no END_OF_RESPONSE
        a[9] = 318 & 0xFF;
        a[12] = 0x20; // SDU (16-bit field)
        a[13] = 0x00;
        enum uint sdu = 2 * 1024 * 1024;
        a[32 .. 36] = [
            cast(ubyte)(sdu >> 24), cast(ubyte)(sdu >> 16), cast(ubyte)(sdu >> 8), cast(ubyte) sdu
        ];
        output ~= a;
        largeLengths = true;
        phase = Phase.protocol;
    }

    // `payload` in DATA packets of up to 32 KB; the payload is not copied (it must stay unchanged until read)
    private void send(const(ubyte)[] payload) @safe
    {
        do
        {
            const n = payload.length < 32_768 ? payload.length : 32_768;
            output ~= dataHeader(10 + n);
            output ~= payload[0 .. n];
            payload = payload[n .. $];
        }
        while (payload.length);
    }

    // The header of a DATA packet of `length` bytes (cached: the same few lengths come again and again).
    private const(ubyte)[] dataHeader(size_t length) @safe
    {
        if (auto h = length in headers)
            return *h;
        auto header = new ubyte[10];
        header[0 .. 4] = [
            cast(ubyte)(length >> 24), cast(ubyte)(length >> 16), cast(ubyte)(length >> 8),
            cast(ubyte) length
        ];
        header[4] = 6; // DATA
        headers[length] = header;
        return header;
    }

    private const(ubyte)[][size_t] headers;

    private ubyte[] protocolResponse() @safe
    {
        TtcWriter w;
        w.u8(MessageType.protocol);
        w.u8(6); // server protocol version
        w.u8(0);
        w.bytes(cast(const(ubyte)[]) "Fake Oracle\0");
        w.u8(873 & 0xFF); // character set AL32UTF8, little-endian
        w.u8(873 >> 8);
        w.u8(0); // flags
        w.u8(0); // no elements
        w.u8(0);
        w.u8(0); // no FDO
        w.u8(0);
        ubyte[55] compileCaps;
        compileCaps[7] = fieldVersion;
        w.clr(compileCaps[]);
        ubyte[13] runtimeCaps;
        w.clr(runtimeCaps[]);
        return w.data;
    }

    private ubyte[] phase1Response() @safe
    {
        import std.digest : digest;
        import std.digest.sha : SHA512;
        import dbwire.crypto.aes : Aes, cbcEncrypt;
        import dbwire.crypto.pbkdf2 : pbkdf2;
        import oracle.protocol.auth : hex;

        // the 12c verifier: the password hash the client derives the same way
        const key = pbkdf2!SHA512(cast(const(ubyte)[]) password, salt[] ~ cast(const(ubyte)[]) "AUTH_PBKDF2_SPEEDY_KEY",
                4096, 64);
        passwordHash[] = digest!SHA512(key ~ salt[])[0 .. 32];
        const ubyte[16] zero = 0;
        const aes = Aes(passwordHash[]);
        TtcWriter w;
        w.u8(MessageType.parameter);
        w.ub(5);
        keyValue(w, "AUTH_SESSKEY", hex(cbcEncrypt(aes, zero, serverKey[])));
        keyValue(w, "AUTH_VFR_DATA", hex(salt[]), 0x4815);
        keyValue(w, "AUTH_PBKDF2_CSK_SALT", hex(cskSalt[]));
        keyValue(w, "AUTH_PBKDF2_VGEN_COUNT", "4096");
        keyValue(w, "AUTH_PBKDF2_SDER_COUNT", "3");
        putEnd(w, 0, 0);
        return w.data;
    }

    private ubyte[] phase2Response(scope const(ubyte)[] request) @safe
    {
        import std.digest.sha : SHA512;
        import std.regex : ctRegex, matchFirst;
        import dbwire.crypto.aes : Aes, cbcDecrypt, cbcEncrypt;
        import dbwire.crypto.pbkdf2 : pbkdf2;
        import oracle.protocol.auth : hex, unhex;

        // the client's session key: the 64 hex digits after AUTH_SESSKEY
        const text = cast(const(char)[]) request;
        const m = matchFirst(text, ctRegex!`AUTH_SESSKEY.{1,8}?([0-9A-F]{64})`);
        assert(!m.empty, "no AUTH_SESSKEY in the phase 2 request");
        const ubyte[16] zero = 0;
        const keyAes = Aes(passwordHash[]);
        const clientKey = cbcDecrypt(keyAes, zero, unhex(m[1]));
        const combo = pbkdf2!SHA512(cast(const(ubyte)[]) hex(clientKey[0 .. 32] ~ serverKey[]), cskSalt[], 3, 32);
        ubyte[32] proof;
        proof[16 .. 32] = cast(const(ubyte)[]) "SERVER_TO_CLIENT";
        TtcWriter w;
        w.u8(MessageType.parameter);
        w.ub(4);
        const comboAes = Aes(combo);
        keyValue(w, "AUTH_SVR_RESPONSE", hex(cbcEncrypt(comboAes, zero, proof[])));
        keyValue(w, "AUTH_VERSION_NO", "318767104"); // 19.0.0.0.0
        keyValue(w, "AUTH_SESSION_ID", "42");
        keyValue(w, "AUTH_SERIAL_NUM", "7");
        putEnd(w, 0, 0);
        return w.data;
    }
}

private void keyValue(ref TtcWriter w, string key, string value, uint flags = 0) @safe
{
    w.textWithLength(key);
    w.textWithLength(value);
    w.ub(flags);
}

/++
The end of a response (an ERROR message): `number` 0 (more rows to fetch, or
a call that succeeded), 1403 (no more rows) or an ORA error.
+/
void putEnd(ref TtcWriter w, uint number, uint cursorId, ulong rowCount = 0) @safe
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
    if (number != 0)
        w.clr(cast(const(ubyte)[])(number == 1403 ? "ORA-01403: no data found" : "ORA-00001: error"));
}

/// A column of `putDescribe`.
struct Col
{
    OracleType type; ///
    uint bufferSize; ///
    string name; ///
}

/// A DESCRIBE_INFO message.
void putDescribe(ref TtcWriter w, scope const(Col)[] cols) @safe
{
    w.u8(MessageType.describeInfo);
    w.clr(null); // the cursor's identity
    w.ub(0); // max row size
    w.ub(cols.length);
    if (cols.length)
        w.u8(0);
    foreach (c; cols)
    {
        const text = c.type == OracleType.varchar;
        w.u8(c.type);
        w.u8(0);
        w.u8(0); // precision
        w.u8(c.type == OracleType.timestamp ? 6 : 0); // scale: fraction digits
        w.ub(c.bufferSize);
        w.ub(0);
        w.ub(0);
        w.ub(0); // object type ID
        w.ub(0);
        w.ub(text ? 873 : 0); // character set
        w.u8(text ? 1 : 0); // character set form
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

/// A ROW_DATA message with the column values (null for NULL).
void putRow(ref TtcWriter w, scope const(ubyte[])[] values) @safe
{
    w.u8(MessageType.rowData);
    foreach (v; values)
        w.clr(v);
}
