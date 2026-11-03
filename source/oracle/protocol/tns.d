/++
The TNS (Oracle Net) packet layer: packet headers, the connect handshake
packets (CONNECT, ACCEPT, REFUSE, REDIRECT, RESEND), DATA packets carrying the
TTC calls, and MARKER packets for break/reset (cancel).

A packet starts with an 8-byte header: the packet length (a big-endian u16, or
a u32 once the negotiated version is 315 or more), a checksum (0), the type,
flags and a header checksum (0). DATA packets add a 2-byte data flags field.

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module oracle.protocol.tns;

import core.time : Duration;
import dbwire.io.transport : Transport;
import oracle.exception : ConnectionException, ProtocolException;

/// TNS packet types.
enum PacketType : ubyte
{
    connect = 1, /// CONNECT
    accept = 2, /// ACCEPT
    refuse = 4, /// REFUSE
    redirect = 5, /// REDIRECT
    data = 6, /// DATA
    resend = 11, /// RESEND
    marker = 12, /// MARKER (break/reset)
    control = 14, /// CONTROL
}

/// Data flags of DATA packets.
enum DataFlags : ushort
{
    eof = 0x0040, /// the session ends
    endOfRequest = 0x0800, /// the request ends (pipelining)
    beginPipeline = 0x1000, /// a pipeline begins
    endOfResponse = 0x2000, /// the response ends (23ai)
}

/// Marker types.
enum MarkerType : ubyte
{
    breakCall = 1, /// break
    reset = 2, /// reset
    interrupt = 3, /// interrupt (in-band cancel)
}

/// TNS versions.
enum TnsVersion : ushort
{
    minimum = 300, /// the lowest version offered
    minAccepted = 315, /// 12.1: 4-byte packet lengths, 32-bit SDU; older servers are refused
    withAcceptFlags = 318, /// 18c: accept flags 2
    endOfResponse = 319, /// 23ai: END_OF_RESPONSE
}

/// The size of the packet header, and of the header of a DATA packet (with its flags).
enum size_t packetHeaderSize = 8;
/// ditto
enum size_t dataHeaderSize = 10;
/// Connect data longer than this is sent in a DATA packet after the CONNECT.
enum size_t maxConnectData = 230;
/// The SDU used until the server's is known, and the largest one.
enum uint defaultSdu = 8192;
/// ditto
enum uint maxSdu = 2_097_152;

/// The fields of an ACCEPT packet the client uses.
struct Accept
{
    /// The negotiated TNS version.
    ushort tnsVersion;
    /// Service options (`0x0400`: the server accepts out-of-band breaks).
    ushort options;
    /// The negotiated session data unit (largest packet).
    uint sdu;
    /// NSI flags (`0x10`: the server requires Native Network Encryption).
    ubyte flags0;
    /// ditto
    ubyte flags1;
    /// Accept flags 2 (version 318 and later).
    uint flags2;
}

/// Accept flags 2.
enum AcceptFlags2 : uint
{
    checkOob = 0x00000001, /// the client must check out-of-band breaks
    hasEndOfResponse = 0x02000000, /// responses end with END_OF_RESPONSE
    fastAuth = 0x10000000, /// fast authentication
}

/// NSI flag: the server requires Native Network Encryption or integrity.
enum ubyte nsiNaRequired = 0x10;

/// Packet flags.
enum PacketFlags : ubyte
{
    redirect = 0x04, /// a CONNECT after a REDIRECT; a REDIRECT whose data follows in a DATA packet
    tlsRenegotiate = 0x08, /// a RESEND asking for a TLS renegotiation first
}

/++
Builds a CONNECT packet (and, if the connect data is long, the DATA packet that
follows it). Native Network Encryption is declined (`NA_DISABLED`).
+/
ubyte[][] buildConnect(string connectData, uint sdu, ushort tnsVersion, ubyte flags = 0) @safe pure
{
    import std.algorithm.comparison : min;

    const longData = connectData.length > maxConnectData;
    enum ushort dataOffset = 74;
    ubyte[] p = new ubyte[dataOffset];
    void u16(size_t at, uint v)
    {
        p[at] = cast(ubyte)(v >> 8);
        p[at + 1] = cast(ubyte) v;
    }

    void u32(size_t at, uint v)
    {
        p[at .. at + 4] = [
            cast(ubyte)(v >> 24), cast(ubyte)(v >> 16), cast(ubyte)(v >> 8), cast(ubyte) v
        ];
    }

    p[4] = PacketType.connect;
    p[5] = flags;
    u16(8, tnsVersion);
    u16(10, TnsVersion.minimum);
    u16(12, 0x0001); // service options: don't care
    u16(14, min(sdu, 0xFFFF));
    u16(16, min(sdu, 0xFFFF)); // TDU
    u16(18, 0x4F98); // protocol characteristics
    u16(20, 0); // line turnaround
    u16(22, 1); // value of one (byte order)
    u16(24, cast(uint) connectData.length);
    u16(26, dataOffset);
    p[32] = 0x84; // NSI flags: security renegotiation supported, NA disabled (no NNE)
    p[33] = 0x84;
    u32(58, sdu);
    u32(62, sdu); // TDU
    if (!longData)
        p ~= cast(const(ubyte)[]) connectData;
    u16(0, cast(uint) p.length);
    if (!longData)
        return [p];
    ubyte[] d = new ubyte[dataHeaderSize];
    d[4] = PacketType.data;
    d ~= cast(const(ubyte)[]) connectData;
    d[0] = cast(ubyte)(d.length >> 8);
    d[1] = cast(ubyte) d.length;
    return [p, d];
}

/// Parses the body of an ACCEPT packet (the whole packet, header included).
Accept parseAccept(scope const(ubyte)[] p) @safe pure
{
    if (p.length < 24)
        throw new ProtocolException("Truncated ACCEPT packet");
    uint u16(size_t at)
    {
        return (p[at] << 8) | p[at + 1];
    }

    uint u32(size_t at)
    {
        return (p[at] << 24) | (p[at + 1] << 16) | (p[at + 2] << 8) | p[at + 3];
    }

    Accept a;
    a.tnsVersion = cast(ushort) u16(8);
    a.options = cast(ushort) u16(10);
    a.sdu = u16(12);
    a.flags0 = p[22];
    a.flags1 = p[23];
    if (a.tnsVersion >= TnsVersion.minAccepted && p.length >= 40)
        a.sdu = u32(32);
    if (a.tnsVersion >= TnsVersion.withAcceptFlags && p.length >= 45)
        a.flags2 = u32(41);
    return a;
}

/++
The error of a REFUSE packet: the `(ERR=nnnnn)` number of its text (e.g. 12514
for an unknown service), and the text.
+/
int parseRefuse(scope const(ubyte)[] p, out string text) @safe pure
{
    import std.conv : ConvException, to;
    import std.string : indexOf;

    if (p.length >= 12)
    {
        const n = (p[10] << 8) | p[11];
        const end = 12 + n < p.length ? 12 + n : p.length;
        text = (cast(const(char)[]) p[12 .. end]).idup;
    }
    const at = text.indexOf("(ERR=");
    if (at < 0)
        return 0;
    const close = text.indexOf(')', at);
    try
        return text[at + 5 .. close < 0 ? text.length : close].to!int;
    catch (ConvException)
        return 0;
}

/++
The data of a REDIRECT packet: the new address (a descriptor such as
`(ADDRESS=(PROTOCOL=tcp)(HOST=h)(PORT=1521))`) and the connect data to send
there (empty: send the original). `following` is the DATA packet with the data
when the REDIRECT has the `redirect` flag.
+/
void parseRedirect(scope const(ubyte)[] p, scope const(ubyte)[] following, out string address,
        out string connectData) @safe pure
{
    import std.string : indexOf;

    if (p.length < 10)
        throw new ProtocolException("Truncated REDIRECT packet");
    const n = (p[8] << 8) | p[9];
    const(ubyte)[] data;
    if ((p[5] & PacketFlags.redirect) || p.length < 10 + n)
    {
        if (following.length < dataHeaderSize)
            throw new ProtocolException("The REDIRECT data is missing");
        data = following[dataHeaderSize .. $];
    }
    else
        data = p[10 .. 10 + n];
    const text = (cast(const(char)[]) data).idup;
    const nul = text.indexOf('\0');
    if (nul < 0)
        address = text;
    else
    {
        address = text[0 .. nul];
        connectData = text[nul + 1 .. $];
        while (connectData.length && connectData[$ - 1] == '\0')
            connectData = connectData[0 .. $ - 1];
    }
}

/++
Whether a REDIRECT keeps its data in the following DATA packet (which the caller
then reads before calling `parseRedirect`).
+/
bool redirectDataFollows(scope const(ubyte)[] p) @safe pure nothrow @nogc
{
    if (p.length < 10)
        return false;
    const n = (p[8] << 8) | p[9];
    return (p[5] & PacketFlags.redirect) != 0 || p.length < 10 + n;
}

/// A complete packet as received: type, flags and body (after the 8-byte header).
struct Packet
{
    /// The packet type.
    ubyte type;
    /// Packet flags.
    ubyte flags;
    /// The whole packet, header included.
    immutable(ubyte)[] bytes;
}

/++
Reads and writes TNS packets on a transport. After the handshake, it presents
the payloads of incoming DATA packets as a byte stream (`read`), handling the
break/reset handshake when the server sends a MARKER.
+/
final class TnsStream : Transport
{
    /// The transport the packets travel on.
    Transport transport;
    /// The session data unit: the largest packet.
    uint sdu = defaultSdu;
    /// Whether packet lengths are 4 bytes (negotiated version 315 or later).
    bool largeLengths;
    /// Whether the server marks the end of each response (23ai).
    bool endOfResponse;
    /// Whether a pipeline's responses are read: MARKER packets are skipped (no reset handshake).
    bool inPipeline;

    private immutable(ubyte)[] payload; // the unread part of the current DATA packet
    private bool responseEnded; // a packet with END_OF_RESPONSE was read completely
    private bool breakPending; // a break/reset happened in the current response

    /// Creates a stream over `transport`.
    this(Transport transport) @safe pure nothrow
    {
        this.transport = transport;
    }

    /// Reads one whole packet.
    Packet readPacket() @safe
    {
        ubyte[packetHeaderSize] header;
        readFully(header[]);
        const length = largeLengths ? (header[0] << 24) | (header[1] << 16) | (
                header[2] << 8) | header[3] : (header[0] << 8) | header[1];
        if (length < packetHeaderSize || length > maxSdu + 64)
            throw new ProtocolException("Invalid TNS packet length " ~ toText(length));
        auto bytes = new ubyte[length];
        bytes[0 .. packetHeaderSize] = header[];
        readFully(bytes[packetHeaderSize .. $]);
        return Packet(header[4], header[5], (() @trusted => cast(immutable(ubyte)[]) bytes)());
    }

    /// Writes raw packets (the handshake).
    void writePackets(scope const(ubyte[])[] packets) @safe
    {
        foreach (p; packets)
            transport.write(p);
    }

    /// Sends `data` (a TTC request) in DATA packets of at most `sdu` bytes.
    void sendData(scope const(ubyte)[] data, ushort flags = 0, ushort lastPacketFlags = 0) @safe
    {
        const room = sdu - dataHeaderSize;
        do
        {
            const n = data.length < room ? data.length : room;
            ubyte[] p = new ubyte[dataHeaderSize + n];
            putLength(p);
            p[4] = PacketType.data;
            const f = n == data.length ? flags | lastPacketFlags : flags;
            p[8] = cast(ubyte)(f >> 8);
            p[9] = cast(ubyte) f;
            p[dataHeaderSize .. $] = data[0 .. n];
            transport.write(p);
            data = data[n .. $];
        }
        while (data.length);
        responseEnded = false;
        breakPending = false;
    }

    /// Sends a MARKER packet.
    void sendMarker(MarkerType type) @safe
    {
        ubyte[packetHeaderSize + 3] p;
        putLength(p[]);
        p[4] = PacketType.marker;
        p[8] = 1;
        p[10] = type;
        transport.write(p[]);
    }

    /// Sends an empty DATA packet with the EOF flag (the session ends).
    void sendEof() @safe
    {
        sendData(null, DataFlags.eof);
    }

    /++
    Whether a break/reset happened since the last request: the response then
    continues with the error message (e.g. ORA-01013), and the reader must start
    a new message. Reading clears it.
    +/
    bool takeBreak() @safe pure nothrow @nogc
    {
        const b = breakPending;
        breakPending = false;
        return b;
    }

    /// Bytes of the current DATA packet not read yet.
    @property size_t unread() const @safe pure nothrow @nogc
    {
        return payload.length;
    }

    /// Whether the current DATA payload is consumed and the server marked the response as ended.
    @property bool atEndOfResponse() const @safe pure nothrow @nogc
    {
        return responseEnded && payload.length == 0;
    }

    override size_t read(scope ubyte[] buffer) @safe
    {
        while (payload.length == 0)
            nextDataPacket();
        const n = buffer.length < payload.length ? buffer.length : payload.length;
        buffer[0 .. n] = payload[0 .. n];
        payload = payload[n .. $];
        return n;
    }

    override void write(scope const(ubyte)[] data) @safe
    {
        sendData(data);
    }

    override bool dataAvailable() @safe
    {
        return payload.length > 0 || transport.dataAvailable();
    }

    override void close() @safe nothrow
    {
        transport.close();
    }

    override bool connected() const @safe nothrow
    {
        return transport.connected;
    }

    override void setTimeouts(Duration receive, Duration send) @safe
    {
        transport.setTimeouts(receive, send);
    }

    /// Reads packets until a DATA packet with payload arrives, handling markers and control packets.
    private void nextDataPacket() @safe
    {
        for (;;)
        {
            const p = readPacket();
            switch (p.type)
            {
            case PacketType.data:
                if (p.bytes.length < dataHeaderSize)
                    throw new ProtocolException("Truncated DATA packet");
                const flags = (p.bytes[8] << 8) | p.bytes[9];
                if (flags & DataFlags.eof)
                    throw new ConnectionException("The server closed the session");
                payload = p.bytes[dataHeaderSize .. $];
                if (flags & DataFlags.endOfResponse)
                    responseEnded = true;
                if (payload.length)
                    return;
                break;
            case PacketType.marker:
                if (!inPipeline) // in a pipeline the error follows without the reset handshake
                    reset(p.bytes.length >= 11 ? p.bytes[10] : 0);
                break;
            case PacketType.control:
                control(p.bytes);
                break;
            default:
                throw new ProtocolException("Unexpected TNS packet type " ~ toText(p.type));
            }
        }
    }

    /++
    The reset handshake after a marker from the server: send RESET and, unless
    the marker was the server's RESET already (as after a cancel), skip until
    it comes (a BREAK is followed by a RESET).
    +/
    private void reset(ubyte markerType) @safe
    {
        sendMarker(MarkerType.reset);
        while (markerType != MarkerType.reset)
        {
            const p = readPacket();
            if (p.type == PacketType.marker && p.bytes.length >= 11)
                markerType = p.bytes[10];
        }
        breakPending = true;
        payload = null;
    }

    private void control(scope const(ubyte)[] p) @safe
    {
        if (p.length < 10)
            throw new ProtocolException("Truncated CONTROL packet");
        const type = (p[8] << 8) | p[9];
        if (type == 8 && p.length >= 18) // in-band notification: an error number
        {
            const error = (p[14] << 24) | (p[15] << 16) | (p[16] << 8) | p[17];
            if (error == 12_572 || error == 2396)
                throw new ConnectionException("The server ended the session (TNS-" ~ toText(error) ~ ")");
        }
    }

    private void putLength(scope ubyte[] p) const @safe pure nothrow @nogc
    {
        const n = p.length;
        if (largeLengths)
        {
            p[0] = cast(ubyte)(n >> 24);
            p[1] = cast(ubyte)(n >> 16);
            p[2] = cast(ubyte)(n >> 8);
            p[3] = cast(ubyte) n;
        }
        else
        {
            p[0] = cast(ubyte)(n >> 8);
            p[1] = cast(ubyte) n;
        }
    }

    private void readFully(scope ubyte[] dst) @safe
    {
        size_t got;
        while (got < dst.length)
        {
            const n = transport.read(dst[got .. $]);
            if (n == 0)
                throw new ConnectionException("Connection closed by the server");
            got += n;
        }
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
    const packets = buildConnect("(DESCRIPTION=(CONNECT_DATA=(SERVICE_NAME=X)))", 8192, 318);
    assert(packets.length == 1);
    const p = packets[0];
    assert(p.length == 74 + 45 && p[0] == 0 && p[1] == 119 && p[4] == PacketType.connect);
    assert(p[8 .. 10] == [0x01, 0x3E] && p[24 .. 28] == [0, 45, 0, 74] && p[32] == 0x84);
    assert(cast(const(char)[]) p[74 .. $] == "(DESCRIPTION=(CONNECT_DATA=(SERVICE_NAME=X)))");

    auto longData = buildConnect("(" ~ "x".replicate(300) ~ ")", 8192, 318);
    assert(longData.length == 2 && longData[0].length == 74 && longData[1][4] == PacketType.data);

    string address, data;
    const ubyte[] redirectHead = [0, 0, 0, 0, 5, 0, 0, 0, 0, 9];
    parseRedirect(redirectHead ~ cast(const(ubyte)[]) "(A=1)\0(B)", null, address, data);
    assert(address == "(A=1)" && data == "(B)");
    assert(buildConnect("(X)", 8192, 318, PacketFlags.redirect)[0][5] == PacketFlags.redirect);

    string text;
    const ubyte[] head = [0, 0, 0, 0, 4, 0, 0, 0, 1, 0, 0, 23];
    const refuse = head ~ cast(const(ubyte)[]) "(ERR=12514)(VSNNUM=0)x";
    assert(parseRefuse(refuse, text) == 12_514 && text == "(ERR=12514)(VSNNUM=0)x");
}

private string replicate(string s, size_t n) @safe pure
{
    string r;
    foreach (_; 0 .. n)
        r ~= s;
    return r;
}
