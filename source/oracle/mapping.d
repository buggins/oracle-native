/++
Struct mapping: rows read into structs, structs inserted as rows.

Fields map to columns by name (case-insensitive: Oracle names are upper case
unless quoted); `@column("name")` gives a field another column name and
`@ignore` leaves it out. Result columns without a field are ignored.

Field types: `bool`, integers, `float`/`double`, `string`, `ubyte[]`,
`Decimal`, `Date`, `TimeOfDay`, `DateTime`, `SysTime`, `Duration` (INTERVAL
DAY TO SECOND), `MonthInterval` (INTERVAL YEAR TO MONTH), `UUID` (RAW(16)),
`Variant`, enums (from numbers, or from text columns holding their names or
values; `insert` writes their values), and `Nullable!T` of these. A NULL read
into a field that isn't `Nullable` gives its zero value, as the getters do.

Example:
---
struct Order
{
    int id;
    @column("customer_name") string customer;
    Decimal amount;
    Nullable!DateTime shipped;
    @ignore string note;
}

conn.insert("orders", [Order(1, "Ann", Decimal.fromString("9.90"))]);
conn.commit();
foreach (o; conn.query!Order("SELECT * FROM orders WHERE amount > :1", 5))
    writeln(o.customer, " ", o.amount);
auto total = conn.queryValue!long("SELECT COUNT(*) FROM orders");
---

The templates infer their attributes (`Variant` copies are `@system`).

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module oracle.mapping;

import core.time : Duration;
import std.datetime.date : Date, DateTime, TimeOfDay;
import std.datetime.systime : SysTime;
import std.traits : FieldNameTuple, getUDAs, hasUDA, isFloatingPoint, isIntegral, isSomeString, Unqual;
import std.typecons : Nullable;
import std.uuid : UUID;
import std.variant : Variant;
import dbwire.types.decimal : Decimal;
import dbwire.types.interval : MonthInterval;
import oracle.exception : ClientException;
import oracle.params : Parameter;
import oracle.result : QueryResult;
import oracle.value : Value;

/// The value of a `@column("name")` attribute.
struct ColumnName
{
    /// The column name.
    string name;
}

/// The type of the `@ignore` attribute.
struct IgnoreField
{
}

/// UDA: maps a field to the column `name` (instead of the field's name).
ColumnName column(string name) @safe pure nothrow
{
    return ColumnName(name);
}

/// UDA: leaves a field out of the mapping.
enum ignore = IgnoreField();

/// The column names of the mapped fields of `T`, in field order.
template columnNames(T) if (is(T == struct))
{
    enum string[] columnNames = () {
        string[] names;
        static foreach (name; FieldNameTuple!T)
        {
            static if (!hasUDA!(__traits(getMember, T, name), IgnoreField))
            {
                static if (hasUDA!(__traits(getMember, T, name), ColumnName))
                    names ~= getUDAs!(__traits(getMember, T, name), ColumnName)[0].name;
                else
                    names ~= name;
            }
        }
        return names;
    }();
}

///
@safe unittest
{
    static struct S
    {
        int id;
        @column("full_name") string name;
        @ignore int cache;
    }

    static assert(columnNames!S == ["id", "full_name"]);
}

/++
`v` converted to the field type `T` (see the module documentation).

Throws: `ClientException` if the column's type can't be converted to `T`, or the value doesn't fit.
+/
T readValue(T)(const Value v)
{
    import std.conv : ConvException, to;

    alias U = Unqual!T;
    static if (is(U : Nullable!N, N))
        return v.isNull ? T.init : T(readValue!N(v));
    else static if (is(U == Variant))
        return v.getVariant();
    else static if (is(U == enum))
    {
        if (v.isNull)
            return T.init;
        long n;
        if (isTextColumn(v))
        {
            // the member's name, or its value in decimal (as `insert` writes enums)
            const text = v.getString();
            static foreach (member; __traits(allMembers, U)) // names compared without std.conv (no exceptions)
                if (text == member)
                    return __traits(getMember, U, member);
            try
                n = text.to!long;
            catch (ConvException)
                throw new ClientException("'" ~ text ~ "' is not a value of " ~ T.stringof);
        }
        else
            n = v.getLong();
        foreach (member; __traits(allMembers, T))
            if (__traits(getMember, T, member) == n)
                return __traits(getMember, T, member);
        throw new ClientException(n.to!string ~ " is not a value of " ~ T.stringof);
    }
    else static if (is(U == bool))
        return v.getBool();
    else static if (isIntegral!U)
    {
        const n = v.getLong();
        if (n < U.min || (U.max <= long.max && n > cast(long) U.max))
            throw new ClientException("Value " ~ n.to!string ~ " does not fit in " ~ U.stringof);
        return cast(T) n;
    }
    else static if (isFloatingPoint!U)
        return cast(T) v.getDouble();
    else static if (isSomeString!U)
        return v.getString().to!T;
    else static if (is(U : const(ubyte)[]))
    {
        static if (is(immutable(ubyte)[] : T))
            return v.getBytes();
        else
            return v.getBytes().dup; // a mutable copy: the row's bytes are immutable
    }
    else static if (is(U == Decimal))
        return v.getDecimal();
    else static if (is(U == Date))
        return v.getDate();
    else static if (is(U == TimeOfDay))
        return v.getTime();
    else static if (is(U == Duration))
        return v.getDuration();
    else static if (is(U == MonthInterval))
        return v.getMonthInterval();
    else static if (is(U == DateTime))
        return v.getDateTime();
    else static if (is(U == SysTime))
        return v.getSysTime();
    else static if (is(U == UUID))
    {
        if (v.isNull)
            return UUID.init;
        const b = v.getBytes();
        if (b.length != 16)
            throw new ClientException("A UUID needs 16 bytes, the column has " ~ b.length.to!string);
        ubyte[16] data = b[0 .. 16];
        return UUID(data);
    }
    else
        static assert(0, "Fields of type " ~ T.stringof ~ " can't be read");
}

private bool isTextColumn(const Value v) @safe
{
    import oracle.types.typeinfo : OracleType;

    switch (v.column.type)
    {
    case OracleType.varchar:
    case OracleType.char_:
    case OracleType.long_:
    case OracleType.clob:
        return true;
    default:
        return false;
    }
}

/++
For each mapped field of `T`, the index of its column in `result`.

Throws: `ClientException` (after closing the result, so the connection is
released) if a field has no column.
+/
size_t[] fieldPositions(T)(QueryResult result)
{
    import std.uni : icmp;

    enum names = columnNames!T;
    auto positions = new size_t[names.length];
    foreach (i, name; names)
    {
        bool found;
        foreach (c, col; result.columns)
            if (icmp(col.name, name) == 0)
            {
                positions[i] = c;
                found = true;
                break;
            }
        if (!found)
        {
            result.close();
            throw new ClientException("The result has no column '" ~ name ~ "' for field " ~ T.stringof ~ "."
                    ~ name);
        }
    }
    return positions;
}

/// The current row of `result` as a `T`, with the columns at `positions` (from `fieldPositions`).
T readStruct(T)(QueryResult result, const size_t[] positions)
{
    T value;
    size_t i;
    const row = result.front;
    static foreach (name; FieldNameTuple!T)
    {
        static if (!hasUDA!(__traits(getMember, T, name), IgnoreField))
        {
            __traits(getMember, value, name) = readValue!(typeof(__traits(getMember, T, name)))(
                    row[positions[i]]);
            i++;
        }
    }
    return value;
}

/++
The rows of a result as `T`s: an input range (`Connection.query!T`). Like the
result, it holds the connection until all rows are read or `close` is called.
+/
struct RowRange(T) if (is(T == struct))
{
    private QueryResult result;
    private size_t[] positions;

    /// Maps the rows of `result`.
    this(QueryResult result)
    {
        this.result = result;
        positions = fieldPositions!T(result);
    }

    /// Whether there are no more rows.
    @property bool empty()
    {
        return result.empty;
    }

    /// The current row. A value that doesn't convert closes the result (a `foreach` has no other way to).
    @property T front()
    {
        try
            return readStruct!T(result, positions);
        catch (Exception e)
        {
            result.close();
            throw e;
        }
    }

    /// Moves to the next row.
    void popFront()
    {
        result.popFront();
    }

    /// Releases the connection; remaining rows are discarded.
    void close()
    {
        result.close();
    }

    /// The underlying result (row counts, columns).
    @property QueryResult queryResult()
    {
        return result;
    }
}

/// The parameters of the mapped fields of `value`, in field order.
package Parameter[] fieldParameters(T)(const ref T value)
{
    auto params = new Parameter[columnNames!T.length];
    fillFieldParameters(value, params);
    return params;
}

/// The parameters of `value`'s mapped fields written into `params` (`columnNames!T.length` of them).
package void fillFieldParameters(T)(const ref T value, Parameter[] params)
{
    size_t i;
    static foreach (name; FieldNameTuple!T)
    {
        static if (!hasUDA!(__traits(getMember, T, name), IgnoreField))
            params[i++] = Parameter.of(__traits(getMember, value, name));
    }
}

/++
`name` as an identifier in SQL: as it is when it is a plain name (Oracle
compares those case-insensitively), else in double quotes (case-sensitive).
+/
package string quoteIdentifier(string name) @safe pure nothrow
{
    import std.ascii : isAlpha, isAlphaNum;

    bool plain = name.length > 0 && isAlpha(name[0]);
    foreach (c; name)
        plain = plain && (isAlphaNum(c) || c == '_' || c == '$' || c == '#');
    return plain ? name : `"` ~ name ~ `"`;
}

///
@safe unittest
{
    assert(quoteIdentifier("order_id") == "order_id" && quoteIdentifier("Order Date") == `"Order Date"`);
}
