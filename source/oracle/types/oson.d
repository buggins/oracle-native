/++
OSON: Oracle's binary JSON, as JSON columns (21c) arrive.

An OSON image starts with the bytes `FF 4A 5A`, a version (1, or 3 with field
names longer than 255 bytes) and big-endian flags, then the sizes of its
segments: the field names (short ones, then long ones), and the tree of
nodes. A scalar image has only the tree size before its single node.

Nodes start with a type byte. Containers have its high bit set: bit 6 tells
an array from an object, bits 3–4 the width of the child count (or, for an
object, that it shares the field IDs of another object found at an offset),
and bit 5 the width of the child offsets. Objects list the field IDs of their
children (1-based indexes into the field names), then the offsets; arrays
only the offsets. Offsets count from the start of the tree, or from the
container itself in relative mode. Scalars are NULL, true, false, strings
(short ones with the length in the type byte), NUMBERs (short ones with the
length in the type byte), BINARY_FLOAT/DOUBLE, DATE, TIMESTAMP (with time
zone), INTERVAL DAY TO SECOND, RAW, IDs, and extended types such as VECTOR.

`osonToText` gives the JSON text as the server's `JSON_SERIALIZE` writes it:
dates and timestamps in ISO 8601 (`2024-01-31T12:00:00.500000+02:30`),
intervals as ISO 8601 durations (`P1DT2H3M4.500000S`), RAW in upper-case
hexadecimal, NUMBERs exactly.

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module oracle.types.oson;

import oracle.exception : ClientException, ProtocolException;

/++
The JSON text of an OSON image.

Throws: `ProtocolException` for malformed images; `ClientException` for node
types this client can't show yet.
+/
string osonToText(immutable(ubyte)[] image) @safe
{
    auto d = OsonDecoder(image);
    d.readHeader();
    return d.text();
}

/// Whether `image` starts like an OSON image.
bool isOson(scope const(ubyte)[] image) @safe pure nothrow @nogc
{
    return image.length >= 4 && image[0] == 0xFF && image[1] == 0x4A && image[2] == 0x5A;
}

private struct OsonDecoder
{
    immutable(ubyte)[] data;
    size_t pos;
    size_t tree; // where the tree segment starts
    bool relativeOffsets;
    size_t fieldIdWidth;
    string[] names;
    bool scalar;
    char[] output;
    uint depth;

    this(immutable(ubyte)[] data) @safe pure nothrow
    {
        this.data = data;
    }

    void readHeader() @safe
    {
        if (!isOson(data))
            throw new ProtocolException("Not an OSON image");
        pos = 3;
        const ver = u8();
        if (ver != 1 && ver != 3)
            throw new ClientException("OSON version " ~ toText(ver) ~ " is not supported");
        const flags = u16();
        relativeOffsets = (flags & 0x01) != 0;
        if (flags & 0x10) // a scalar: just the tree size before the node
        {
            scalar = true;
            if (flags & 0x1000)
                u32();
            else
                u16();
            tree = pos;
            return;
        }
        uint shortCount;
        if (flags & 0x08)
        {
            shortCount = u32();
            fieldIdWidth = 4;
        }
        else if (flags & 0x0400)
        {
            shortCount = u16();
            fieldIdWidth = 2;
        }
        else
        {
            shortCount = u8();
            fieldIdWidth = 1;
        }
        const shortOffsetWidth = flags & 0x0800 ? 4 : 2;
        const shortSegment = shortOffsetWidth == 4 ? u32() : u16();
        uint longCount, longSegment;
        size_t longOffsetWidth;
        if (ver == 3)
        {
            const secondary = u16();
            longOffsetWidth = secondary & 0x0100 ? 2 : 4;
            longCount = u32();
            longSegment = u32();
        }
        if (flags & 0x1000)
            u32(); // tree segment size
        else
            u16();
        u16(); // number of tiny nodes
        if (shortCount + cast(ulong) longCount > data.length)
            throw new ProtocolException("Invalid OSON field name count");
        names = new string[shortCount + longCount];
        readNames(names[0 .. shortCount], 1, shortOffsetWidth, shortSegment);
        readNames(names[shortCount .. $], 2, longOffsetWidth, longSegment);
        tree = pos;
    }

    /// Field names: hash IDs (`hashWidth` bytes each), offsets, then the names (each after its length).
    void readNames(string[] result, size_t hashWidth, size_t offsetWidth, uint segmentSize) @safe
    {
        if (result.length == 0)
            return;
        skip(result.length * hashWidth);
        const offsets = pos;
        skip(result.length * offsetWidth);
        const segment = take(segmentSize);
        const end = pos;
        pos = offsets;
        foreach (ref name; result)
        {
            const offset = offsetWidth == 4 ? u32() : u16();
            const lengthWidth = hashWidth; // short names: 1-byte lengths; long ones: 2 bytes
            if (offset + lengthWidth > segment.length)
                throw new ProtocolException("Invalid OSON field name offset");
            const length = lengthWidth == 1 ? segment[offset] : (segment[offset] << 8) | segment[offset + 1];
            if (offset + lengthWidth + length > segment.length)
                throw new ProtocolException("Invalid OSON field name length");
            name = cast(string) segment[offset + lengthWidth .. offset + lengthWidth + length];
        }
        pos = end;
    }

    string text() @safe
    {
        node();
        return (() @trusted => cast(string) output)();
    }

    void node() @safe
    {
        const type = u8();
        if (type & 0x80)
            return container(type);
        switch (type)
        {
        case 0x30:
            return put("null");
        case 0x31:
            return put("true");
        case 0x32:
            return put("false");
        case 0x33:
            return quoted(cast(string) take(u8()));
        case 0x37:
            return quoted(cast(string) take(u16()));
        case 0x38:
            return quoted(cast(string) take(u32()));
        case 0x34:
            return number(take(u8()));
        case 0x36:
            return floating(take(8), false);
        case 0x7F:
            return floating(take(4), true);
        case 0x3C: // DATE
        case 0x7D: // TIMESTAMP without fraction
            return dateTime(take(7), false);
        case 0x39: // TIMESTAMP
            return dateTime(take(11), false);
        case 0x7C: // TIMESTAMP WITH TIME ZONE
            return dateTime(take(13), true);
        case 0x3E:
            return dayToSecond(take(11));
        case 0x3A:
            return hex(take(u16()));
        case 0x3B:
            return hex(take(u32()));
        case 0x7E: // an ID (e.g. of a document)
            return hex(take(u8()));
        case 0x7B:
            const extended = u8();
            if (extended == 0x01)
                return vector(take(u32()));
            throw new ClientException("OSON extended type " ~ toText(extended) ~ " is not supported yet");
        case 0x3D:
            throw new ClientException("INTERVAL YEAR TO MONTH values in JSON are not supported yet");
        default:
            break;
        }
        if ((type & 0xF0) == 0x20 || (type & 0xF0) == 0x60) // NUMBER, its length - 1 in the type
            return number(take((type & 0x0F) + 1));
        if ((type & 0xF0) == 0x40 || (type & 0xF0) == 0x50) // an integer NUMBER, its length in the type
            return number(take(type & 0x0F));
        if ((type & 0xE0) == 0) // a string up to 31 bytes, its length in the type
            return quoted(cast(string) take(type));
        throw new ClientException("OSON node type " ~ toText(type) ~ " is not supported yet");
    }

    void container(ubyte type) @safe
    {
        if (++depth > 1000)
            throw new ProtocolException("OSON nesting too deep");
        scope (exit)
            depth--;
        const isObject = (type & 0x40) == 0;
        const start = pos - 1 - tree; // the container's own offset
        size_t count, fieldIds, offsets;
        if ((type & 0x18) == 0x18) // an object sharing the field IDs of another one
        {
            if (!isObject)
                throw new ProtocolException("An OSON array with shared field IDs");
            const shared_ = offset(type);
            offsets = pos;
            pos = position(shared_);
            count = childCount(u8());
            fieldIds = pos;
        }
        else
        {
            count = childCount(type);
            fieldIds = pos;
            offsets = isObject ? pos + fieldIdWidth * count : pos;
        }
        if (count > data.length)
            throw new ProtocolException("Invalid OSON child count");
        put(isObject ? "{" : "[");
        foreach (i; 0 .. count)
        {
            if (i)
                put(",");
            if (isObject)
            {
                pos = fieldIds;
                const id = fieldIdWidth == 1 ? u8() : fieldIdWidth == 2 ? u16() : u32();
                fieldIds = pos;
                if (id == 0 || id > names.length)
                    throw new ProtocolException("Invalid OSON field ID " ~ toText(id));
                quoted(names[id - 1]);
                put(":");
            }
            pos = offsets;
            size_t child = offset(type);
            if (relativeOffsets)
                child += start;
            offsets = pos;
            pos = position(child);
            node();
        }
        put(isObject ? "}" : "]");
    }

    /// The child count, its width given by bits 3–4 of a container's type.
    size_t childCount(ubyte type) @safe
    {
        switch (type & 0x18)
        {
        case 0x00:
            return u8();
        case 0x08:
            return u16();
        case 0x10:
            return u32();
        default:
            throw new ProtocolException("Invalid OSON child count width");
        }
    }

    /// An offset into the tree, 4 bytes wide if bit 5 of the container's type is set, else 2.
    size_t offset(ubyte type) @safe
    {
        return type & 0x20 ? u32() : u16();
    }

    size_t position(size_t treeOffset) @safe
    {
        if (tree + treeOffset >= data.length)
            throw new ProtocolException("Invalid OSON offset");
        return tree + treeOffset;
    }

    /// A NUMBER: plain with up to 40 digits before and after the point, else `1.5E-40`.
    void number(scope const(ubyte)[] b) @safe
    {
        import oracle.types.number : decodeNumber;

        const d = decodeNumber(b);
        const n = cast(int) d.digits.length;
        if (d.infinite || n == 0 || (d.pointPosition <= 40 && n - d.pointPosition <= 40))
            return put(d.toString());
        const exponent = d.pointPosition - 1;
        put((d.negative ? "-" : "") ~ d.digits[0 .. 1] ~ (n > 1 ? "." ~ d.digits[1 .. $] : "") ~ "E"
                ~ (exponent < 0 ? "-" : "+") ~ toText(exponent < 0 ? -exponent : exponent));
    }

    void floating(scope const(ubyte)[] b, bool single) @safe
    {
        import oracle.types.floats : decodeBinaryFloat, floatText;

        const v = decodeBinaryFloat(b);
        const s = floatText(v, single);
        put(s == "Nan" || s == "Inf" || s == "-Inf" ? "\"" ~ s ~ "\"" : s);
    }

    void dateTime(scope const(ubyte)[] b, bool zoned) @safe
    {
        import std.format : format;
        import oracle.types.temporal : decodeDateTime, decodeZone, hasLocalTime, localDateTime;

        auto d = decodeDateTime(b);
        string suffix;
        if (zoned)
        {
            const zone = decodeZone(b);
            if (hasLocalTime(zone))
                d = localDateTime(d, zone);
            suffix = zone.text;
        }
        auto s = format("%04d-%02d-%02dT%02d:%02d:%02d", d.year, d.month, d.day, d.hour, d.minute, d.second);
        if (b.length > 7)
            s ~= format(".%06d", d.nanoseconds / 1000);
        quoted(s ~ suffix);
    }

    void dayToSecond(scope const(ubyte)[] b) @safe
    {
        import std.format : format;
        import oracle.types.temporal : decodeDayToSecond;

        const d = decodeDayToSecond(b);
        const negative = d.days < 0 || d.hours < 0 || d.minutes < 0 || d.seconds < 0 || d.nanoseconds < 0;
        int abs(int v)
        {
            return v < 0 ? -v : v;
        }

        quoted(format("%sP%dDT%dH%dM%d.%06dS", negative ? "-" : "", abs(d.days), abs(d.hours), abs(d.minutes),
                abs(d.seconds), abs(d.nanoseconds) / 1000));
    }

    void hex(scope const(ubyte)[] b) @safe
    {
        static immutable digits = "0123456789ABCDEF";
        auto s = new char[b.length * 2];
        foreach (i, x; b)
        {
            s[2 * i] = digits[x >> 4];
            s[2 * i + 1] = digits[x & 15];
        }
        quoted((() @trusted => cast(string) s)());
    }

    void vector(immutable(ubyte)[] b) @safe
    {
        import oracle.types.vector : decodeVector;

        put(decodeVector(b).toString());
    }

    /// A JSON string: quotes, backslash escapes for `"`, `\` and control characters.
    void quoted(string s) @safe
    {
        static immutable digits = "0123456789abcdef";
        output ~= '"';
        foreach (char c; s)
        {
            switch (c)
            {
            case '"':
                output ~= `\"`;
                break;
            case '\\':
                output ~= `\\`;
                break;
            case '\n':
                output ~= `\n`;
                break;
            case '\r':
                output ~= `\r`;
                break;
            case '\t':
                output ~= `\t`;
                break;
            case '\b':
                output ~= `\b`;
                break;
            case '\f':
                output ~= `\f`;
                break;
            default:
                if (c < 0x20)
                {
                    output ~= `\u00`;
                    output ~= digits[c >> 4];
                    output ~= digits[c & 15];
                }
                else
                    output ~= c;
            }
        }
        output ~= '"';
    }

    void put(scope const(char)[] s) @safe pure nothrow
    {
        output ~= s;
    }

    ubyte u8() @safe
    {
        return take(1)[0];
    }

    uint u16() @safe
    {
        const b = take(2);
        return (b[0] << 8) | b[1];
    }

    uint u32() @safe
    {
        const b = take(4);
        return (cast(uint) b[0] << 24) | (b[1] << 16) | (b[2] << 8) | b[3];
    }

    void skip(size_t n) @safe
    {
        take(n);
    }

    immutable(ubyte)[] take(size_t n) @safe
    {
        if (n > data.length - pos)
            throw new ProtocolException("Truncated OSON image");
        auto b = data[pos .. pos + n];
        pos += n;
        return b;
    }
}

private string toText(T)(T v) @safe pure
{
    import std.conv : to;

    return v.to!string;
}

@safe unittest
{
    import std.exception : assertThrown;

    // images sent by 23ai: an object (relative offsets, four short field names), an array
    immutable ubyte[] object = [
        0xFF, 0x4A, 0x5A, 0x01, 0x21, 0x06, 0x04, 0x00, 0x08, 0x00, 0x24, 0x00, 0x00, 0x2C,
        0x52, 0x73, 0xE5, 0x00, 0x00, 0x00, 0x04, 0x00, 0x06, 0x00, 0x02, 0x01, 0x61, 0x01, 0x62, 0x01,
        0x63, 0x01,
        0x64, 0x84, 0x03, 0x01, 0x04, 0x02, 0x00, 0x0B, 0x00, 0x0E, 0x00, 0x1A, 0x21, 0xC1, 0x02, 0xC0,
        0x03, 0x00,
        0x16, 0x00, 0x17, 0x00, 0x18, 0x31, 0x30, 0x01, 0x78, 0x84, 0x01, 0x03, 0x00, 0x1F, 0x23, 0x3E,
        0x59, 0x33,
        0x66
    ];
    assert(osonToText(object) == `{"a":1,"b":[true,null,"x"],"c":{"d":-12.5}}`);
    immutable ubyte[] array = [
        0xFF, 0x4A, 0x5A, 0x01, 0x20, 0x06, 0x00, 0x00, 0x00, 0x00, 0x0C, 0x00, 0x00, 0xC0,
        0x02, 0x00, 0x06, 0x00, 0x09, 0x21, 0xC1, 0x02, 0x21, 0xC1, 0x03
    ];
    assert(osonToText(array) == `[1,2]`);
    // a scalar string
    immutable ubyte[] scalar = [0xFF, 0x4A, 0x5A, 0x01, 0x00, 0x10, 0x00, 0x04, 0x03, 'a', '"', 'b'];
    assert(osonToText(scalar) == `"a\"b"`);
    assertThrown!ProtocolException(osonToText(scalar[0 .. 10]));
    immutable ubyte[] notOson = [1, 2, 3, 4];
    assertThrown!ProtocolException(osonToText(notOson));
}
