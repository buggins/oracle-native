/++
ROWID values: the physical address of a row (data object number, file, block,
slot), shown as 18 base-64 characters.

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module oracle.types.rowid;

import dbwire.io.buffer : fromBigEndian;
import oracle.exception : ProtocolException;

/++
The text of a ROWID kept as 13 big-endian bytes (u32 object number, u16 file,
a byte, u32 block, u16 slot): `AAAR3sAAEAAAACXAAA`.

Throws: `ProtocolException` if `b` is not 13 bytes long.
+/
string rowidText(scope const(ubyte)[] b) @safe pure
{
    static immutable alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    if (b.length != 13)
        throw new ProtocolException("Invalid ROWID length");
    const ulong objectNumber = fromBigEndian!uint(b[0 .. 4][0 .. 4]);
    const ulong file = fromBigEndian!ushort(b[4 .. 6][0 .. 2]);
    const ulong block = fromBigEndian!uint(b[7 .. 11][0 .. 4]);
    const ulong slot = fromBigEndian!ushort(b[11 .. 13][0 .. 2]);
    char[18] s;
    size_t at;
    void put(ulong v, size_t width)
    {
        foreach (i; 0 .. width)
        {
            s[at + width - 1 - i] = alphabet[v & 63];
            v >>= 6;
        }
        at += width;
    }

    put(objectNumber, 6);
    put(file, 3);
    put(block, 6);
    put(slot, 3);
    return s[].idup;
}

/++
The text of a UROWID: a physical ROWID (first byte 1) in its usual form; a
logical one (e.g. of an index-organized table) as `*` and the base-64 of the
bytes after the first, without padding: `*BAYAABsCwQL+`.

Throws: `ProtocolException` for malformed values.
+/
string urowidText(scope const(ubyte)[] b) @safe pure
{
    import std.base64 : Base64;

    if (b.length == 0)
        throw new ProtocolException("Invalid UROWID");
    if (b[0] == 1)
    {
        if (b.length != 13)
            throw new ProtocolException("Invalid physical UROWID length");
        // object number, file, block, slot: as in a ROWID, which has an extra byte after the file
        return rowidText(b[1 .. 7] ~ cast(const(ubyte)[])[0] ~ b[7 .. 13]);
    }
    auto s = Base64.encode(b[1 .. $]);
    while (s.length && s[$ - 1] == '=')
        s = s[0 .. $ - 1];
    return "*" ~ s.idup;
}

///
@safe unittest
{
    // from Oracle 26ai: rows of an index-organized table
    assert(urowidText([2, 4, 6, 0, 0, 0x1B, 2, 0xC1, 2, 0xFE]) == "*BAYAABsCwQL+");
    assert(urowidText([2, 4, 6, 0, 0, 0x1B, 4, 0xC3, 0x0D, 0x23, 0x39, 0xFE]) == "*BAYAABsEww0jOf4");
}

///
@safe unittest
{
    // object 73196, file 4, block 151, slot 0
    const ubyte[] b = [0, 1, 0x1D, 0xEC, 0, 4, 0, 0, 0, 0, 0x97, 0, 0];
    assert(rowidText(b) == "AAAR3sAAEAAAACXAAA");
}
