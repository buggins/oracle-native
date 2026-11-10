/++
LOBs (CLOB, NCLOB, BLOB, BFILE) through their locators: length, reading,
writing, trimming, temporary LOBs.

By default query results carry LOB contents as values (`Value.getString`,
`getBytes`); with `ConnectionOptions.lobLocators`, and always for BFILE, they
carry locators, read through `Value.getLob`.

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module oracle.lob;

import oracle.connection : Connection;
import oracle.exception : ClientException, ProtocolException;
import oracle.protocol.messages : FunctionCode, functionHeader;
import oracle.protocol.ttc : TtcReader, TtcWriter;
import oracle.types.typeinfo : CharsetForm, OracleType;

/// LOB operations (LOB_OP function 96).
enum LobOperation : uint
{
    getLength = 0x01, /// the length (bytes or characters)
    read = 0x02, /// read
    trim = 0x20, /// trim to a length
    write = 0x40, /// write at an offset
    getChunkSize = 0x4000, /// the chunk size
    createTemporary = 0x110, /// create a temporary LOB
    freeTemporary = 0x111, /// free a temporary LOB
    fileOpen = 0x100, /// open a BFILE
    fileClose = 0x200, /// close a BFILE
    fileIsOpen = 0x400, /// whether a BFILE is open
    fileExists = 0x800, /// whether a BFILE's file exists
}

/// What a LOB operation sends besides its locator.
struct LobRequest
{
    /// The operation.
    LobOperation operation;
    /// The locator (for a new temporary LOB: a zero-filled buffer of the locator's size).
    const(ubyte)[] locator;
    /// The source offset (1-based; for CREATE_TEMP: the character set form).
    ulong sourceOffset;
    /// The destination offset (for CREATE_TEMP: the LOB type).
    ulong destinationOffset;
    /// The destination length (for CREATE_TEMP: the duration).
    ulong destinationLength;
    /// Whether an amount is sent (and comes back).
    bool withAmount;
    /// The amount: bytes or characters to read, the new length to trim to, a BFILE's open mode.
    ulong amount;
    /// Data to write.
    const(ubyte)[] data;
    /// The character set of a new temporary LOB (0: none sent).
    ushort charset;
    /// The NULL-LOB pointer (CREATE_TEMP and the is-* operations).
    bool nullLobPointer;
}

/// The LOB_OP message.
ubyte[] buildLobOperation(scope const ref LobRequest q, ubyte sequence, ubyte fieldVersion) @safe pure nothrow
{
    TtcWriter w;
    functionHeader(w, FunctionCode.lobOp, sequence, fieldVersion);
    w.u8(1); // source locator
    w.ub(q.locator.length);
    w.u8(0); // destination locator
    w.ub(q.destinationLength);
    w.ub(0); // short source offset
    w.ub(0); // short destination offset
    w.u8(q.charset ? 1 : 0);
    w.u8(0); // short amount
    w.u8(q.nullLobPointer ? 1 : 0);
    w.ub(q.operation);
    w.u8(0); // SCN array
    w.u8(0);
    w.ub(q.sourceOffset);
    w.ub(q.destinationOffset);
    w.u8(q.withAmount ? 1 : 0);
    foreach (_; 0 .. 3)
        w.u16be(0);
    w.bytes(q.locator);
    if (q.charset)
        w.ub(q.charset);
    if (q.data !is null)
    {
        w.u8(14); // LOB_DATA
        w.clr(q.data);
    }
    if (q.withAmount)
        w.ub(q.amount);
    return w.data;
}

/// What a LOB operation returns.
struct LobResponse
{
    /// Data read.
    immutable(ubyte)[] data;
    /// The locator, possibly updated.
    immutable(ubyte)[] locator;
    /// The amount (length, bytes or characters read).
    ulong amount;
    /// The answer of an is-* operation.
    bool flag;
}

/++
A LOB: a locator, with operations that each take a round trip. Get one from
`Value.getLob` or `Connection.createLob`. A LOB fetched in a query can be read
while the query's rows are still being read.

Offsets start at 1; CLOB and NCLOB lengths, offsets and amounts count
characters (UTF-16 code units), BLOB and BFILE ones bytes.
+/
final class Lob
{
    private Connection conn;
    private ulong lease; // the connection's lease it came with (pooled connections)
    private immutable(ubyte)[] locator_;
    private OracleType type_;
    private CharsetForm form;
    private bool freed;

    package this(Connection conn, ulong lease, OracleType type, CharsetForm form, immutable(ubyte)[] locator) @safe
    pure nothrow
    {
        this.conn = conn;
        this.lease = lease;
        this.type_ = type;
        this.form = form;
        this.locator_ = locator;
    }

    /// CLOB (also NCLOB), BLOB or BFILE.
    @property OracleType type() const @safe pure nothrow
    {
        return type_;
    }

    /// Whether it is a national character LOB (NCLOB).
    @property bool isNational() const @safe pure nothrow
    {
        return form == CharsetForm.nchar;
    }

    /// Whether it is a temporary LOB (made by `Connection.createLob`; free it with `free`).
    @property bool isTemporary() const @safe pure nothrow
    {
        return locator_.length > 7 && (locator_[7] & 0x01) != 0;
    }

    /// The locator, as bound in statements.
    @property immutable(ubyte)[] locator() const @safe pure nothrow
    {
        return locator_;
    }

    /// The length: characters for CLOB and NCLOB, bytes for BLOB and BFILE.
    ulong length() @safe
    {
        LobRequest q;
        q.operation = LobOperation.getLength;
        q.withAmount = true;
        return run(q).amount;
    }

    /++
    Reads `amount` bytes (BLOB, BFILE) from `offset` (1-based); all the rest by default.

    Throws: `ClientException` for CLOBs (use `readText`); `ServerException` for server errors.
    +/
    immutable(ubyte)[] read(ulong offset = 1, ulong amount = uint.max) @safe
    {
        if (type_ == OracleType.clob)
            throw new ClientException("Use readText for CLOBs");
        if (type_ != OracleType.bfile)
            return readRaw(offset, amount);
        // a BFILE is opened for the read, unless it is already open
        LobRequest q;
        q.operation = LobOperation.fileIsOpen;
        q.nullLobPointer = true;
        const wasOpen = run(q).flag;
        if (!wasOpen)
        {
            q = LobRequest.init;
            q.operation = LobOperation.fileOpen;
            q.withAmount = true;
            q.amount = 11; // read only
            run(q);
        }
        scope (exit)
            if (!wasOpen)
            {
                LobRequest c;
                c.operation = LobOperation.fileClose;
                run(c);
            }
        return readRaw(offset, amount);
    }

    /++
    Reads `amount` characters of a CLOB or NCLOB from `offset` (1-based); all the rest by default.

    Throws: `ClientException` for BLOBs and BFILEs (use `read`); `ServerException` for server errors.
    +/
    string readText(ulong offset = 1, ulong amount = uint.max) @safe
    {
        if (type_ != OracleType.clob)
            throw new ClientException("Use read for BLOBs and BFILEs");
        return decode(readRaw(offset, amount));
    }

    /++
    Writes bytes to a BLOB at `offset` (1-based), extending it as needed. The
    LOB must be temporary or selected `FOR UPDATE` in a transaction.

    Throws: `ClientException` for CLOBs (use `writeText`) and BFILEs (read-only); `ServerException` for server errors.
    +/
    void write(scope const(ubyte)[] data, ulong offset = 1) @safe
    {
        if (type_ != OracleType.blob)
            throw new ClientException("Write bytes to BLOBs, text to CLOBs with writeText (BFILEs are read-only)");
        writeRaw(data, offset);
    }

    /++
    Writes text to a CLOB or NCLOB at `offset` (1-based, in characters),
    extending it as needed. The LOB must be temporary or selected `FOR
    UPDATE` in a transaction.

    Throws: `ClientException` for BLOBs and BFILEs (use `write`); `ServerException` for server errors.
    +/
    void writeText(scope const(char)[] text, ulong offset = 1) @safe
    {
        if (type_ != OracleType.clob)
            throw new ClientException("Write text to CLOBs, bytes to BLOBs with write (BFILEs are read-only)");
        writeRaw(encode(text), offset);
    }

    /// Shortens the LOB to `newLength` (characters or bytes).
    void trim(ulong newLength) @safe
    {
        LobRequest q;
        q.operation = LobOperation.trim;
        q.withAmount = true;
        q.amount = newLength;
        run(q);
    }

    /// Frees a temporary LOB. Calling it again, or for other LOBs, does nothing.
    void free() @safe
    {
        if (freed || !isTemporary)
            return;
        LobRequest q;
        q.operation = LobOperation.freeTemporary;
        run(q);
        freed = true;
    }

    private immutable(ubyte)[] readRaw(ulong offset, ulong amount) @safe
    {
        LobRequest q;
        q.operation = LobOperation.read;
        q.sourceOffset = offset;
        q.withAmount = true;
        q.amount = amount;
        return run(q).data;
    }

    private void writeRaw(scope const(ubyte)[] data, ulong offset) @safe
    {
        LobRequest q;
        q.operation = LobOperation.write;
        q.sourceOffset = offset;
        q.data = data.length ? data : [];
        run(q);
    }

    private LobResponse run(scope ref LobRequest q) @safe
    {
        if (freed)
            throw new ClientException("The temporary LOB was freed");
        q.locator = locator_;
        auto r = conn.lobOperation(q, lease);
        if (r.locator.length == locator_.length)
            locator_ = r.locator;
        return r;
    }

    /// Whether the LOB's text is UTF-16 (variable-width database character sets, NCLOB), and little-endian.
    private bool utf16() const @safe pure nothrow
    {
        return form == CharsetForm.nchar || (locator_.length > 6 && (locator_[6] & 0x80) != 0);
    }

    private bool littleEndian() const @safe pure nothrow
    {
        return locator_.length > 7 && (locator_[7] & 0x40) != 0;
    }

    private string decode(immutable(ubyte)[] data) const @safe
    {
        import std.utf : UTFException, validate;
        import dbwire.charset.utf16 : decodeUtf16be, decodeUtf16le;

        if (utf16())
            return littleEndian() ? decodeUtf16le(data) : decodeUtf16be(data);
        const s = cast(string) data;
        try
            validate(s);
        catch (UTFException)
            throw new ProtocolException("Invalid UTF-8 text in a CLOB");
        return s;
    }

    private immutable(ubyte)[] encode(scope const(char)[] text) const @safe
    {
        import dbwire.charset.utf16 : encodeUtf16be, encodeUtf16le;

        if (!utf16())
            return cast(immutable(ubyte)[]) text.idup;
        return littleEndian() ? encodeUtf16le(text) : encodeUtf16be(text); // unique results of pure functions
    }
}

///
@safe unittest
{
    // reading 'small clob' as python-oracledb asks for it (a 114-byte locator, from offset 1, all of it)
    LobRequest q;
    q.operation = LobOperation.read;
    q.locator = new ubyte[114];
    q.sourceOffset = 1;
    q.withAmount = true;
    q.amount = uint.max;
    const m = buildLobOperation(q, 0x0E, 24);
    assert(m[0 .. 25] == [
        0x03, 0x60, 0x0E, 0x00, 0x01, 0x01, 0x72, 0, 0, 0, 0, 0, 0, 0, 0x01, 0x02, 0x00, 0x00, 0x01,
        0x01, 0x00,
        0x01, 0, 0, 0
    ]);
    assert(m.length == 28 + 114 + 5 && m[$ - 5 .. $] == [0x04, 0xFF, 0xFF, 0xFF, 0xFF]);

    // creating a temporary CLOB
    LobRequest c;
    c.operation = LobOperation.createTemporary;
    c.locator = new ubyte[40];
    c.destinationLength = 10;
    c.sourceOffset = CharsetForm.implicit;
    c.destinationOffset = OracleType.clob;
    c.charset = 873;
    c.nullLobPointer = true;
    const t = buildLobOperation(c, 0x1F, 24);
    assert(t[4 .. 34] == [
        0x01, 0x01, 0x28, 0x00, 0x01, 0x0A, 0x00, 0x00, 0x01, 0x00, 0x01, 0x02, 0x01, 0x10, 0x00, 0x00,
        0x01, 0x01,
        0x01, 0x70, 0x00, 0, 0, 0, 0, 0, 0, 0, 0, 0
    ]);
    assert(t[$ - 3 .. $] == [0x02, 0x03, 0x69]);
}
