/++
The primitive encodings of TTC, the call layer carried inside TNS DATA packets:
universal integers (`ub2`, `ub4`, `ub8` and the signed `sb` forms: a length
byte, then that many big-endian bytes) and length-prefixed byte strings (CLR:
a length byte, or a chunked form for long values).

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module oracle.protocol.ttc;

import dbwire.io.buffer : BufferedReader;
import oracle.exception : ProtocolException;

/// CLR length byte values with a special meaning.
enum ubyte clrNull = 0; /// NULL (also 255)
/// ditto
enum ubyte clrNull2 = 255;
/// ditto
enum ubyte clrChunked = 254; /// chunked: ub4 chunk lengths and chunks, ended by a 0 length

/// Longest value written in one CLR piece, and the chunk size of longer values.
enum size_t clrMaxShort = 252;
/// ditto
enum size_t clrChunkSize = 32_767;

/// Builds a TTC request in memory.
struct TtcWriter
{
    /// The bytes written so far.
    ubyte[] data;

    /// Appends one byte.
    void u8(ubyte b) @safe pure nothrow
    {
        data ~= b;
    }

    /// Appends raw bytes.
    void bytes(scope const(ubyte)[] b) @safe pure nothrow
    {
        data ~= b;
    }

    /// Appends a big-endian u16.
    void u16be(uint v) @safe pure nothrow
    {
        data ~= [cast(ubyte)(v >> 8), cast(ubyte) v];
    }

    /// Appends a little-endian u16 (a few negotiation fields are little-endian).
    void u16le(uint v) @safe pure nothrow
    {
        data ~= [cast(ubyte) v, cast(ubyte)(v >> 8)];
    }

    /// Appends a big-endian u32.
    void u32be(uint v) @safe pure nothrow
    {
        data ~= [cast(ubyte)(v >> 24), cast(ubyte)(v >> 16), cast(ubyte)(v >> 8), cast(ubyte) v];
    }

    /// Appends a universal unsigned integer (`ub2`/`ub4`/`ub8`): a length byte, then 0, 1, 2, 4 or 8 big-endian bytes.
    void ub(ulong v) @safe pure nothrow
    {
        if (v == 0)
            return u8(0);
        const n = v <= 0xFF ? 1 : v <= 0xFFFF ? 2 : v <= 0xFFFF_FFFF ? 4 : 8;
        u8(cast(ubyte) n);
        foreach_reverse (i; 0 .. n)
            u8(cast(ubyte)(v >> (8 * i)));
    }

    /// Appends a universal signed integer (`sb*`): the sign in the high bit of the length byte.
    void sb(long v) @safe pure nothrow
    {
        if (v == 0)
            return u8(0);
        const negative = v < 0;
        const m = negative ? -cast(ulong) v : cast(ulong) v;
        const n = m <= 0xFF ? 1 : m <= 0xFFFF ? 2 : m <= 0xFFFF_FFFF ? 4 : 8;
        u8(cast(ubyte)(n | (negative ? 0x80 : 0)));
        foreach_reverse (i; 0 .. n)
            u8(cast(ubyte)(m >> (8 * i)));
    }

    /// Appends a CLR: short values with a length byte, longer ones chunked; `null` is NULL.
    void clr(scope const(ubyte)[] v) @safe pure nothrow
    {
        if (v.length == 0)
            return u8(clrNull);
        if (v.length <= clrMaxShort)
        {
            u8(cast(ubyte) v.length);
            return bytes(v);
        }
        u8(clrChunked);
        while (v.length)
        {
            const n = v.length < clrChunkSize ? v.length : clrChunkSize;
            ub(n);
            bytes(v[0 .. n]);
            v = v[n .. $];
        }
        ub(0);
    }

    /// Appends a value with two lengths: `ub4` total length (0 = none), then a CLR.
    void bytesWithLength(scope const(ubyte)[] v) @safe pure nothrow
    {
        ub(v.length);
        if (v.length)
            clr(v);
    }

    /// ditto
    void textWithLength(scope const(char)[] v) @safe pure nothrow
    {
        bytesWithLength(cast(const(ubyte)[]) v);
    }
}

/// The longest name, message, locator or other metadata a `TtcReader` reads by default (1 MiB).
enum size_t metadataLimit = 1024 * 1024;

/// Reads TTC primitives; malformed values throw `ProtocolException`.
struct TtcReader
{
    /// The byte stream (the payloads of the DATA packets of a response).
    BufferedReader reader;

    /// Reads one byte.
    ubyte u8() @safe
    {
        return reader.readFixed!ubyte();
    }

    /// Reads `n` raw bytes (a copy).
    immutable(ubyte)[] bytes(size_t n) @safe
    {
        return reader.readExactBytes(n);
    }

    /// Skips `n` bytes.
    void skip(size_t n) @safe
    {
        if (n)
            reader.readExactBytes(n);
    }

    /// Reads a big-endian u16.
    ushort u16be() @safe
    {
        return reader.readFixedBE!ushort();
    }

    /// Reads a little-endian u16.
    ushort u16le() @safe
    {
        return reader.readFixed!ushort();
    }

    /// Reads a big-endian u32.
    uint u32be() @safe
    {
        return reader.readFixedBE!uint();
    }

    /// Reads a universal unsigned integer; `limit` bytes at most (2 for `ub2`, 4 for `ub4`, 8 for `ub8`).
    ulong ub(size_t limit = 8) @safe
    {
        const n = u8();
        if (n == 0)
            return 0;
        if ((n & 0x80) || n > limit)
            throw new ProtocolException("Invalid TTC integer length " ~ toText(n));
        ulong v;
        foreach (_; 0 .. n)
            v = (v << 8) | u8();
        return v;
    }

    /// `ub` for 2-, 4- and 8-byte fields.
    ushort ub2() @safe
    {
        return cast(ushort) ub(2);
    }

    /// ditto
    uint ub4() @safe
    {
        return cast(uint) ub(4);
    }

    /// ditto
    ulong ub8() @safe
    {
        return ub(8);
    }

    /// Reads a universal signed integer.
    long sb(size_t limit = 8) @safe
    {
        const n = u8();
        if (n == 0)
            return 0;
        const len = n & 0x7F;
        if (len > limit)
            throw new ProtocolException("Invalid TTC integer length " ~ toText(len));
        ulong v;
        foreach (_; 0 .. len)
            v = (v << 8) | u8();
        return (n & 0x80) ? -cast(long) v : cast(long) v;
    }

    /++
    Reads a CLR; `null` for NULL. Values longer than `maxLength` bytes are
    refused; the default suits names, messages and locators (column values
    pass `ConnectionOptions.maxValueLength`).

    Throws: `ProtocolException` for malformed or too long values.
    +/
    immutable(ubyte)[] clr(size_t maxLength = metadataLimit) @safe
    {
        const n = u8();
        if (n == clrNull || n == clrNull2)
            return null;
        if (n != clrChunked)
            return bytes(n);
        ubyte[] result;
        for (;;)
        {
            const chunk = ub4();
            if (chunk == 0)
                break;
            if (result.length + chunk > maxLength)
                throw new ProtocolException("A value longer than " ~ toText(maxLength) ~ " bytes");
            result ~= bytes(chunk);
        }
        return (() @trusted => cast(immutable(ubyte)[]) result)(); // unique: built here
    }

    /// Reads a value with two lengths: `ub4` total length (0 = none), then a CLR (at most `maxLength` bytes).
    immutable(ubyte)[] bytesWithLength(size_t maxLength = metadataLimit) @safe
    {
        return ub4() == 0 ? null : clr(maxLength);
    }

    /// ditto, as text
    string textWithLength() @safe
    {
        return cast(string) bytesWithLength();
    }

    /// Reads a NUL-terminated string.
    string cstring(size_t maxLength = 4096) @safe
    {
        char[] s;
        for (;;)
        {
            const c = u8();
            if (c == 0)
                break;
            if (s.length == maxLength)
                throw new ProtocolException("Unterminated string");
            s ~= cast(char) c;
        }
        return (() @trusted => cast(string) s)(); // unique: built here
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
    import dbwire.io.mock : MockTransport;

    TtcWriter w;
    w.ub(0);
    w.ub(200);
    w.ub(0x1234);
    w.ub(0x1_0000);
    w.sb(-5);
    w.clr(cast(const(ubyte)[]) "abc");
    w.clr(null);
    assert(w.data == [0, 1, 200, 2, 0x12, 0x34, 4, 0, 1, 0, 0, 0x81, 5, 3, 'a', 'b', 'c', 0]);

    auto big = new ubyte[40_000];
    big[$ - 1] = 7;
    w.clr(big); // chunked: 32767 + 7233
    auto t = new MockTransport;
    t.feed(w.data);
    auto r = TtcReader(new BufferedReader(t));
    assert(r.ub4() == 0 && r.ub4() == 200 && r.ub2() == 0x1234 && r.ub4() == 0x1_0000 && r.sb() == -5);
    assert(r.clr() == "abc" && r.clr() is null);
    const got = r.clr();
    assert(got.length == 40_000 && got[$ - 1] == 7);
}

@safe unittest
{
    import std.exception : assertThrown;
    import dbwire.io.mock : MockTransport;

    auto t = new MockTransport;
    t.feed([3, 1, 2, 3]); // a 3-byte value for a ub2
    auto r = TtcReader(new BufferedReader(t));
    assertThrown!ProtocolException(r.ub2());
}

// A chunked CLR longer than the limit (by default metadataLimit) is refused before its data is read
@safe unittest
{
    import std.exception : assertThrown;
    import dbwire.io.mock : MockTransport;

    auto t = new MockTransport;
    t.feed([0xFE, 0x04, 0x00, 0x10, 0x00, 0x01]); // chunked: one chunk of 1 MiB + 1 bytes, none sent
    auto r = TtcReader(new BufferedReader(t));
    assertThrown!ProtocolException(r.clr());
}
