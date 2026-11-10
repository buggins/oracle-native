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
intervals as ISO 8601 durations (`P1DT2H3M4.500000S`, `P1Y2M`), RAW in
upper-case hexadecimal, NUMBERs exactly.

`encodeOson` makes an image of JSON text or a `std.json` value (for JSON
binds), storing numbers as the server's JSON parser does: as NUMBERs, rounded
to NUMBER's precision, or as BINARY_DOUBLE outside NUMBER's range.

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module oracle.types.oson;

import std.conv : to;
import dbwire.io.buffer : fromBigEndian;
import oracle.protocol.ttc : TtcWriter;
import oracle.exception : ClientException, ProtocolException;

/// The largest JSON value sent or fetched (as an OSON image), in bytes.
enum uint jsonMaxLength = 32 * 1024 * 1024;

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
    string output;
    uint depth;
    size_t visits; // child nodes visited: each has its own offset in its parent, unless containers are shared

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
            throw new ClientException("OSON version " ~ to!string(ver) ~ " is not supported");
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
        output.reserve(data.length * 2); // the text is usually longer than the image
        node();
        return output;
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
            throw new ClientException("OSON extended type " ~ to!string(extended) ~ " is not supported yet");
        case 0x3D:
            return yearToMonth(take(5));
        default:
            break;
        }
        if ((type & 0xF0) == 0x20 || (type & 0xF0) == 0x60) // NUMBER, its length - 1 in the type
            return number(take((type & 0x0F) + 1));
        if ((type & 0xF0) == 0x40 || (type & 0xF0) == 0x50) // an integer NUMBER, its length in the type
            return number(take(type & 0x0F));
        if ((type & 0xE0) == 0) // a string up to 31 bytes, its length in the type
            return quoted(cast(string) take(type));
        throw new ClientException("OSON node type " ~ to!string(type) ~ " is not supported yet");
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
                    throw new ProtocolException("Invalid OSON field ID " ~ to!string(id));
                quoted(names[id - 1]);
                put(":");
            }
            // children may share nodes: a few nested containers listing the same child twice would expand
            // exponentially; a tree without shared containers has fewer children than bytes
            if (++visits > data.length)
                throw new ProtocolException("OSON image with too many shared nodes");
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
        import oracle.types.number : NumberDigits, parseNumber;

        NumberDigits d;
        parseNumber(b, d);
        if (d.infinite)
            return put(d.negative ? "-~" : "~");
        put(decimalText(d.negative, d.buffer[0 .. d.length], d.pointPosition));
    }

    /// BINARY_FLOAT and BINARY_DOUBLE: the shortest digits that read back exactly, written as NUMBERs are.
    void floating(scope const(ubyte)[] b, bool single) @safe
    {
        import std.math : isFinite;
        import oracle.types.floats : decodeBinaryFloat, floatDigits, floatText;

        const v = decodeBinaryFloat(b);
        if (!isFinite(v))
            return quoted(floatText(v, single)); // "Nan", "Inf", "-Inf"
        const d = floatDigits(v, single);
        put(decimalText(d.negative, d.digits, d.pointPosition));
    }

    void dateTime(scope const(ubyte)[] b, bool zoned) @safe
    {
        import oracle.types.temporal : TextBuffer, decodeDateTime, decodeZone, hasLocalTime, localDateTime, putFraction;

        auto d = decodeDateTime(b);
        string suffix;
        if (zoned)
        {
            const zone = decodeZone(b);
            if (hasLocalTime(zone))
                d = localDateTime(d, zone);
            suffix = zone.text;
        }
        TextBuffer t; // as %04d-%02d-%02dT%02d:%02d:%02d, then .%06d with a fraction
        if (d.year < 0)
        {
            t.put('-');
            t.number(-d.year, 3);
        }
        else
            t.number(d.year, 4);
        t.put('-');
        t.number(d.month, 2);
        t.put('-');
        t.number(d.day, 2);
        t.put('T');
        t.number(d.hour, 2);
        t.put(':');
        t.number(d.minute, 2);
        t.put(':');
        t.number(d.second, 2);
        if (b.length > 7)
            t.putFraction(d.nanoseconds, 6);
        if (suffix.length <= t.buffer.length - t.length)
        {
            t.put(suffix);
            quoted(t.buffer[0 .. t.length]);
        }
        else
            quoted(t.text ~ suffix);
    }

    void dayToSecond(scope const(ubyte)[] b) @safe
    {
        import oracle.types.temporal : TextBuffer, decodeDayToSecond, putFraction;

        const d = decodeDayToSecond(b);
        const negative = d.days < 0 || d.hours < 0 || d.minutes < 0 || d.seconds < 0 || d.nanoseconds < 0;
        int abs(int v)
        {
            return v < 0 ? -v : v;
        }

        TextBuffer t; // as %sP%dDT%dH%dM%d.%06dS
        if (negative)
            t.put('-');
        t.put('P');
        t.number(abs(d.days), 1);
        t.put("DT");
        t.number(abs(d.hours), 1);
        t.put('H');
        t.number(abs(d.minutes), 1);
        t.put('M');
        t.number(abs(d.seconds), 1);
        t.putFraction(abs(d.nanoseconds), 6);
        t.put('S');
        quoted(t.buffer[0 .. t.length]);
    }

    /// As `JSON_SERIALIZE` writes it: `P1Y2M`, `-P3M`, `P1Y`, `P0Y`.
    void yearToMonth(scope const(ubyte)[] b) @safe
    {
        import oracle.types.temporal : decodeYearToMonth;

        const ym = decodeYearToMonth(b);
        const negative = ym.years < 0 || ym.months < 0;
        const years = ym.years < 0 ? -ym.years : ym.years;
        const months = ym.months < 0 ? -ym.months : ym.months;
        string s = negative ? "-P" : "P";
        if (years || !months)
            s ~= to!string(years) ~ "Y";
        if (months)
            s ~= to!string(months) ~ "M";
        quoted(s);
    }

    void hex(scope const(ubyte)[] b) @safe
    {
        import std.digest : LetterCase, toHexString;

        quoted(toHexString!(LetterCase.upper)(b));
    }

    void vector(immutable(ubyte)[] b) @safe
    {
        import oracle.types.vector : decodeVector;

        put(decodeVector(b).toString());
    }

    /// A JSON string: quotes, backslash escapes for `"`, `\` and control characters.
    void quoted(scope const(char)[] s) @safe
    {
        static immutable digits = "0123456789abcdef";
        output ~= '"';
        size_t run; // the start of the characters that need no escape, appended as one slice
        foreach (i, char c; s)
        {
            if (c >= 0x20 && c != '"' && c != '\\')
                continue;
            output ~= s[run .. i];
            run = i + 1;
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
                output ~= `\u00`;
                output ~= digits[c >> 4];
                output ~= digits[c & 15];
            }
        }
        output ~= s[run .. $];
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
        return fromBigEndian!ushort(take(2)[0 .. 2]);
    }

    uint u32() @safe
    {
        return fromBigEndian!uint(take(4)[0 .. 4]);
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

/// A decimal number: 0.`digits` × 10^`point`, digits without leading or trailing zeros (none for zero).
private struct DecimalParts
{
    bool negative;
    char[] digits;
    long point;
}

/// Splits a decimal number in JSON syntax (`-12.5e3`, also C's `1e+02`) into its sign and digits.
private DecimalParts parseDecimal(string text) @safe pure nothrow
{
    DecimalParts p;
    size_t i;
    const negative = text.length && text[0] == '-';
    char[] digits;
    long point;
    if (negative)
        i++;
    for (; i < text.length && text[i] >= '0' && text[i] <= '9'; i++)
        digits ~= text[i];
    point = digits.length;
    if (i < text.length && text[i] == '.')
        for (i++; i < text.length && text[i] >= '0' && text[i] <= '9'; i++)
            digits ~= text[i];
    long exponent;
    if (i < text.length && (text[i] == 'e' || text[i] == 'E'))
    {
        i++;
        const expNegative = i < text.length && text[i] == '-';
        if (i < text.length && (text[i] == '-' || text[i] == '+'))
            i++;
        for (; i < text.length && text[i] >= '0' && text[i] <= '9'; i++)
            if (exponent < 100_000)
                exponent = exponent * 10 + (text[i] - '0');
        if (expNegative)
            exponent = -exponent;
    }
    size_t start;
    while (start < digits.length && digits[start] == '0')
    {
        start++;
        point--;
    }
    digits = digits[start .. $];
    while (digits.length && digits[$ - 1] == '0')
        digits = digits[0 .. $ - 1];
    p.negative = negative;
    p.digits = digits;
    p.point = point + exponent;
    return p;
}

/++
A number as `JSON_SERIALIZE` writes it: plain with up to 40 digits before
and after the point (`-0.015`, `1000`), else `1.5E-40`.
+/
private string decimalText(bool negative, scope const(char)[] digits, long point) @safe pure nothrow
{
    import std.array : replicate;

    const n = cast(long) digits.length;
    if (n == 0)
        return "0";
    const sign = negative ? "-" : "";
    if (point <= 40 && n - point <= 40)
    {
        if (point <= 0)
            return sign ~ "0." ~ "0".replicate(cast(size_t)-point) ~ digits.idup;
        if (point >= n)
            return sign ~ digits.idup ~ "0".replicate(cast(size_t)(point - n));
        return sign ~ digits[0 .. cast(size_t) point].idup ~ "." ~ digits[cast(size_t) point .. $].idup;
    }
    const exponent = point - 1;
    return sign ~ digits[0 .. 1].idup ~ (n > 1 ? "." ~ digits[1 .. $].idup : "") ~ "E" ~ (exponent < 0 ? "-" : "+")
        ~ to!string(exponent < 0 ? -exponent : exponent);
}

@safe unittest
{
    const a = parseDecimal("-0012.5000e+3");
    assert(a.negative && a.digits == "125" && a.point == 5);
    const b = parseDecimal("1e-05");
    assert(!b.negative && b.digits == "1" && b.point == -4);
    assert(decimalText(false, "1", -4) == "0.00001" && decimalText(false, "1", 3) == "100");
    assert(decimalText(false, "12345678901234568", 18) == "123456789012345680");
    assert(decimalText(true, "25", -299) == "-2.5E-300" && decimalText(false, "1", 301) == "1E+300");
    assert(decimalText(false, "123456789", 6) == "123456.789" && decimalText(false, "", 0) == "0");
}

// --- encoding ---

/++
The OSON image of a JSON text (for a JSON bind). Object members keep their
order; a name may not repeat in an object (the server refuses that too).
`longFieldNames`: field names may be longer than 255 bytes (up to 65535;
Oracle Database 23ai), else such names are refused.

Throws: `ClientException` if the text isn't valid JSON, an object repeats a
name, or a field name is too long.
+/
immutable(ubyte)[] encodeOson(string json, bool longFieldNames) @safe
{
    auto parser = JsonParser(json);
    return encodeTree(parser.document(), longFieldNames);
}

/// ditto; objects get their members in name order (a `JSONValue` keeps none).
immutable(ubyte)[] encodeOson(const JSONValue value, bool longFieldNames) @safe
{
    return encodeTree(fromJsonValue(value, 0), longFieldNames);
}

/++
Checks that `json` is valid JSON text (as `encodeOson` reads it).

Throws: `ClientException` if it isn't.
+/
void checkJsonText(string json) @safe
{
    auto parser = JsonParser(json);
    parser.document();
}

import std.json : JSONValue;

/// A JSON value to encode.
private struct JsonNode
{
    enum Kind : ubyte
    {
        null_,
        true_,
        false_,
        string_,
        number, // `bytes`: a NUMBER
        binaryDouble, // `bytes`: a BINARY_DOUBLE
        array,
        object,
    }

    Kind kind;
    string text; // a string's value
    immutable(ubyte)[] bytes;
    JsonNode[] children; // array elements, object member values
    string[] names; // object member names
}

private enum maxDepth = 1000;

private JsonNode scalarNode(JsonNode.Kind kind) @safe pure nothrow
{
    JsonNode n;
    n.kind = kind;
    return n;
}

/++
A JSON number given as text (`-12.5e3`, valid JSON syntax): a NUMBER rounded
to NUMBER's 20 base-100 digits, or a BINARY_DOUBLE outside NUMBER's range,
as the server's JSON parser stores it.
+/
private JsonNode numberNode(string text) @safe
{
    import oracle.types.encode : encodeBinaryDouble, encodeNumber;
    import oracle.types.floats : parseDouble;

    const parts = parseDecimal(text);
    const negative = parts.negative;
    auto digits = parts.digits.dup; // rounded in place below
    long point = parts.point; // moved by the alignment and rounding below
    JsonNode n;
    n.kind = JsonNode.Kind.number;
    if (digits.length == 0)
    {
        n.bytes = encodeNumber(0L);
        return n;
    }
    // align on base-100 digits, then keep 20 of them (40 decimal digits), rounding half up
    if (point % 2 != 0)
    {
        digits = "0" ~ digits;
        point++;
    }
    if (digits.length > 40)
    {
        const roundUp = digits[40] >= '5';
        digits = digits[0 .. 40];
        if (roundUp)
        {
            size_t k = digits.length;
            while (k > 0 && digits[k - 1] == '9')
                digits[--k] = '0';
            if (k == 0)
            {
                digits = "01" ~ digits[0 .. 38]; // 99...9 rounds to 100...0: one more base-100 digit
                point += 2;
            }
            else
                digits[k - 1]++;
        }
    }
    const pairExponent = point / 2 - 1; // NUMBER's range: 100^-65 to below 100^63
    if (pairExponent < -65 || pairExponent > 62)
    {
        n.kind = JsonNode.Kind.binaryDouble;
        n.bytes = encodeBinaryDouble(parseDouble(text));
        return n;
    }
    n.bytes = encodeNumber(negative, digits, cast(int) point);
    return n;
}

private JsonNode fromJsonValue(const JSONValue v, uint depth) @safe
{
    import std.algorithm.sorting : sort;
    import std.json : JSONType;
    import std.math : isFinite;
    import oracle.types.encode : encodeBinaryDouble;
    import oracle.types.floats : floatText;

    if (depth > maxDepth)
        throw new ClientException("JSON value nested too deeply");
    final switch (v.type)
    {
    case JSONType.null_:
        return scalarNode(JsonNode.Kind.null_);
    case JSONType.true_:
        return scalarNode(JsonNode.Kind.true_);
    case JSONType.false_:
        return scalarNode(JsonNode.Kind.false_);
    case JSONType.string:
        JsonNode n;
        n.kind = JsonNode.Kind.string_;
        n.text = v.str;
        return n;
    case JSONType.integer:
        return numberNode(v.integer.to!string);
    case JSONType.uinteger:
        return numberNode(v.uinteger.to!string);
    case JSONType.float_:
        if (isFinite(v.floating))
            return numberNode(floatText(v.floating, false));
        JsonNode n;
        n.kind = JsonNode.Kind.binaryDouble;
        n.bytes = encodeBinaryDouble(v.floating);
        return n;
    case JSONType.array:
        JsonNode n;
        n.kind = JsonNode.Kind.array;
        foreach (ref e; v.arrayNoRef)
            n.children ~= fromJsonValue(e, depth + 1);
        return n;
    case JSONType.object:
        JsonNode n;
        n.kind = JsonNode.Kind.object;
        const members = v.objectNoRef;
        auto keys = (() @trusted => members.keys)(); // @system for a const AA before frontend 2.098
        sort(keys);
        foreach (k; keys)
        {
            n.names ~= k;
            n.children ~= fromJsonValue(members[k], depth + 1);
        }
        return n;
    }
}

/// A JSON text parser (RFC 8259) building `JsonNode`s.
private struct JsonParser
{
    string text;
    size_t pos;

    JsonNode document() @safe
    {
        skipSpace();
        auto n = value(0);
        skipSpace();
        if (pos != text.length)
            fail("unexpected text after the value");
        return n;
    }

    JsonNode value(uint depth) @safe
    {
        if (depth > maxDepth)
            fail("nested too deeply");
        if (pos >= text.length)
            fail("a value expected");
        switch (text[pos])
        {
        case '{':
            return object(depth);
        case '[':
            return array(depth);
        case '"':
            JsonNode n;
            n.kind = JsonNode.Kind.string_;
            n.text = str();
            return n;
        case 't':
            literal("true");
            return scalarNode(JsonNode.Kind.true_);
        case 'f':
            literal("false");
            return scalarNode(JsonNode.Kind.false_);
        case 'n':
            literal("null");
            return scalarNode(JsonNode.Kind.null_);
        default:
            return number();
        }
    }

    JsonNode object(uint depth) @safe
    {
        JsonNode n;
        n.kind = JsonNode.Kind.object;
        bool[string] seen;
        pos++; // {
        skipSpace();
        if (peek('}'))
            return n;
        for (;;)
        {
            skipSpace();
            if (!peek('"', false))
                fail("a member name expected");
            const name = str();
            skipSpace();
            expect(':');
            skipSpace();
            if (name in seen)
                fail("the name \"" ~ name ~ "\" repeats in an object");
            seen[name] = true;
            n.names ~= name;
            n.children ~= value(depth + 1);
            skipSpace();
            if (peek('}'))
                return n;
            expect(',');
        }
    }

    JsonNode array(uint depth) @safe
    {
        JsonNode n;
        n.kind = JsonNode.Kind.array;
        pos++; // [
        skipSpace();
        if (peek(']'))
            return n;
        for (;;)
        {
            skipSpace();
            n.children ~= value(depth + 1);
            skipSpace();
            if (peek(']'))
                return n;
            expect(',');
        }
    }

    JsonNode number() @safe
    {
        const start = pos;
        if (pos < text.length && text[pos] == '-')
            pos++;
        if (pos < text.length && text[pos] == '0')
            pos++;
        else if (!digits())
            fail("invalid value");
        if (pos < text.length && text[pos] == '.')
        {
            pos++;
            if (!digits())
                fail("digits expected after the decimal point");
        }
        if (pos < text.length && (text[pos] == 'e' || text[pos] == 'E'))
        {
            pos++;
            if (pos < text.length && (text[pos] == '+' || text[pos] == '-'))
                pos++;
            if (!digits())
                fail("digits expected in the exponent");
        }
        return numberNode(text[start .. pos]);
    }

    bool digits() @safe pure nothrow
    {
        const start = pos;
        while (pos < text.length && text[pos] >= '0' && text[pos] <= '9')
            pos++;
        return pos > start;
    }

    string str() @safe
    {
        bool plain(char ch)
        {
            return ch != '"' && ch != '\\' && ch >= 0x20;
        }

        pos++; // "
        const start = pos;
        while (pos < text.length && plain(text[pos]))
            pos++;
        if (pos < text.length && text[pos] == '"')
        {
            pos++;
            return text[start .. pos - 1]; // no escapes: a slice of the text
        }
        string result = text[start .. pos];
        for (;;)
        {
            if (pos >= text.length)
                fail("unterminated string");
            const c = text[pos++];
            if (c == '"')
                break;
            if (c < 0x20)
                fail("control character in a string");
            if (c != '\\')
            {
                // the run of characters without escapes, as one slice
                const run = pos - 1;
                while (pos < text.length && plain(text[pos]))
                    pos++;
                result ~= text[run .. pos];
                continue;
            }
            if (pos >= text.length)
                fail("unterminated string");
            const e = text[pos++];
            switch (e)
            {
            case '"':
            case '\\':
            case '/':
                result ~= e;
                break;
            case 'b':
                result ~= '\b';
                break;
            case 'f':
                result ~= '\f';
                break;
            case 'n':
                result ~= '\n';
                break;
            case 'r':
                result ~= '\r';
                break;
            case 't':
                result ~= '\t';
                break;
            case 'u':
                dchar u = hex4();
                if (u >= 0xD800 && u < 0xDC00) // a surrogate pair
                {
                    if (pos + 2 > text.length || text[pos] != '\\' || text[pos + 1] != 'u')
                        fail("unpaired surrogate");
                    pos += 2;
                    const low = hex4();
                    if (low < 0xDC00 || low > 0xDFFF)
                        fail("unpaired surrogate");
                    u = 0x10000 + ((u - 0xD800) << 10) + (low - 0xDC00);
                }
                else if (u >= 0xDC00 && u <= 0xDFFF)
                    fail("unpaired surrogate");
                result ~= u; // encoded as UTF-8 (surrogates were refused above)
                break;
            default:
                fail("invalid escape");
            }
        }
        return result;
    }

    dchar hex4() @safe
    {
        if (pos + 4 > text.length)
            fail("invalid \\u escape");
        uint v;
        foreach (c; text[pos .. pos + 4])
        {
            v <<= 4;
            if (c >= '0' && c <= '9')
                v |= c - '0';
            else if (c >= 'a' && c <= 'f')
                v |= c - 'a' + 10;
            else if (c >= 'A' && c <= 'F')
                v |= c - 'A' + 10;
            else
                fail("invalid \\u escape");
        }
        pos += 4;
        return cast(dchar) v;
    }

    void literal(string word) @safe
    {
        if (text.length - pos < word.length || text[pos .. pos + word.length] != word)
            fail("invalid value");
        pos += word.length;
    }

    bool peek(char c, bool consume = true) @safe pure nothrow
    {
        if (pos < text.length && text[pos] == c)
        {
            if (consume)
                pos++;
            return true;
        }
        return false;
    }

    void expect(char c) @safe
    {
        if (!peek(c))
            fail("'" ~ c ~ "' expected");
    }

    void skipSpace() @safe pure nothrow
    {
        while (pos < text.length && (text[pos] == ' ' || text[pos] == '\t' || text[pos] == '\n' || text[pos] == '\r'))
            pos++;
    }

    void fail(string what) @safe
    {
        throw new ClientException("Invalid JSON text at offset " ~ to!string(pos) ~ ": " ~ what);
    }
}

/// A field name of an image: its hash (FNV-1a), and its ID once sorted.
private struct FieldName
{
    string name;
    uint hash;
    uint id;
    uint offset; // in its segment
}

private uint fieldNameHash(string name) @safe pure nothrow @nogc
{
    uint h = 0x811C_9DC5;
    foreach (char c; name)
        h = (h ^ cast(ubyte) c) * 16_777_619;
    return h;
}

/// Big-endian integers into a byte buffer.
/// Header flags of an image.
private enum : uint
{
    inlineLeaf = 0x02,
    lengthInType = 0x04,
    fieldIds32 = 0x08,
    isScalar = 0x10,
    hashIds8 = 0x0100,
    fieldIds16 = 0x0400,
    namesSegment32 = 0x0800,
    tree32 = 0x1000,
    tinyNodeCount = 0x2000,
}

private immutable(ubyte)[] encodeTree(const JsonNode root, bool longFieldNames) @safe
{
    import std.algorithm.sorting : sort;

    // the field names, short (up to 255 bytes) and long ones, sorted by hash byte, length and bytes
    uint[string] ids;
    FieldName[] shortNames, longNames;
    void collect(const ref JsonNode n)
    {
        foreach (name; n.names)
            if (name !in ids)
            {
                if (name.length > (longFieldNames ? 65_535 : 255))
                    throw new ClientException("JSON field name longer than " ~ (longFieldNames
                            ? "65535 bytes" : "255 bytes (longer ones need Oracle Database 23ai)"));
                ids[name] = 0;
                (name.length > 255 ? longNames : shortNames) ~= FieldName(name, fieldNameHash(name));
            }
        foreach (ref c; n.children)
            collect(c);
    }

    collect(root);
    static bool before(const FieldName a, const FieldName b) @safe pure nothrow
    {
        if ((a.hash & 0xFF) != (b.hash & 0xFF))
            return (a.hash & 0xFF) < (b.hash & 0xFF);
        if (a.name.length != b.name.length)
            return a.name.length < b.name.length;
        return a.name < b.name;
    }

    sort!before(shortNames);
    sort!before(longNames);
    TtcWriter shortSegment, longSegment;
    foreach (i, ref f; shortNames)
    {
        f.id = cast(uint)(i + 1);
        ids[f.name] = f.id;
        f.offset = cast(uint) shortSegment.data.length;
        shortSegment.u8(cast(ubyte)(f.name.length));
        shortSegment.bytes(cast(const(ubyte)[]) f.name);
    }
    foreach (i, ref f; longNames)
    {
        f.id = cast(uint)(shortNames.length + i + 1);
        ids[f.name] = f.id;
        f.offset = cast(uint) longSegment.data.length;
        longSegment.u16be(cast(uint) f.name.length);
        longSegment.bytes(cast(const(ubyte)[]) f.name);
    }
    const names = shortNames.length + longNames.length;
    const idWidth = names > 65_535 ? 4 : names > 255 ? 2 : 1;

    // the tree: containers with 32-bit child offsets from the start of the tree
    TtcWriter tree;
    void node(const ref JsonNode n)
    {
        final switch (n.kind)
        {
        case JsonNode.Kind.null_:
            return tree.u8(0x30);
        case JsonNode.Kind.true_:
            return tree.u8(0x31);
        case JsonNode.Kind.false_:
            return tree.u8(0x32);
        case JsonNode.Kind.string_:
            if (n.text.length < 256)
            {
                tree.u8(0x33);
                tree.u8(cast(ubyte)(n.text.length));
            }
            else if (n.text.length < 65_536)
            {
                tree.u8(0x37);
                tree.u16be(cast(uint) n.text.length);
            }
            else
            {
                if (n.text.length > uint.max)
                    throw new ClientException("JSON string too long");
                tree.u8(0x38);
                tree.u32be(cast(uint) n.text.length);
            }
            return tree.bytes(cast(const(ubyte)[]) n.text);
        case JsonNode.Kind.number:
            tree.u8(0x34);
            tree.u8(cast(ubyte)(n.bytes.length));
            return tree.bytes(n.bytes);
        case JsonNode.Kind.binaryDouble:
            tree.u8(0x36);
            return tree.bytes(n.bytes);
        case JsonNode.Kind.array:
        case JsonNode.Kind.object:
            const isObject = n.kind == JsonNode.Kind.object;
            const count = n.children.length;
            if (count > uint.max)
                throw new ClientException("JSON container too big");
            ubyte type = isObject ? 0x84 : 0xC0;
            type |= 0x20; // 32-bit offsets
            type |= count > 65_535 ? 0x10 : count > 255 ? 0x08 : 0;
            tree.u8(type);
            if (count > 65_535)
                tree.u32be(cast(uint) count);
            else if (count > 255)
                tree.u16be(cast(uint) count);
            else
                tree.u8(cast(ubyte)(count));
            if (isObject)
                foreach (name; n.names)
                {
                    const id = ids[name];
                    if (idWidth == 1)
                        tree.u8(cast(ubyte)(id));
                    else if (idWidth == 2)
                        tree.u16be(id);
                    else
                        tree.u32be(id);
                }
            const offsets = tree.data.length;
            tree.zeros(4 * count); // the offsets, filled in below
            foreach (i, ref c; n.children)
            {
                if (tree.data.length > uint.max)
                    throw new ClientException("JSON value too big");
                tree.setU32be(offsets + 4 * i, cast(uint) tree.data.length);
                node(c);
            }
            return;
        }
    }

    node(root);
    if (tree.data.length > uint.max)
        throw new ClientException("JSON value too big");
    const treeSize = cast(uint) tree.data.length;

    TtcWriter image;
    image.bytes([0xFF, 0x4A, 0x5A]);
    image.u8(cast(ubyte)(longNames.length ? 3 : 1));
    const scalar = root.kind != JsonNode.Kind.array && root.kind != JsonNode.Kind.object;
    uint flags = inlineLeaf | lengthInType | (treeSize > 65_535 ? tree32 : 0);
    if (scalar)
    {
        image.u16be(flags | isScalar);
        treeSize > 65_535 ? image.u32be(treeSize) : image.u16be(treeSize);
        image.bytes(tree.data);
        return (() @trusted => cast(immutable(ubyte)[]) image.data)(); // unique: built here
    }
    const shortSize = shortSegment.data.length;
    const longSize = longSegment.data.length;
    if (shortSize > uint.max || longSize > uint.max)
        throw new ClientException("JSON field names too big");
    flags |= hashIds8 | tinyNodeCount | (idWidth == 4 ? fieldIds32 : idWidth == 2 ? fieldIds16
            : 0)
        | (shortSize > 65_535 ? namesSegment32 : 0);
    image.u16be(flags);
    if (idWidth == 1)
        image.u8(cast(ubyte)(shortNames.length));
    else if (idWidth == 2)
        image.u16be(cast(uint) shortNames.length);
    else
        image.u32be(cast(uint) shortNames.length);
    shortSize > 65_535 ? image.u32be(cast(uint) shortSize) : image.u16be(cast(uint) shortSize);
    if (longNames.length)
    {
        image.u16be(longSize < 65_536 ? 0x0100 : 0); // 16-bit offsets of long names
        image.u32be(cast(uint) longNames.length);
        image.u32be(cast(uint) longSize);
    }
    treeSize > 65_535 ? image.u32be(treeSize) : image.u16be(treeSize);
    image.u16be(0); // tiny nodes
    foreach (ref f; shortNames)
        image.u8(cast(ubyte)(f.hash & 0xFF));
    foreach (ref f; shortNames)
        shortSize > 65_535 ? image.u32be(f.offset) : image.u16be(f.offset);
    image.bytes(shortSegment.data);
    foreach (ref f; longNames)
        image.u16be(f.hash & 0xFFFF);
    foreach (ref f; longNames)
        longSize < 65_536 ? image.u16be(f.offset) : image.u32be(f.offset);
    image.bytes(longSegment.data);
    image.bytes(tree.data);
    return (() @trusted => cast(immutable(ubyte)[]) image.data)(); // unique: built here
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

///
@safe unittest
{
    import std.exception : assertThrown;
    import std.json : parseJSON;

    // round trips through the decoder
    foreach (text; [
        `{"a":1,"b":[true,null,"x"],"c":{"d":-12.5}}`, `[1,2]`, `"a\"b"`, `[]`, `{}`, `0`,
        `{"z":{"z":{"z":[{"y":1E+125}]}}}`, `["\u00e9\ud83d\ude00\n"]`, `[1E-130,1E+200,123456789]`
    ])
    {
        const image = encodeOson(text, false);
        assert(isOson(image));
        const back = osonToText(image);
        assert(back == text || parseJSON(back) == parseJSON(text), text ~ " -> " ~ back);
    }
    // numbers as the server stores them: rounded to NUMBER's precision
    assert(osonToText(encodeOson(
            `[0.99999999999999999999999999999999999999999,12345678901234567890123456789012345678951]`,
            false)) == `[1,1.2345678901234567890123456789012345679E+40]`);
    assert(osonToText(encodeOson(`[-0,0.0,1E3,-1.50e-2]`, false)) == `[0,0,1000,-0.015]`);
    assertThrown!ClientException(encodeOson(`{"a":1,"b":2,"a":3}`, false)); // a repeated name
    assert(osonToText(encodeOson(`[{"a":1},{"a":2}]`, false)) == `[{"a":1},{"a":2}]`);
    // a std.json value: members in name order
    assert(osonToText(encodeOson(parseJSON(`{"b":[1.5,-2,"s"],"a":null}`), false)) == `{"a":null,"b":[1.5,-2,"s"]}`);
    // a scalar image: FF 4A 5A, version 1, flags (scalar), tree size, the node
    assert(encodeOson(`"ab"`, false) == [
        0xFF, 0x4A, 0x5A, 0x01, 0x00, 0x16, 0x00, 0x04, 0x33, 0x02, 'a', 'b'
    ]);
    // an object: one short field name with its FNV-1a hash byte
    assert(encodeOson(`{"a":true}`, false) == [
        0xFF, 0x4A, 0x5A, 0x01, 0x21, 0x06, 0x01, 0x00, 0x02, 0x00, 0x08,
        0x00, 0x00, 0x2C, 0x00, 0x00, 0x01, 'a', 0xA4, 0x01, 0x01, 0x00, 0x00, 0x00, 0x07, 0x31
    ]);
    foreach (bad; [
        ``, `{`, `[1,]`, `{"a" 1}`, `01`, `1.`, `"\x"`, `tru`, `[1] 2`, `"\ud800"`, "\"a\nb\""
    ])
        assertThrown!ClientException(encodeOson(bad, false), bad);
    // names over 255 bytes: version 3 with a long-name segment, only when allowed
    import std.array : replicate;

    const longName = "n".replicate(300);
    assertThrown!ClientException(encodeOson(`{"` ~ longName ~ `":1}`, false));
    const image = encodeOson(`{"` ~ longName ~ `":1,"s":2}`, true);
    assert(image[3] == 3 && osonToText(image) == `{"` ~ longName ~ `":1,"s":2}`);
    // many names and a big tree: 16-bit field IDs, 32-bit sizes
    string many = "{";
    foreach (i; 0 .. 3000)
        many ~= (i ? "," : "") ~ `"field` ~ to!string(i) ~ `":"` ~ "v".replicate(30) ~ `"`;
    many ~= "}";
    assert(parseJSON(osonToText(encodeOson(many, false))) == parseJSON(many));
}

@safe unittest
{
    // INTERVAL YEAR TO MONTH nodes, as 23ai sends them
    immutable ubyte[] ym = [
        0xFF, 0x4A, 0x5A, 0x01, 0x00, 0x16, 0x00, 0x06, 0x3D, 0x80, 0x00, 0x00, 0x01, 0x3E
    ];
    assert(osonToText(ym) == `"P1Y2M"`);
    immutable ubyte[] negative = [
        0xFF, 0x4A, 0x5A, 0x01, 0x00, 0x16, 0x00, 0x06, 0x3D, 0x7F, 0xFF, 0xFF, 0xFD, 0x31
    ];
    assert(osonToText(negative) == `"-P3Y11M"`);
    immutable ubyte[] zero = [
        0xFF, 0x4A, 0x5A, 0x01, 0x00, 0x16, 0x00, 0x06, 0x3D, 0x80, 0x00, 0x00, 0x00, 0x3C
    ];
    assert(osonToText(zero) == `"P0Y"`);
    immutable ubyte[] months = [
        0xFF, 0x4A, 0x5A, 0x01, 0x00, 0x16, 0x00, 0x06, 0x3D, 0x80, 0x00, 0x00, 0x00, 0x39
    ];
    assert(osonToText(months) == `"-P3M"`);
}

// Containers that list the same child twice: an exponential expansion is refused
@safe unittest
{
    import std.exception : assertThrown;

    ubyte[] tree;
    enum depth = 40;
    foreach (i; 0 .. depth)
    {
        const next = (i + 1) * 6;
        tree ~= [
            cast(ubyte) 0xC0, 2, cast(ubyte)(next >> 8), cast(ubyte) next, cast(ubyte)(next >> 8),
            cast(ubyte) next
        ];
    }
    tree ~= 0x30; // the innermost node
    ubyte[] image = [
        0xFF, 0x4A, 0x5A, 1, 0x00, 0x00, 0, 0, 0, cast(ubyte)(tree.length >> 8),
        cast(ubyte) tree.length,
        0, 0
    ];
    image ~= tree;
    assertThrown!ProtocolException(osonToText(image.idup));
}

// Strings with characters to escape: the runs between them are copied as they are
@safe unittest
{
    const text = `{"a":"x\"y\\z\n\u0001w","b":"plain text"}`;
    assert(osonToText(encodeOson(text, false)) == text);
}
