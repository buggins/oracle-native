/++
Bind variables: `Parameter` (a D value converted to an Oracle type and its
wire form), finding the placeholders (`:1`, `:name`) of a statement, and
rewriting `?` placeholders.

D types and the Oracle types they are sent as:

$(TABLE
$(TR $(TH D type) $(TH Oracle type))
$(TR $(TD `bool`) $(TD `BOOLEAN` (23ai); `NUMBER` 1 or 0 for older servers))
$(TR $(TD integers) $(TD `NUMBER`))
$(TR $(TD `float`) $(TD `BINARY_FLOAT`))
$(TR $(TD `double`, `real`) $(TD `BINARY_DOUBLE`))
$(TR $(TD `Decimal`) $(TD `NUMBER`, exactly (at most 40 significant digits)))
$(TR $(TD strings, `char`) $(TD `VARCHAR2`; longer than 32767 bytes: for `CLOB` and `LONG` columns))
$(TR $(TD `ubyte[]`, `UUID`) $(TD `RAW`; longer than 32767 bytes: for `BLOB` and `LONG RAW` columns))
$(TR $(TD `Lob`) $(TD the LOB (e.g. a temporary LOB from `Connection.createLob`)))
$(TR $(TD `Date`, `DateTime`) $(TD `DATE`))
$(TR $(TD `SysTime`) $(TD `TIMESTAMP WITH TIME ZONE` with the time's UTC offset, to 100 ns))
$(TR $(TD `Duration`) $(TD `INTERVAL DAY TO SECOND`))
$(TR $(TD `MonthInterval`) $(TD `INTERVAL YEAR TO MONTH`))
$(TR $(TD `Vector`, `float[]`, `double[]`) $(TD `VECTOR` (23ai; for older servers its text)))
$(TR $(TD `JSONValue`, `Parameter.json(text)`) $(TD `JSON` as Oracle's binary JSON (OSON; 21c and later; for older servers its text)))
$(TR $(TD `Nullable!T`) $(TD NULL of T's type, or T's value))
$(TR $(TD `typeof(null)`) $(TD NULL `VARCHAR2`))
$(TR $(TD `Variant`) $(TD by its content; empty: NULL `VARCHAR2`))
)

Oracle converts bind values to the types the statement needs (a `VARCHAR2`
NULL goes into any column).

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module oracle.params;

import core.time : Duration;
import std.datetime.date : Date, DateTime;
import std.datetime.systime : SysTime;
import std.traits : isFloatingPoint, isIntegral, isSomeChar, isSomeString, Unqual;
import std.json : JSONValue;
import std.typecons : Nullable;
import std.uuid : UUID;
import std.variant : Variant;
import dbwire.types.decimal : Decimal;
import dbwire.types.interval : MonthInterval;
import oracle.exception : ClientException;
import oracle.lob : Lob;
import oracle.types.typeinfo : CharsetForm, OracleType;
import oracle.types.oson : jsonMaxLength;
import oracle.types.vector : Vector, vectorMaxLength;

/// The largest VARCHAR2 and RAW bind value, in bytes.
enum size_t maxBindBytes = 32_767;

/// Bind directions.
enum BindDirection : ubyte
{
    input = 0x20, /// IN
    output = 0x10, /// OUT
    inputOutput = 0x30, /// IN OUT
}

/// A bind variable: its name, Oracle type, and value in wire form.
struct Parameter
{
    /// The placeholder's name for named binds (`:name` without the colon); empty for positional ones.
    string name;
    /// The Oracle type the value is sent as.
    OracleType type;
    /// The largest value in bytes (sent in the bind metadata).
    uint bufferSize;
    /// The value in the type's wire form; `null` for NULL.
    immutable(ubyte)[] data;
    /// Whether the value is NULL.
    bool isNull;
    /// IN, OUT (PL/SQL `OUT` parameters, `RETURNING INTO`) or IN OUT.
    BindDirection direction = BindDirection.input;

    /// Whether the type is character data (sent with the AL32UTF8 character set).
    @property bool isText() const @safe pure nothrow
    {
        return type == OracleType.varchar || type == OracleType.char_ || type == OracleType.long_
            || type == OracleType.clob;
    }

    /++
    The parameter for `value` (see the module documentation for the types).
    Attributes are inferred: `@safe` except for `Variant`, whose copies are `@system`.

    Throws: `ClientException` for values Oracle can't hold (NaN is fine:
    BINARY_DOUBLE has it; a `Decimal` with more than 40 digits, dates outside
    -4712 to 9999).
    +/
    static Parameter of(T)(auto ref T value)
    {
        alias U = Unqual!T;
        static if (is(U == Parameter))
            return value;
        else static if (is(U == typeof(null)))
            return nullOf!string();
        else static if (is(U : Nullable!V, V))
            return value.isNull ? nullOf!V() : of(value.get);
        else static if (is(U == Variant))
            return ofVariant(value);
        else
            return make(value);
    }

    /// A NULL of the Oracle type for D type `T`.
    static Parameter nullOf(T)()
    {
        auto p = typeOf!(Unqual!T)();
        p.isNull = true;
        return p;
    }

    /++
    An IN OUT parameter with the type of `T` and the initial value
    `initial`; its value after the call is in the result's `outputs`.
    +/
    static Parameter inOut(T)(T initial)
    {
        auto p = of(initial);
        p.direction = BindDirection.inputOutput;
        p.bufferSize = outputSize(p.type, p.bufferSize);
        return p;
    }

    /++
    An OUT parameter (a PL/SQL `OUT` parameter or assignment target, or a
    `RETURNING ... INTO` target) of the Oracle type for D type `T`; its
    value after the call is in the result's `outputs`.
    +/
    static Parameter output(T)()
    {
        auto p = nullOf!T();
        p.direction = BindDirection.output;
        p.bufferSize = outputSize(p.type, p.bufferSize);
        return p;
    }

    /++
    An OUT parameter receiving a REF cursor (`SYS_REFCURSOR`); its rows are
    read through `Output.cursor` of the result's `outputs`.
    +/
    static Parameter refCursor() @safe pure nothrow
    {
        Parameter p;
        p.type = OracleType.cursor;
        p.bufferSize = 4;
        p.isNull = true;
        p.direction = BindDirection.output;
        return p;
    }

    /++
    A JSON parameter from JSON text, sent as JSON (Oracle's binary JSON,
    OSON), so the server doesn't parse text: for JSON columns, and for PL/SQL
    `JSON` parameters. Numbers are kept exactly (rounded to NUMBER's 40
    digits, as the server would), object members keep their order. Field
    names longer than 255 bytes need Oracle Database 23ai. Servers before
    21c get the text.

    Throws: `ClientException` if `text` isn't valid JSON.
    +/
    static Parameter json(string text) @safe
    {
        import oracle.types.oson : encodeOson;

        auto p = typed(OracleType.json, jsonMaxLength);
        p.data = encodeOson(text, true);
        return p;
    }

    /// This parameter bound by name: to the placeholder `:name`.
    Parameter named(string name) const @safe
    {
        Parameter p = this;
        p.name = name.length && name[0] == ':' ? name[1 .. $] : name;
        return p;
    }
}

///
@safe unittest
{
    const p = Parameter.of(42);
    assert(p.type == OracleType.number && p.data == [0xC1, 0x2B] && !p.isNull);
    assert(Parameter.of("Grüße").type == OracleType.varchar && Parameter.of("Grüße").data == "Grüße");
    assert(Parameter.of(1.5).type == OracleType.binaryDouble && Parameter.of(1.5f).type == OracleType.binaryFloat);
    assert(Parameter.of(Nullable!int()).isNull && Parameter.of(null).type == OracleType.varchar);
    assert(Parameter.output!long.direction == BindDirection.output && Parameter.of(7).named(":x").name == "x");
}

/// An empty parameter of type `t`.
private Parameter typed(OracleType t, uint bufferSize) @safe pure nothrow
{
    Parameter p;
    p.type = t;
    p.bufferSize = bufferSize;
    return p;
}

/// The size of an OUT or IN OUT parameter of type `t`: the type's largest value.
private uint outputSize(OracleType t, uint inputSize) @safe pure nothrow
{
    switch (t)
    {
    case OracleType.varchar:
    case OracleType.raw:
        return cast(uint) maxBindBytes;
    default:
        return inputSize;
    }
}

/++
A VECTOR parameter as its text, for servers without native VECTOR binds (TTC
field version below 23.4); other parameters as they are.
+/
package Parameter asTextVector(Parameter p) @safe
{
    import oracle.types.vector : decodeVector;

    if (p.type != OracleType.vector)
        return p;
    p.type = OracleType.varchar;
    if (!p.isNull)
        p.data = cast(immutable(ubyte)[]) decodeVector(p.data).toString();
    p.bufferSize = p.isNull ? 4 : cast(uint) p.data.length;
    return p;
}

/++
A JSON parameter as the server can take it: an OSON image from field version
21.1 (21c), its text before (the server parses it).

Throws: `ClientException` if the image has field names longer than 255 bytes
and the server is older than 23ai (field version 23.1).
+/
package Parameter asWireJson(Parameter p, ubyte fieldVersion) @safe
{
    import oracle.protocol.negotiate : TtcFieldVersion;
    import oracle.types.oson : osonToText;

    if (p.type != OracleType.json)
        return p;
    if (fieldVersion >= TtcFieldVersion.v21_1)
    {
        if (!p.isNull && p.data.length > 3 && p.data[3] == 3 && fieldVersion < TtcFieldVersion.v23_1)
            throw new ClientException("JSON field names longer than 255 bytes need Oracle Database 23ai");
        return p;
    }
    p.type = OracleType.varchar;
    if (!p.isNull)
        p.data = cast(immutable(ubyte)[]) osonToText(p.data);
    p.bufferSize = p.direction != BindDirection.input ? cast(uint) maxBindBytes : p.isNull ? 4 : cast(
            uint)(p.data.length < 0x1FFF_FFFF ? p.data.length * 4 : 0x7FFF_FFFF);
    return p;
}

/++
A BOOLEAN parameter as the NUMBER 1 or 0, for servers before 23ai (TTC field
version below 23.1); other parameters as they are.
+/
package Parameter asNumberBoolean(Parameter p) @safe
{
    import oracle.types.encode : encodeNumber;

    if (p.type != OracleType.boolean)
        return p;
    p.type = OracleType.number;
    p.bufferSize = 22;
    if (!p.isNull)
        p.data = encodeNumber(p.data.length && p.data[$ - 1] != 0 ? 1L : 0L);
    return p;
}

/// The type of parameters of D type `T`.
private Parameter typeOf(T)()
{
    static if (is(T == bool))
        return typed(OracleType.boolean, 4); // NUMBER for servers before 23ai (`asNumberBoolean`)
    else static if (isIntegral!T || is(T == Decimal))
        return typed(OracleType.number, 22);
    else static if (is(T == float))
        return typed(OracleType.binaryFloat, 4);
    else static if (isFloatingPoint!T)
        return typed(OracleType.binaryDouble, 8);
    else static if (isSomeString!T || isSomeChar!T)
        return typed(OracleType.varchar, 4);
    else static if (is(T : const(ubyte)[]) || is(T == UUID))
        return typed(OracleType.raw, 1);
    else static if (is(T == Date) || is(T == DateTime))
        return typed(OracleType.date, 7);
    else static if (is(T == SysTime))
        return typed(OracleType.timestampTz, 13);
    else static if (is(T == Duration))
        return typed(OracleType.intervalDs, 11);
    else static if (is(T == MonthInterval))
        return typed(OracleType.intervalYm, 5);
    else static if (is(T : Lob))
        return typed(OracleType.blob, 112);
    else static if (is(T == Vector) || is(T : const(float)[]) || is(T : const(double)[]))
        return typed(OracleType.vector, vectorMaxLength);
    else static if (is(T == JSONValue))
        return typed(OracleType.json, jsonMaxLength);
    else
        static assert(false, "Unsupported parameter type " ~ T.stringof);
}

private Parameter make(T)(T value)
{
    import std.conv : to;
    import oracle.types.encode;
    import oracle.types.vector : encodeVector;

    alias U = Unqual!T;
    auto p = typeOf!U();
    static if (is(U == bool))
        p.data = value ? [1, 1] : [0];
    else static if (is(U == ulong))
        p.data = encodeUnsignedNumber(value);
    else static if (isIntegral!U)
        p.data = encodeNumber(cast(long) value);
    else static if (is(U == Decimal))
        p.data = encodeNumber(value);
    else static if (is(U == float))
        p.data = encodeBinaryFloat(value);
    else static if (isFloatingPoint!U)
        p.data = encodeBinaryDouble(cast(double) value);
    else static if (isSomeString!U || isSomeChar!U)
    {
        static if (is(U == string))
            const text = value;
        else
            const text = value.to!string;
        p.data = cast(immutable(ubyte)[]) text;
        // room for the server's conversion of the UTF-8 text (as other clients size it)
        p.bufferSize = cast(uint)(text.length ? (text.length < 0x1FFF_FFFF ? text.length * 4 : 0x7FFF_FFFF) : 4);
    }
    else static if (is(U == UUID))
    {
        p.data = value.data.idup;
        p.bufferSize = 16;
    }
    else static if (is(U : const(ubyte)[]))
    {
        p.data = value.idup;
        p.bufferSize = cast(uint)(value.length ? value.length : 1);
    }
    else static if (is(U == Date))
        p.data = encodeDate(DateTime(value));
    else static if (is(U == DateTime))
        p.data = encodeDate(value);
    else static if (is(U == SysTime))
        p.data = encodeTimestampTz(value);
    else static if (is(U == Duration))
        p.data = encodeIntervalDs(value);
    else static if (is(U == MonthInterval))
        p.data = encodeIntervalYm(value);
    else static if (is(U == Vector))
        p.data = encodeVector(value);
    else static if (is(U == JSONValue))
    {
        import oracle.types.oson : encodeOson;

        p.data = encodeOson(value, true);
    }
    else static if (is(U : const(float)[]) || is(U : const(double)[]))
    {
        if (value.length)
            p.data = encodeVector(Vector.of(value));
    }
    else static if (is(U : Lob))
    {
        if (value is null)
            p.isNull = true;
        else
        {
            p.type = value.type;
            p.data = value.locator;
        }
    }
    if (p.data is null) // an empty string or array: NULL in Oracle
        p.isNull = true;
    return p;
}

// TypeInfo.opEquals is @system (it compares names and flags; nothing unsafe).
private bool sameType(const TypeInfo a, const TypeInfo b) @trusted
{
    return a == b;
}

private Parameter ofVariant(ref const Variant value) @safe
{
    import std.meta : AliasSeq;

    if (!value.hasValue)
        return Parameter.nullOf!string();
    static foreach (T; AliasSeq!(bool, byte, ubyte, short, ushort, int, uint, long, ulong, float, double, real,
            Decimal, string, wstring, dstring, char, ubyte[], immutable(ubyte)[], const(ubyte)[], UUID, Date,
            DateTime, SysTime, Duration, MonthInterval, Parameter, Lob, Vector, float[], double[], JSONValue))
        if (sameType(value.type, typeid(T)))
            return Parameter.of((() @trusted => value.get!T)()); // Variant.get is @system; the type was checked
    throw new ClientException("Unsupported Variant parameter type " ~ value.type.toString);
}

/++
The parameters for `args`, each converted with `Parameter.of`; a single
`Parameter[]` argument is taken as the parameters themselves.
+/
const(Parameter)[] parameters(Args...)(auto ref Args args)
{
    static if (Args.length == 1 && is(Args[0] : const(Parameter)[]) && !is(Args[0] == typeof(null)))
        return args[0];
    else
    {
        auto result = new Parameter[Args.length];
        foreach (i, ref arg; args)
            result[i] = Parameter.of(arg);
        return result;
    }
}

/// The bind placeholders of a statement.
struct Placeholders
{
    /// The names (upper case unless quoted), in order of appearance; numbers stay digits (`1`).
    string[] occurrences;
    /// The distinct names, in order of first appearance.
    string[] names;
    /// The names after `RETURNING ... INTO` (DML returning values).
    string[] returning;
}

/++
Finds the placeholders of `sql`, skipping string literals (also `q'[...]'`),
quoted identifiers, comments, and `:=`.
+/
Placeholders findPlaceholders(scope const(char)[] sql) @safe pure nothrow
{
    import std.algorithm.searching : canFind;
    import std.ascii : isAlpha, isAlphaNum, isDigit, toUpper;

    Placeholders p;
    bool afterReturning, afterInto;
    size_t i;
    while (i < sql.length)
    {
        const c = sql[i];
        if (c == '\'' || ((c == 'q' || c == 'Q') && i + 2 < sql.length && sql[i + 1] == '\''))
        {
            i = skipLiteral(sql, i);
            continue;
        }
        if (c == '"')
        {
            i++;
            while (i < sql.length && sql[i] != '"')
                i++;
            i++;
            continue;
        }
        if (c == '-' && i + 1 < sql.length && sql[i + 1] == '-')
        {
            while (i < sql.length && sql[i] != '\n')
                i++;
            continue;
        }
        if (c == '/' && i + 1 < sql.length && sql[i + 1] == '*')
        {
            i += 2;
            while (i + 1 < sql.length && !(sql[i] == '*' && sql[i + 1] == '/'))
                i++;
            i += 2;
            continue;
        }
        if (isAlpha(c) || c == '_')
        {
            // a keyword or identifier: watch for RETURNING ... INTO
            const start = i;
            while (i < sql.length && (isAlphaNum(sql[i]) || sql[i] == '_' || sql[i] == '$' || sql[i] == '#'))
                i++;
            char[16] word;
            const n = i - start < word.length ? i - start : 0;
            foreach (k; 0 .. n)
                word[k] = toUpper(sql[start + k]);
            if (word[0 .. n] == "RETURNING" || word[0 .. n] == "RETURN")
                afterReturning = true;
            else if (word[0 .. n] == "INTO" && afterReturning)
                afterInto = true;
            continue;
        }
        if (c == ':' && i + 1 < sql.length && sql[i + 1] != '=')
        {
            size_t j = i + 1;
            string name;
            if (sql[j] == '"')
            {
                const start = ++j;
                while (j < sql.length && sql[j] != '"')
                    j++;
                name = sql[start .. j].idup;
                j++;
            }
            else if (isAlpha(sql[j]) || isDigit(sql[j]))
            {
                const start = j;
                while (j < sql.length && (isAlphaNum(sql[j]) || sql[j] == '_' || sql[j] == '$' || sql[j] == '#'))
                    j++;
                name = asciiUpper(sql[start .. j]); // the unique result of a pure function converts to string
            }
            if (name.length)
            {
                p.occurrences ~= name;
                if (!p.names.canFind(name))
                    p.names ~= name;
                if (afterInto && !p.returning.canFind(name))
                    p.returning ~= name;
                i = j;
                continue;
            }
        }
        i++;
    }
    return p;
}

private char[] asciiUpper(scope const(char)[] s) @safe pure nothrow
{
    import std.ascii : toUpper;

    auto r = s.dup;
    foreach (ref c; r)
        c = toUpper(c);
    return r;
}

/// The index after the string literal starting at `i` (`'...'` with `''` escapes, or `q'X...X'`).
private size_t skipLiteral(scope const(char)[] sql, size_t i) @safe pure nothrow
{
    if (sql[i] != '\'')
    {
        // q'X...X': the closing quote follows the closing delimiter
        const open = sql[i + 2];
        const close = open == '[' ? ']' : open == '{' ? '}' : open == '(' ? ')' : open == '<' ? '>' : open;
        i += 3;
        while (i + 1 < sql.length && !(sql[i] == close && sql[i + 1] == '\''))
            i++;
        return i + 2;
    }
    i++;
    while (i < sql.length)
    {
        if (sql[i] == '\'')
        {
            if (i + 1 < sql.length && sql[i + 1] == '\'')
            {
                i += 2;
                continue;
            }
            return i + 1;
        }
        i++;
    }
    return i;
}

/++
Rewrites `?` placeholders as `:1`, `:2`, ... (outside literals, quoted
identifiers and comments) and counts them. Statements without `?` are
returned as they are.
+/
string rewritePlaceholders(string sql, out size_t count) @safe pure nothrow
{
    import std.conv : to;

    string result;
    size_t copied, i;
    while (i < sql.length)
    {
        const c = sql[i];
        if (c == '\'' || ((c == 'q' || c == 'Q') && i + 2 < sql.length && sql[i + 1] == '\''))
        {
            i = skipLiteral(sql, i);
            continue;
        }
        if (c == '"')
        {
            i++;
            while (i < sql.length && sql[i] != '"')
                i++;
            i++;
            continue;
        }
        if (c == '-' && i + 1 < sql.length && sql[i + 1] == '-')
        {
            while (i < sql.length && sql[i] != '\n')
                i++;
            continue;
        }
        if (c == '/' && i + 1 < sql.length && sql[i + 1] == '*')
        {
            i += 2;
            while (i + 1 < sql.length && !(sql[i] == '*' && sql[i + 1] == '/'))
                i++;
            i += 2;
            continue;
        }
        if (c == '?')
        {
            count++;
            result ~= sql[copied .. i] ~ ":" ~ count.to!string;
            copied = i + 1;
        }
        i++;
    }
    return count ? result ~ sql[copied .. $] : sql;
}

///
@safe unittest
{
    auto p = findPlaceholders("select :1, :Name, ':x' || q'[:y]' /* :z */, \"A:B\", :name -- :w\n from t where a := 1");
    assert(p.occurrences == ["1", "NAME", "NAME"] && p.names == ["1", "NAME"]);
    p = findPlaceholders("update t set a = :a where id = :id returning a, b into :ra, :rb");
    assert(p.names == ["A", "ID", "RA", "RB"] && p.returning == ["RA", "RB"]);
    assert(findPlaceholders("begin :x := :y + :\"z\"; end;").names == ["X", "Y", "z"]);

    size_t n;
    assert(rewritePlaceholders("select ?, '?', ? from dual -- ?", n) == "select :1, '?', :2 from dual -- ?" && n == 2);
    assert(rewritePlaceholders("select 1 from dual", n) == "select 1 from dual" && n == 0);
}
