/++
Oracle data type numbers and column metadata.

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module oracle.types.typeinfo;

/// Oracle data type numbers, as in describe information.
enum OracleType : ubyte
{
    varchar = 1, /// VARCHAR2, NVARCHAR2
    number = 2, /// NUMBER, FLOAT
    long_ = 8, /// LONG
    rowid = 11, /// ROWID
    date = 12, /// DATE
    raw = 23, /// RAW
    longRaw = 24, /// LONG RAW
    char_ = 96, /// CHAR, NCHAR
    binaryFloat = 100, /// BINARY_FLOAT
    binaryDouble = 101, /// BINARY_DOUBLE
    cursor = 102, /// REF CURSOR
    object = 109, /// object types, XMLType
    clob = 112, /// CLOB, NCLOB
    blob = 113, /// BLOB
    bfile = 114, /// BFILE
    json = 119, /// JSON (21c)
    vector = 127, /// VECTOR (23ai)
    timestamp = 180, /// TIMESTAMP
    timestampTz = 181, /// TIMESTAMP WITH TIME ZONE
    intervalYm = 182, /// INTERVAL YEAR TO MONTH
    intervalDs = 183, /// INTERVAL DAY TO SECOND
    urowid = 208, /// UROWID
    timestampLtz = 231, /// TIMESTAMP WITH LOCAL TIME ZONE
    boolean = 252, /// BOOLEAN (23ai)
}

/// Character set forms.
enum CharsetForm : ubyte
{
    none = 0, /// not character data
    implicit = 1, /// the database character set (VARCHAR2, CHAR, CLOB)
    nchar = 2, /// the national character set (NVARCHAR2, NCHAR, NCLOB)
}

/// The metadata of a result column.
struct ColumnInfo
{
    /// Column name (as the server reports it: upper case unless quoted).
    string name;
    /// The data type.
    OracleType type;
    /// NUMBER precision (0: not given), or the fractional-second precision of timestamps.
    byte precision;
    /// NUMBER scale (-127: not given, a floating-point NUMBER).
    byte scale;
    /// Maximum size in bytes.
    uint bufferSize;
    /// Maximum size in characters for character data.
    uint maxSize;
    /// Character set ID of character data.
    ushort charsetId;
    /// Character set form.
    CharsetForm charsetForm;
    /// Whether the column may be NULL.
    bool nullable;
    /// Owner and name of an object type.
    string typeSchema;
    /// ditto
    string typeName;
    /// Owner and name of the column's SQL domain (23ai), if any.
    string domainSchema;
    /// ditto
    string domainName;
    /// The column's annotations (23ai): name and value (empty when it has none).
    immutable(string[2])[] annotations;
    /// Whether the column holds JSON: the JSON type, or a column with an `IS JSON` check.
    bool isJson;
    /// Whether the values are binary JSON (OSON): the JSON type, also as a BLOB for older clients.
    bool isOson;
    /// VECTOR columns (23ai): the number of dimensions (0: any).
    uint vectorDimensions;
    /// VECTOR columns: the element format (`VectorFormat`; 0: any).
    ubyte vectorFormat;
    /// VECTOR columns: flags (sparse vectors: 0x02).
    ubyte vectorFlags;
    /// The type the column is fetched as (LOBs: as LONG / LONG RAW values or as locators); none: `type`.
    package(oracle) OracleType fetchType = cast(OracleType) 0;

    /// The type the values arrive as.
    @property OracleType wireType() const @safe pure nothrow
    {
        return fetchType ? fetchType : type;
    }

    /// Whether the column is a LOB (CLOB, NCLOB, BLOB, BFILE).
    @property bool isLob() const @safe pure nothrow
    {
        return type == OracleType.clob || type == OracleType.blob || type == OracleType.bfile;
    }

    /// The type's name in SQL, e.g. `NUMBER(10,2)`, `VARCHAR2(30)`.
    string typeText() const @safe pure nothrow
    {
        import std.conv : to;

        switch (type)
        {
        case OracleType.varchar:
            return (charsetForm == CharsetForm.nchar ? "NVARCHAR2(" : "VARCHAR2(") ~ maxSize.to!string ~ ")";
        case OracleType.char_:
            return (charsetForm == CharsetForm.nchar ? "NCHAR(" : "CHAR(") ~ maxSize.to!string ~ ")";
        case OracleType.number:
            if (precision == 0) // no precision: NUMBER, or NUMBER(*,s) with a scale
                return scale == -127 ? "NUMBER" : "NUMBER(*," ~ scale.to!string ~ ")";
            if (scale == -127)
                return "FLOAT(" ~ precision.to!string ~ ")";
            return "NUMBER(" ~ precision.to!string ~ "," ~ scale.to!string ~ ")";
        case OracleType.long_:
            return "LONG";
        case OracleType.rowid:
            return "ROWID";
        case OracleType.date:
            return "DATE";
        case OracleType.raw:
            return "RAW(" ~ bufferSize.to!string ~ ")";
        case OracleType.longRaw:
            return "LONG RAW";
        case OracleType.binaryFloat:
            return "BINARY_FLOAT";
        case OracleType.binaryDouble:
            return "BINARY_DOUBLE";
        case OracleType.cursor:
            return "REF CURSOR";
        case OracleType.object:
            return typeSchema.length ? typeSchema ~ "." ~ typeName : typeName;
        case OracleType.clob:
            return charsetForm == CharsetForm.nchar ? "NCLOB" : "CLOB";
        case OracleType.blob:
            return "BLOB";
        case OracleType.bfile:
            return "BFILE";
        case OracleType.json:
            return "JSON";
        case OracleType.vector:
            return "VECTOR";
        case OracleType.timestamp:
            return "TIMESTAMP(" ~ scale.to!string ~ ")";
        case OracleType.timestampTz:
            return "TIMESTAMP(" ~ scale.to!string ~ ") WITH TIME ZONE";
        case OracleType.intervalYm:
            return "INTERVAL YEAR(" ~ precision.to!string ~ ") TO MONTH";
        case OracleType.intervalDs:
            return "INTERVAL DAY(" ~ precision.to!string ~ ") TO SECOND(" ~ scale.to!string ~ ")";
        case OracleType.urowid:
            return "UROWID";
        case OracleType.timestampLtz:
            return "TIMESTAMP(" ~ scale.to!string ~ ") WITH LOCAL TIME ZONE";
        case OracleType.boolean:
            return "BOOLEAN";
        default:
            return "TYPE " ~ (cast(int) type).to!string;
        }
    }
}

///
@safe unittest
{
    ColumnInfo c;
    c.type = OracleType.number;
    c.precision = 10;
    c.scale = 2;
    assert(c.typeText == "NUMBER(10,2)");
    c.type = OracleType.varchar;
    c.maxSize = 30;
    assert(c.typeText == "VARCHAR2(30)");
}
