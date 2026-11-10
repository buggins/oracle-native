/++
VECTOR values (Oracle AI Database 23ai): their binary image and their text.

The image: the byte `DB`, a version (0; 1 with BINARY vectors; 2 with sparse
ones), big-endian flags (`0x0002`: a norm follows, `0x0010`: space for a norm
follows, `0x0020`: sparse), the element format (`VectorFormat`), the number
of dimensions (big-endian u32; bits for BINARY), the 8 bytes of the norm if a
flag says so, then the elements: BINARY_FLOAT or BINARY_DOUBLE bytes, signed
bytes for INT8, packed bits for BINARY. Sparse vectors give the number of
stored elements (big-endian u16) and their indexes (big-endian u32 each)
before the elements.

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module oracle.types.vector;

import std.conv : to;
import oracle.exception : ClientException, ProtocolException;

/// The largest VECTOR image this client sends or fetches.
enum uint vectorMaxLength = 1024 * 1024;

/// The element formats of VECTOR values.
enum VectorFormat : ubyte
{
    float32 = 2, /// 32-bit floating point (`float`)
    float64 = 3, /// 64-bit floating point (`double`)
    int8 = 4, /// 8-bit integers (`byte`)
    binary = 5, /// bits, packed 8 to a byte (`ubyte`); the dimensions are a multiple of 8
}

/++
A VECTOR value: its dimensions and elements in one of the formats. Only the
array of its `format` holds the elements. A sparse vector holds only the
elements at `indices` (the others are zero).
+/
struct Vector
{
    /// The element format.
    VectorFormat format = VectorFormat.float32;
    /// The number of dimensions (bits for BINARY vectors).
    uint dimensions;
    /// The elements of FLOAT32 vectors.
    float[] float32s;
    /// The elements of FLOAT64 vectors.
    double[] float64s;
    /// The elements of INT8 vectors.
    byte[] int8s;
    /// The elements of BINARY vectors: 8 dimensions per byte, the first in the high bit.
    ubyte[] binary;
    /// Whether the vector is sparse.
    bool sparse;
    /// The indexes of the stored elements of a sparse vector, in order.
    uint[] indices;

    /// A dense FLOAT32 vector.
    static Vector of(const(float)[] values) @safe pure nothrow
    {
        Vector v;
        v.format = VectorFormat.float32;
        v.float32s = values.dup;
        v.dimensions = cast(uint) values.length;
        return v;
    }

    /// A dense FLOAT64 vector.
    static Vector of(const(double)[] values) @safe pure nothrow
    {
        Vector v;
        v.format = VectorFormat.float64;
        v.float64s = values.dup;
        v.dimensions = cast(uint) values.length;
        return v;
    }

    /// A dense INT8 vector.
    static Vector of(const(byte)[] values) @safe pure nothrow
    {
        Vector v;
        v.format = VectorFormat.int8;
        v.int8s = values.dup;
        v.dimensions = cast(uint) values.length;
        return v;
    }

    /// A BINARY vector of `bits.length * 8` dimensions.
    static Vector ofBits(const(ubyte)[] bits) @safe pure nothrow
    {
        Vector v;
        v.format = VectorFormat.binary;
        v.binary = bits.dup;
        v.dimensions = cast(uint)(bits.length * 8);
        return v;
    }

    /// The number of stored elements (all of them unless sparse; bytes for BINARY).
    @property size_t length() const @safe pure nothrow @nogc
    {
        final switch (format)
        {
        case VectorFormat.float32:
            return float32s.length;
        case VectorFormat.float64:
            return float64s.length;
        case VectorFormat.int8:
            return int8s.length;
        case VectorFormat.binary:
            return binary.length;
        }
    }

    /// Stored element `i` as a `double` (a byte of bits for BINARY).
    double opIndex(size_t i) const @safe pure nothrow
    {
        final switch (format)
        {
        case VectorFormat.float32:
            return float32s[i];
        case VectorFormat.float64:
            return float64s[i];
        case VectorFormat.int8:
            return int8s[i];
        case VectorFormat.binary:
            return binary[i];
        }
    }

    /++
    All dimensions as `double`s (zeros filled in for sparse vectors).

    Throws: `ClientException` for BINARY vectors.
    +/
    double[] toDoubles() const @safe pure
    {
        if (format == VectorFormat.binary)
            throw new ClientException("A BINARY vector has bits, not numbers");
        auto result = new double[sparse ? dimensions : length];
        result[] = 0;
        foreach (i; 0 .. length)
            result[sparse ? indices[i] : i] = this[i];
        return result;
    }

    /++
    The text the server writes (`FROM_VECTOR`): `[1.5E+000,2.0E+000]` for
    floating point (9 significant digits for FLOAT32, 17 for FLOAT64, trailing
    zeros dropped), `[1,-2]` for INT8, the bytes for BINARY (`[255,0]`), and
    `[dimensions,[indexes],[values]]` for sparse vectors.
    +/
    string toString() const @safe
    {
        import oracle.types.floats : decimalPoint;

        const point = format == VectorFormat.float32 || format == VectorFormat.float64 ? decimalPoint() : ".";
        string values = "[";
        foreach (i; 0 .. length)
        {
            if (i)
                values ~= ",";
            final switch (format)
            {
            case VectorFormat.float32:
                values ~= elementText(float32s[i], 9, point);
                break;
            case VectorFormat.float64:
                values ~= elementText(float64s[i], 17, point);
                break;
            case VectorFormat.int8:
                values ~= to!string(int8s[i]);
                break;
            case VectorFormat.binary:
                values ~= to!string(binary[i]);
                break;
            }
        }
        values ~= "]";
        if (!sparse)
            return values;
        string list = "[";
        foreach (i, index; indices)
            list ~= (i ? "," : "") ~ to!string(index);
        return "[" ~ to!string(dimensions) ~ "," ~ list ~ "]," ~ values ~ "]";
    }
}

/++
Decodes a VECTOR image.

Throws: `ProtocolException` for malformed images; `ClientException` for
versions or formats this client doesn't know.
+/
Vector decodeVector(const(ubyte)[] image) @safe pure
{
    import oracle.types.floats : decodeBinaryFloat;

    size_t pos;
    const(ubyte)[] take(size_t n)
    {
        if (n > image.length - pos)
            throw new ProtocolException("Truncated VECTOR image");
        auto b = image[pos .. pos + n];
        pos += n;
        return b;
    }

    uint u32()
    {
        const b = take(4);
        return (cast(uint) b[0] << 24) | (b[1] << 16) | (b[2] << 8) | b[3];
    }

    if (take(1)[0] != 0xDB)
        throw new ProtocolException("Not a VECTOR image");
    const ver = take(1)[0];
    if (ver > 2)
        throw new ClientException("VECTOR image version " ~ to!string(ver) ~ " is not supported");
    const f = take(2);
    const flags = (f[0] << 8) | f[1];
    Vector v;
    const format = take(1)[0];
    if (format < VectorFormat.float32 || format > VectorFormat.binary)
        throw new ClientException("VECTOR format " ~ to!string(format) ~ " is not supported");
    v.format = cast(VectorFormat) format;
    v.dimensions = u32();
    if (flags & (0x0002 | 0x0010))
        take(8); // the norm
    size_t count = v.format == VectorFormat.binary ? v.dimensions / 8 : v.dimensions;
    if (flags & 0x0020)
    {
        v.sparse = true;
        const n = take(2);
        count = (n[0] << 8) | n[1];
        v.indices = new uint[count];
        foreach (ref index; v.indices)
        {
            index = u32();
            if (index >= v.dimensions)
                throw new ProtocolException("Invalid sparse VECTOR index");
        }
    }
    const width = v.format == VectorFormat.float64 ? 8 : v.format == VectorFormat.float32 ? 4 : 1;
    if (count > (image.length - pos) / width)
        throw new ProtocolException("Truncated VECTOR image");
    final switch (v.format)
    {
    case VectorFormat.float32:
        v.float32s = new float[count];
        foreach (ref x; v.float32s)
            x = cast(float) decodeBinaryFloat(take(4));
        break;
    case VectorFormat.float64:
        v.float64s = new double[count];
        foreach (ref x; v.float64s)
            x = decodeBinaryFloat(take(8));
        break;
    case VectorFormat.int8:
        v.int8s = cast(byte[]) take(count).dup;
        break;
    case VectorFormat.binary:
        v.binary = take(count).dup;
        break;
    }
    if (pos != image.length)
        throw new ProtocolException("Extra bytes after a VECTOR image");
    return v;
}

/++
The image of `v`, as clients send it (with space for the norm).

Throws: `ClientException` for inconsistent vectors.
+/
immutable(ubyte)[] encodeVector(const Vector v) @safe pure
{
    import oracle.types.encode : encodeBinaryDouble, encodeBinaryFloat;

    const n = v.length;
    if (v.sparse ? v.indices.length != n || n > ushort.max : v.format == VectorFormat.binary
            ? v.dimensions != n * 8 : v.dimensions != n)
        throw new ClientException("The VECTOR's dimensions don't match its elements");
    ubyte[] b;
    void u32(uint x)
    {
        b ~= [cast(ubyte)(x >> 24), cast(ubyte)(x >> 16), cast(ubyte)(x >> 8), cast(ubyte) x];
    }

    ushort flags = 0x0010; // space for the norm
    ubyte ver = 0;
    if (v.sparse)
    {
        flags |= 0x0020 | 0x0002;
        ver = 2;
    }
    else if (v.format == VectorFormat.binary)
        ver = 1;
    else
        flags |= 0x0002;
    b ~= [0xDB, ver, cast(ubyte)(flags >> 8), cast(ubyte) flags, v.format];
    u32(v.dimensions);
    b ~= new ubyte[8];
    if (v.sparse)
    {
        b ~= [cast(ubyte)(n >> 8), cast(ubyte) n];
        foreach (index; v.indices)
        {
            if (index >= v.dimensions)
                throw new ClientException("A sparse VECTOR index is out of range");
            u32(index);
        }
    }
    final switch (v.format)
    {
    case VectorFormat.float32:
        foreach (x; v.float32s)
            b ~= encodeBinaryFloat(x);
        break;
    case VectorFormat.float64:
        foreach (x; v.float64s)
            b ~= encodeBinaryDouble(x);
        break;
    case VectorFormat.int8:
        b ~= cast(const(ubyte)[]) v.int8s;
        break;
    case VectorFormat.binary:
        b ~= v.binary;
        break;
    }
    return (() @trusted => cast(immutable(ubyte)[]) b)();
}

/++
An element as the server writes it: `1.5E+000`, `1.00000001E-001`, `0`.
The server refuses NaN and infinities in vectors; a `Vector` made by the
client may hold them: `Nan`, `Inf`, `-Inf` (as BINARY_DOUBLE text).
`point`: the C locale's decimal point, which `snprintf` writes.
+/
private string elementText(double x, int digits, string point) @safe
{
    import core.stdc.stdio : snprintf;
    import std.array : replace;
    import std.math : isInfinity, isNaN;
    import std.string : indexOf;

    if (isNaN(x))
        return "Nan";
    if (isInfinity(x))
        return x < 0 ? "-Inf" : "Inf";
    if (x == 0)
        return "0";
    char[64] buffer;
    // at most 17 digits, a sign, a point and an exponent: fits; snprintf writes only into the buffer
    const n = (() @trusted => snprintf(buffer.ptr, buffer.length, "%.*E", digits - 1, x))();
    if (n <= 0 || n >= buffer.length)
        throw new ClientException("Can't format a vector element");
    auto s = buffer[0 .. n].idup; // d.ddddE±xx
    if (point != ".") // the C locale's decimal point: "," after setlocale(LC_NUMERIC, "de_DE"), for example
        s = s.replace(point, ".");
    const e = s.indexOf('E');
    if (e < 0 || e + 2 >= s.length)
        throw new ClientException("Can't format a vector element");
    auto mantissa = s[0 .. e];
    while (mantissa.length > 3 && mantissa[$ - 1] == '0' && mantissa[$ - 2] != '.')
        mantissa = mantissa[0 .. $ - 1];
    auto exponent = s[e + 2 .. $];
    while (exponent.length < 3)
        exponent = "0" ~ exponent;
    return mantissa ~ "E" ~ s[e + 1] ~ exponent;
}

@safe unittest
{
    assert(Vector.of([1.5f, 2, 3]).toString() == "[1.5E+000,2.0E+000,3.0E+000]");
    assert(Vector.of([0.1f, 1e-7f, 3.4e38f, -0.0f]).toString()
            == "[1.00000001E-001,1.00000001E-007,3.39999995E+038,0]");
    assert(Vector.of([0.1, 1.5, 1e-300, 0.3])
            .toString()
            == "[1.0000000000000001E-001,1.5E+000,1.0E-300,2.9999999999999999E-001]");
    assert(Vector.of(cast(byte[])[1, -2]).toString() == "[1,-2]");
    assert(Vector.ofBits([255, 0]).toString() == "[255,0]");
    Vector s;
    s.sparse = true;
    s.dimensions = 5;
    s.indices = [1, 3];
    s.float32s = [1.5f, -2];
    assert(s.toString() == "[5,[1,3],[1.5E+000,-2.0E+000]]");
    foreach (v; [
            Vector.of([1.5f, 2]), Vector.of([0.1, -3]), Vector.of(cast(byte[])[1, -2]),
            Vector.ofBits([1, 2]), s
        ])
    {
        const image = encodeVector(v);
        const back = decodeVector(image);
        assert(back.toString() == v.toString() && back.dimensions == v.dimensions && back.sparse == v.sparse);
    }
    assert(s.toDoubles() == [0, 1.5, 0, -2, 0]);
    // TO_VECTOR('[1.5,2,3]', 3, FLOAT32) as 23ai sends it (with a norm)
    immutable ubyte[] image = [
        0xDB, 0x00, 0x00, 0x12, 0x02, 0x00, 0x00, 0x00, 0x03, 0xC0, 0x0F, 0x3D, 0xB2, 0x17,
        0x4E, 0x74, 0x68, 0xBF, 0xC0, 0x00, 0x00, 0xC0, 0x00, 0x00, 0x00, 0xC0, 0x40, 0x00, 0x00
    ];
    const v = decodeVector(image);
    assert(v.float32s == [1.5f, 2, 3] && v.dimensions == 3 && !v.sparse);
}

// NaN and infinities (the server refuses them, a client-made vector may hold them)
@safe unittest
{
    assert(Vector.of([float.nan, float.infinity, -float.infinity]).toString() == "[Nan,Inf,-Inf]");
    assert(Vector.of([double.nan, 1.5]).toString() == "[Nan,1.5E+000]");
}

// The text is independent of the C locale (with a decimal comma, where the system has such a locale)
@system unittest
{
    import core.stdc.locale : LC_NUMERIC, setlocale;
    import std.string : fromStringz, toStringz;

    const saved = fromStringz(setlocale(LC_NUMERIC, null)).idup;
    scope (exit)
        setlocale(LC_NUMERIC, saved.toStringz);
    foreach (name; ["de_DE.UTF-8", "de_DE.utf8", "fr_FR.UTF-8", "German_Germany.1252"])
        if (setlocale(LC_NUMERIC, name.toStringz) !is null)
        {
            assert(Vector.of([1.5f, 0.1f]).toString() == "[1.5E+000,1.00000001E-001]");
            break;
        }
}
