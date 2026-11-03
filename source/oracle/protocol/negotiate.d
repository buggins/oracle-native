/++
The TTC session setup before authentication: the protocol message (server
banner, character sets, capabilities) and the data-type message (the client's
capabilities and the representation it wants for each data type).

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module oracle.protocol.negotiate;

import oracle.exception : ProtocolException;
import oracle.protocol.ttc : TtcReader, TtcWriter;

/// TTC message types.
enum MessageType : ubyte
{
    protocol = 1, /// protocol negotiation
    dataTypes = 2, /// data-type negotiation
    function_ = 3, /// a function call (client)
    error = 4, /// error / end-of-call status
    rowHeader = 6, /// row header
    rowData = 7, /// row data
    parameter = 8, /// key/value parameters
    status = 9, /// call status
    ioVector = 11, /// PL/SQL bind directions
    lobData = 14, /// LOB data
    warning = 15, /// warning
    describeInfo = 16, /// column metadata
    piggyback = 17, /// piggyback call (client)
    flushOutBinds = 19, /// flush out binds
    bitVector = 21, /// duplicate-column bit vector
    serverSidePiggyback = 23, /// server piggyback
    implicitResultSet = 27, /// implicit results
    renegotiate = 28, /// renegotiate
    endOfResponse = 29, /// end of response (23ai)
}

/// TTC field versions: which message fields a release knows (the negotiated value is min(client, server)).
enum TtcFieldVersion : ubyte
{
    v11_2 = 6, /// 11.2
    v12_1 = 7, /// 12.1
    v12_2 = 8, /// 12.2
    v12_2_ext1 = 9, /// 12.2, extension 1
    v18_1 = 10, /// 18.1
    v18_1_ext1 = 11, /// 18.1, extension 1
    v19_1 = 12, /// 19.1
    v19_1_ext1 = 13, /// 19.1, extension 1
    v20_1 = 14, /// 20.1: two more ERROR fields
    v20_1_ext1 = 15, /// 20.1, extension 1
    v21_1 = 16, /// 21.1: native JSON
    v23_1 = 17, /// 23.1: column domains, native BOOLEAN
    v23_1_ext1 = 18, /// 23.1, extension 1: a token number in every function header
    v23_1_ext2 = 19, /// 23.1, extension 2
    v23_1_ext3 = 20, /// 23.1, extension 3: column annotations
    v23_1_ext4 = 21, /// 23.1, extension 4
    v23_1_ext5 = 22, /// 23.1, extension 5
    v23_3_ext6 = 23, /// 23.3, extension 6
    v23_4 = 24, /// 23.4: VECTOR metadata
}

/// The TTC field version this client implements.
enum ubyte clientFieldVersion = TtcFieldVersion.v23_4;

/// Character set IDs.
enum CharsetId : ushort
{
    al32utf8 = 873, /// UTF-8 (the client's character set)
    al16utf16 = 2000, /// UTF-16 big-endian (the usual national character set)
}

/// What the server told about itself in the protocol message.
struct ServerInfo
{
    /// The server's banner, e.g. "x86_64/Linux 2.4.xx".
    string banner;
    /// The database and national character sets.
    ushort charset;
    /// ditto
    ushort ncharset;
    /// The server's compile-time and run-time capabilities.
    immutable(ubyte)[] compileCaps;
    /// ditto
    immutable(ubyte)[] runtimeCaps;
}

/// The protocol message: protocol version 6 (8.1 and later), then the driver name.
ubyte[] buildProtocolMessage(string driverName) @safe pure
{
    TtcWriter w;
    w.bytes([MessageType.protocol, 6, 0]);
    w.bytes(cast(const(ubyte)[]) driverName);
    w.u8(0);
    return w.data;
}

/// Reads the server's answer to the protocol message.
ServerInfo readProtocolResponse(ref TtcReader r) @safe
{
    if (r.u8() != MessageType.protocol)
        throw new ProtocolException("Expected the protocol message");
    ServerInfo s;
    r.u8(); // server protocol version
    r.u8();
    s.banner = r.cstring();
    s.charset = r.u16le();
    r.u8(); // server flags
    const elements = r.u16le();
    r.skip(5 * elements);
    const fdo = r.bytes(r.u16be());
    // the national character set is in the FDO, after a variable-length part
    if (fdo.length >= 7)
    {
        const at = 6 + fdo[5] + fdo[6] + 3;
        if (at + 2 <= fdo.length)
            s.ncharset = cast(ushort)((fdo[at] << 8) | fdo[at + 1]);
    }
    s.compileCaps = r.clr();
    s.runtimeCaps = r.clr();
    return s;
}

/// Indexes into the compile-time capability array.
enum Cap : size_t
{
    sqlVersion = 0, /// SQL version
    logonTypes = 4, /// supported logon types
    fieldVersion = 7, /// TTC field version
    ttc1 = 15, /// TTC1 flags
    oci1 = 16, /// OCI1 flags
    tdsVersion = 17, /// TDS version
    rpcVersion = 18, /// RPC version
    rpcSignature = 19, /// RPC signature
    dbfVersion = 21, /// DBF version
    lob = 23, /// LOB flags
    ttc2 = 26, /// TTC2 flags
    ub2Dty = 27, /// UB2 data types
    clientFunctions = 34, /// client functions
    oci3 = 35, /// OCI3 flags
    ttc3 = 37, /// TTC3 flags
    sessionSignature = 39, /// session signature version
    ttc4 = 40, /// TTC4 flags
    lob2 = 42, /// LOB2 flags
    ttc5 = 44, /// TTC5 flags
    vectorFeatures = 52, /// VECTOR features
}

/// The client's compile-time capabilities.
immutable(ubyte)[] clientCompileCaps() @safe pure nothrow
{
    auto c = new ubyte[55];
    c[Cap.sqlVersion] = 6;
    c[Cap.logonTypes] = 0x08 | 0x02 | 0x20 | 0x40 | 0x80; // O5LOGON, O5LOGON_NP, O7LOGON, long identifiers and passwords
    c[Cap.fieldVersion] = clientFieldVersion;
    c[8] = 1;
    c[9] = 1;
    c[Cap.ttc1] = 0x20 | 0x01 | 0x08; // fast bit vector, end-of-call status, indicator record
    c[Cap.tdsVersion] = 3;
    c[Cap.rpcVersion] = 7;
    c[Cap.rpcSignature] = 3;
    c[Cap.dbfVersion] = 1;
    c[Cap.lob] = 0x01 | 0x02 | 0x04 | 0x08 | 0x40 | 0x80; // ub8 sizes, encodings, prefetch, temp size, prefetch length, 12c
    c[Cap.ttc2] = 0x04; // zero-length non-pointer
    c[Cap.ub2Dty] = 1;
    c[Cap.clientFunctions] = 12;
    c[Cap.oci3] = 0x20;
    c[Cap.ttc3] = 0x10 | 0x20 | 0x80 | 0x08; // implicit results, big CLR chunks, keep out of order, LTXID
    c[Cap.sessionSignature] = 8;
    c[Cap.ttc4] = 0x04 | 0x40; // in-band notifications, explicit boundary
    c[Cap.lob2] = 0x01 | 0x04;
    c[Cap.oci1] = 0x10; // session state propagation: end-to-end attributes apply; ERROR and STATUS carry a sequence number
    c[Cap.ttc5] = 0x08; // VECTOR
    c[Cap.vectorFeatures] = 0x01 | 0x02; // BINARY and sparse vectors
    return (() @trusted => cast(immutable(ubyte)[]) c)();
}

/// The client's run-time capabilities.
immutable(ubyte)[] clientRuntimeCaps() @safe pure nothrow
{
    auto c = new ubyte[13];
    c[0] = 2; // compatible with 8.1
    c[6] = 0x01 | 0x04; // zero copy, 32 KB strings
    return (() @trusted => cast(immutable(ubyte)[]) c)();
}

/// The internal type of column describe information (user-defined structure).
private enum ushort udsType = 663;

/// Data-type representations.
enum Representation : ushort
{
    native = 0, /// the client's native form
    universal = 1, /// the universal (network) form
    oracle = 10, /// Oracle's own form (NUMBER, DATE)
}

/++
The data types the client accepts unchanged, in the universal representation.
Many are internal TTC types the server uses in its own messages: without
them it fails the first call after the negotiation.

Generated: the types Oracle AI Database 26ai Free (23.26.3) accepts with an
identity conversion, in the order of its answer to a request listing every
type number from 1 to 1023 that way (27 is in `conversions` instead). Older
servers ignore the types they don't know.
+/
private immutable ushort[] identityTypes = [
    1, 8, 23, 24, 25, 26, 28, 29, 30, 31, 32, 33, 10, 11, 40, 41, 117, 120, 290, 291, 292, 293, 294,
    298, 299,
    300, 301, 302, 303, 305, 306, 307, 308, 309, 310, 311, 312, 313, 315, 316, 317, 318, 319, 320, 321,
    322, 323,
    327, 328, 329, 331, 333, 339, 340, 341, 342, 343, 344, 345, 346, 348, 349, 354, 355, 359, 363, 380,
    381, 382,
    384, 385, 386, 387, 388, 389, 390, 391, 393, 394, 395, 396, 397, 398, 399, 400, 401, 404, 405, 406,
    407, 413,
    414, 415, 416, 417, 418, 419, 420, 421, 422, 423, 424, 425, 426, 427, 429, 430, 431, 432, 433, 449,
    450, 454,
    455, 456, 457, 458, 459, 460, 461, 462, 463, 466, 467, 468, 469, 470, 471, 472, 473, 474, 475, 476,
    477, 478,
    479, 480, 481, 482, 483, 484, 485, 486, 490, 491, 492, 493, 494, 495, 496, 498, 499, 500, 501, 502,
    509, 510,
    513, 514, 516, 517, 518, 519, 520, 521, 522, 523, 524, 525, 526, 527, 528, 529, 530, 531, 532, 533,
    534, 535,
    536, 537, 538, 539, 543, 544, 545, 546, 547, 548, 549, 550, 551, 552, 553, 554, 555, 556, 557, 558,
    559, 560,
    561, 562, 563, 564, 566, 567, 568, 569, 570, 571, 572, 573, 574, 575, 576, 577, 578, 579, 580, 581,
    582, 583,
    584, 585, 586, 587, 588, 589, 590, 591, 592, 593, 594, 595, 596, 597, 598, 599, 600, 601, 602, 603,
    604, 605,
    611, 612, 613, 614, 615, 616, 617, 621, 622, 623, 624, 625, 626, 627, 628, 629, 630, 631, 632, 633,
    634, 635,
    636, 637, 638, 639, 640, 641, 642, 643, 644, 645, 646, 647, 648, 649, 650, 651, 652, 653, 655, 656,
    657, 658,
    659, 660, 661, 662, 664, 665, 666, 668, 669, 670, 96, 100, 101, 102, 106, 109, 111, 112, 113, 114,
    119, 127,
    146, 147, 178, 179, 180, 181, 182, 183, 208, 231, 233, 252, 515,
];

/// A data type the client wants converted (or in another representation): type, conversion, representation.
private struct Conversion
{
    ushort type, to, representation;
}

/++
NUMBER, DATE and internal type 27 in Oracle's representation (with the
universal one, signed one-byte fields such as a column's scale come as
length-prefixed integers); types the server has no identity conversion for,
mapped to their base type. Listed before `identityTypes`, which also has 27:
the first entry counts.
+/
private immutable Conversion[] conversions = [
    {2, 2, Representation.oracle}, // NUMBER
    {3, 2, Representation.oracle}, // INTEGER
    {4, 2, Representation.oracle}, // FLOAT
    {6, 2, Representation.oracle}, // VARNUM
    {7, 2, Representation.oracle}, // packed decimal
    {68, 2, Representation.oracle}, // unsigned integer
    {91, 2, Representation.oracle}, // display number
    {152, 2, Representation.oracle},
    {153, 2, Representation.oracle},
    {154, 2, Representation.oracle},
    {172, 2, Representation.oracle},
    {12, 12, Representation.oracle}, // DATE
    {27, 27, Representation.oracle}, // one-byte fields of messages (e.g. scale in describe information) as raw bytes
    {156, 12, Representation.oracle},
    {184, 12, Representation.oracle},
    {5, 1, Representation.universal}, // NUL-terminated string → VARCHAR
    {9, 1, Representation.universal}, // VARCHAR (length-prefixed) → VARCHAR
    {15, 1, Representation.universal},
    {155, 1, Representation.universal},
    {94, 1, Representation.universal}, // LONG VARCHAR
    {95, 23, Representation.universal}, // LONG VARRAW → RAW
    {97, 96, Representation.universal}, // CHARZ → CHAR
    {104, 11, Representation.universal}, // ROWID descriptor → ROWID
    {108, 109, Representation.universal},
    {110, 111, Representation.universal},
    {116, 102, Representation.universal},
    {195, 112, Representation.universal}, // CLOB
    {196, 113, Representation.universal}, // BLOB
    {197, 114, Representation.universal}, // BFILE
    {232, 231, Representation.universal}, // TIMESTAMP WITH LOCAL TIME ZONE
    {241, 109, Representation.universal},
];

/// The data-type message: character sets (AL32UTF8 for both), capabilities, data types.
ubyte[] buildDataTypesMessage() @safe pure
{
    TtcWriter w;
    w.u8(MessageType.dataTypes);
    w.u16le(CharsetId.al32utf8);
    w.u16le(CharsetId.al32utf8);
    w.u8(0x01 | 0x02); // multibyte, conversion lengths
    w.clr(clientCompileCaps());
    w.clr(clientRuntimeCaps());
    void entry(ushort type, ushort to, ushort representation)
    {
        w.u16be(type);
        w.u16be(to);
        w.u16be(representation);
        w.u16be(0);
    }

    foreach (c; conversions)
        entry(c.type, c.to, c.representation);
    foreach (t; identityTypes)
        entry(t, t, Representation.universal);
    // the describe-information structure (UDS): a server answers its identity question without it, but
    // describes columns with the fields of the negotiated field version (23.1 domains, annotations,
    // VECTOR metadata) only to clients that list it
    entry(udsType, udsType, Representation.universal);
    w.u16be(0);
    return w.data;
}

/// Reads the server's answer to the data-type message.
void readDataTypesResponse(ref TtcReader r) @safe
{
    if (r.u8() != MessageType.dataTypes)
        throw new ProtocolException("Expected the data-type message");
    for (;;)
    {
        const type = r.u16be();
        if (type == 0)
            break;
        const conversion = r.u16be();
        if (conversion != 0)
            r.skip(4);
    }
}

///
@safe unittest
{
    assert(buildProtocolMessage("d") == [1, 6, 0, 'd', 0]);
    const dt = buildDataTypesMessage();
    assert(dt[0 .. 6] == [2, 0x69, 0x03, 0x69, 0x03, 3] && dt[6] == 55 && dt[$ - 2 .. $] == [0, 0]);
    assert(clientCompileCaps()[Cap.fieldVersion] == 24 && dt.length > 8 * 300);
}
