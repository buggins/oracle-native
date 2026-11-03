/// Newer types: native BOOLEAN, JSON (21c), VECTOR (23ai), and the 23ai column metadata.
module integrationtests.modern;

import std.algorithm.searching : canFind;
import std.conv : to;
import std.exception : collectException, enforce;
import std.json : JSONType;
import std.typecons : Nullable;

import oracle;
import integrationtests.server;

/// The major version of the server.
private int majorVersion(Connection conn)
{
    import std.algorithm.searching : findSplitBefore;

    return conn.serverVersion.findSplitBefore(".")[0].to!int;
}

/// `bool` parameters: BOOLEAN on 23ai (columns, PL/SQL), NUMBER 1/0 on older servers.
void testNativeBooleans()
{
    auto conn = connectToServer();
    scope (exit)
        conn.close();
    auto r = conn.query("SELECT :1, :2, :3 FROM dual", true, false, Nullable!bool());
    const row = r.front;
    const native = majorVersion(conn) >= 23;
    enforce(row.columns[0].type == (native ? OracleType.boolean : OracleType.number), "bind type");
    enforce(row.getBool(0) && !row.getBool(1) && row.isNull(2), "values");
    enforce(row.getString(0) == (native ? "true" : "1"), "text: " ~ row.getString(0));
    r.close();

    dropTable(conn, "itest_nbool");
    conn.exec("CREATE TABLE itest_nbool (id NUMBER, n NUMBER(1)" ~ (native ? ", b BOOLEAN" : "") ~ ")");
    conn.exec("INSERT INTO itest_nbool (id, n) VALUES (:1, :2)", 1, true); // into a NUMBER column
    conn.exec("INSERT INTO itest_nbool (id, n) VALUES (:1, :2)", 2, false);
    enforce(conn.queryValue!long("SELECT id FROM itest_nbool WHERE n = :1", true) == 1, "NUMBER column");
    if (native)
    {
        conn.exec("UPDATE itest_nbool SET b = :1 WHERE id = :2", true, 1);
        conn.exec("UPDATE itest_nbool SET b = :1 WHERE id = :2", Nullable!bool(), 2);
        enforce(conn.queryValue!long("SELECT id FROM itest_nbool WHERE b = :1", true) == 1, "BOOLEAN column");
        enforce(conn.queryValue!(Nullable!bool)("SELECT b FROM itest_nbool WHERE id = 2").isNull, "NULL");
        auto p = conn.query("BEGIN :o := NOT :i; END;", Parameter.output!bool, false);
        enforce(p.output(0).column.type == OracleType.boolean && p.output(0).getBool(), "PL/SQL BOOLEAN");
        auto io = conn.query("BEGIN :x := :x OR :y; END;", Parameter.inOut(false), true);
        enforce(io.output(0).getBool(), "IN OUT BOOLEAN");
    }
    conn.rollback();
    dropTable(conn, "itest_nbool");
}

/// JSON columns (21c): texts as JSON_SERIALIZE writes them, std.json values, NULLs, big and wide documents.
void testJson()
{
    import std.array : join, replicate;
    import std.range : iota;
    import std.algorithm.iteration : map;

    auto conn = connectToServer();
    scope (exit)
        conn.close();
    if (majorVersion(conn) < 21)
        return;
    dropTable(conn, "itest_json");
    conn.exec("CREATE TABLE itest_json (id NUMBER, j JSON, t VARCHAR2(200) CHECK (t IS JSON))");
    string[] docs = [
        `{"a":1,"b":[true,false,null,"x"],"c":{"d":-12.5,"e":""}}`,
        `[1,2.5,-0.001,123456789012345678901234567890,1e100]`,
        // plain up to 40 digits before and after the point, else 1.5E-40
        `[1e39,1e40,12345678901234567890123456789012345678901,1e-40,1.5e-40,`
        ~ `0.000123456789012345678901234567890123456789,-1e100]`,
        `"just a string"`, `42`, `null`, `true`, `{}`, `[]`,
        `{"text":"quotes \" backslash \\ newline \n tab \t unicode Grüße мир 😀 control \u0001"}`,
        `{"deep":[[[[[[[[[[{"x":[1]}]]]]]]]]]]}`,
        // many fields (field IDs wider than one byte)
        "{" ~ iota(300).map!(i => `"f` ~ i.to!string ~ `":` ~ i.to!string).join(",") ~ "}",
        // a big document (offsets wider than 16 bits)
        `{"big":[` ~ iota(20_000).map!(i => `"value ` ~ i.to!string ~ `"`).join(",") ~ `]}`,
    ];
    if (majorVersion(conn) >= 23)
        docs ~= `{"` ~ "n".replicate(300) ~ `":1}`; // field names longer than 255 bytes (OSON version 3)
    foreach (i, d; docs)
    {
        if (d.length <= 32_767)
        {
            conn.exec("INSERT INTO itest_json (id, j) VALUES (:1, JSON(:2))", i, d);
            continue;
        }
        auto lob = conn.createLob(OracleType.clob); // longer texts: through a CLOB
        lob.writeText(d);
        conn.exec("INSERT INTO itest_json (id, j) VALUES (:1, JSON(:2))", i, lob);
        lob.free();
    }
    // extended types, built by the server
    conn.exec("INSERT INTO itest_json (id, j) VALUES (100, JSON_OBJECT('d' VALUE DATE '2024-01-31',"
            ~ " 'ts' VALUE TIMESTAMP '2024-01-31 12:00:00.123456', 'tz' VALUE TIMESTAMP '2024-01-31 12:00:00 -08:00',"
            ~ " 'f' VALUE 1.5f, 'bd' VALUE 0.1d, 'r' VALUE HEXTORAW('0A0B'),"
            ~ " 'ds' VALUE INTERVAL '-1 02:03:04.5' DAY TO SECOND, 'ym' VALUE INTERVAL '-1-2' YEAR TO MONTH,"
            ~ " 'ym0' VALUE INTERVAL '0-0' YEAR TO MONTH, 'bd2' VALUE 1e-5d, 'bd3' VALUE 1e300d, 'bd4' VALUE 100d,"
            ~ " 'bf' VALUE 3.4e38f RETURNING JSON))");
    conn.exec("INSERT INTO itest_json (id, j, t) VALUES (101, NULL, '{\"x\":1}')");

    size_t n;
    foreach (row; conn.query("SELECT id, j, JSON_SERIALIZE(j RETURNING CLOB), t FROM itest_json ORDER BY id"))
    {
        n++;
        if (row.isNull(1))
        {
            enforce(row.getString(1) is null && row.getJson(1).type == JSONType.null_, "NULL JSON");
            enforce(row.columns[3].isJson && row.getString(3) == `{"x":1}`, "IS JSON column");
            continue;
        }
        enforce(row.columns[1].type == OracleType.json, "JSON type");
        const expected = row.getString(2);
        const got = row.getString(1);
        enforce(got == expected, "document " ~ row.getString(0) ~ ": " ~ (got.length > 200 ? got[0 .. 200] : got)
                ~ " vs " ~ (expected.length > 200 ? expected[0 .. 200] : expected));
    }
    enforce(n == docs.length + 2, "rows");
    const first = conn.queryRow!JsonRow("SELECT j FROM itest_json WHERE id = 0");
    auto v = conn.query("SELECT j FROM itest_json WHERE id = 0").front.getJson(0);
    enforce(v["a"].integer == 1 && v["b"][3].str == "x" && v["c"]["d"].floating == -12.5, "std.json value");
    enforce(first.j == docs[0], "mapped to a string");
    conn.rollback();
    dropTable(conn, "itest_json");
}

private struct JsonRow
{
    string j;
}

/++
JSON binds: JSON text (`Parameter.json`) and `std.json` values sent as OSON
images (21c and later) give the documents the server makes of the same text;
OUT and IN OUT JSON, `RETURNING ... INTO`; older servers get the text.
+/
void testJsonBinds()
{
    import std.array : join, replicate;
    import std.algorithm.iteration : map;
    import std.json : JSONValue, parseJSON;
    import std.range : iota;

    auto conn = connectToServer();
    scope (exit)
        conn.close();
    const major = majorVersion(conn);
    dropTable(conn, "itest_jsonb");
    if (major < 21)
    {
        // JSON text for an IS JSON column
        conn.exec("CREATE TABLE itest_jsonb (id NUMBER, j CLOB CHECK (j IS JSON))");
        conn.exec("INSERT INTO itest_jsonb VALUES (1, :1)", Parameter.json(`{"a": [1, 2.50, "x"]}`));
        conn.exec("INSERT INTO itest_jsonb VALUES (2, :1)", parseJSON(`{"b":true,"a":null}`));
        enforce(scalar(conn, "SELECT j FROM itest_jsonb WHERE id = 1") == `{"a":[1,2.5,"x"]}`, "text for 18c");
        enforce(scalar(conn, "SELECT j FROM itest_jsonb WHERE id = 2") == `{"a":null,"b":true}`, "std.json text");
        dropTable(conn, "itest_jsonb");
        return;
    }
    conn.exec("CREATE TABLE itest_jsonb (id NUMBER, j JSON)");
    string[] docs = [
        `{"a":1,"b":[true,false,null,"x"],"c":{"d":-12.5,"e":""}}`,
        `{"z":1,"a":2,"m":{"y":[],"b":{}}}`,
        `[1,2.5,-0.001,123456789012345678901234567890,1e100,-0,1.50]`,
        // rounded to NUMBER's precision, as the server does
        `[0.99999999999999999999999999999999999999999,12345678901234567890123456789012345678951]`,
        `"just a string"`, `42`, `null`, `true`, `{}`, `[]`,
        `{"text":"quotes \" backslash \\ newline \n tab \t unicode Grüße мир 😀 \u00e9\ud83d\ude00 control \u0001"}`,
        `{"deep":[[[[[[[[[[{"x":[1]}]]]]]]]]]]}`,
        "{" ~ iota(300).map!(i => `"f` ~ i.to!string ~ `":` ~ i.to!string).join(",") ~ "}",
        "[" ~ iota(300).map!(i => `{"k` ~ (i % 7).to!string ~ `":` ~ i.to!string ~ `}`).join(",") ~ "]",
        `{"big":[` ~ iota(20_000).map!(i => `"value ` ~ i.to!string ~ `"`).join(",") ~ `]}`,
    ];
    const longName = `{"` ~ "n".replicate(300) ~ `":1,"s":[2]}`;
    if (major >= 23)
        docs ~= [longName, `[1e126,1e-131,-1e200]`]; // BINARY_DOUBLE outside NUMBER's range (21c: overflow)
    else
        enforce(collectException!ClientException(conn.exec("INSERT INTO itest_jsonb VALUES (0, :1)",
                Parameter.json(longName))) !is null, "names over 255 bytes refused before 23ai");
    enforce(collectException!ClientException(Parameter.json(`{"dup":1,"dup":2}`)) !is null, "repeated names");
    foreach (i, d; docs)
        conn.exec("INSERT INTO itest_jsonb VALUES (:1, :2)", i, Parameter.json(d)); // re-executed: cached cursor
    foreach (i, d; docs)
    {
        // the server's document of the same text
        auto lob = conn.createLob(OracleType.clob);
        lob.writeText(d);
        const expected = conn.queryValue!string("SELECT JSON_SERIALIZE(JSON(:1) RETURNING CLOB) FROM dual", lob);
        lob.free();
        auto r = conn.query("SELECT j, JSON_SERIALIZE(j RETURNING CLOB) FROM itest_jsonb WHERE id = :1", i);
        const row = r.front;
        const shown = row.getString(1);
        const got = row.getString(0);
        r.close();
        // the server's parser puts the members of bigger objects in field ID order; images from the
        // client keep the given order (and the server finds members either way)
        const same = shown == expected || (shown.length > 1000 && parseJSON(shown) == parseJSON(expected));
        enforce(same, "document " ~ i.to!string ~ ": " ~ (shown.length > 200 ? shown[0 .. 200] : shown) ~ " vs "
                ~ (
                    expected.length > 200 ? expected[0 .. 200] : expected));
        enforce(got == shown, "document " ~ i.to!string ~ " decoded: " ~ (got.length > 200 ? got[0 .. 200] : got));
    }

    // std.json values (members in name order)
    const value = parseJSON(`{"b":[1.5,-2,"s",true,null,0.1,1e300],"a":{"x":12345678901234}}`);
    conn.exec("INSERT INTO itest_jsonb VALUES (1000, :1)", value);
    conn.exec("INSERT INTO itest_jsonb VALUES (1001, :1)", Parameter.nullOf!JSONValue());
    conn.exec("INSERT INTO itest_jsonb VALUES (1002, :1)", Nullable!JSONValue(JSONValue("s")));
    enforce(scalar(conn, "SELECT JSON_SERIALIZE(j) FROM itest_jsonb WHERE id = 1000")
            == `{"a":{"x":12345678901234},"b":[1.5,-2,"s",true,null,0.1,1E+300]}`, "std.json value");
    enforce(conn.query("SELECT j FROM itest_jsonb WHERE id = 1000").front.getJson(0) == value, "read back");
    enforce(scalar(conn, "SELECT COUNT(*) FROM itest_jsonb WHERE id = 1001 AND j IS NULL") == "1", "SQL NULL");
    enforce(scalar(conn, "SELECT JSON_SERIALIZE(j) FROM itest_jsonb WHERE id = 1002") == `"s"`, "Nullable");
    // members found in an object of many members in the given order
    enforce(scalar(conn, "SELECT JSON_VALUE(j, '$.f257') FROM itest_jsonb WHERE id = 12") == "257", "lookup");
    enforce(conn.queryValue!string("SELECT JSON_VALUE(:1, '$.a.x') FROM dual", value) == "12345678901234",
            "JSON_VALUE");

    // RETURNING INTO, PL/SQL OUT, IN and IN OUT
    auto ret = conn.query("UPDATE itest_jsonb SET j = :1 WHERE id = 1000 RETURNING j INTO :2",
            Parameter.json(`{"updated":[1,2]}`), Parameter.output!JSONValue());
    enforce(ret.outputs[0].value.getString() == `{"updated":[1,2]}`, "RETURNING INTO");
    enforce(ret.outputs[0].value.getJson()["updated"][1].integer == 2, "RETURNING INTO as std.json");
    auto o = conn.query("BEGIN :1 := JSON_OBJECT('k' VALUE :2 RETURNING JSON); END;", Parameter.output!JSONValue(), 42);
    enforce(o.outputs[0].value.getString() == `{"k":42}`, "PL/SQL OUT");
    auto inp = conn.query("DECLARE j JSON := :1; BEGIN :2 := JSON_SERIALIZE(j); END;",
            Parameter.json(`[1,{"q":"w"}]`), Parameter.output!string());
    enforce(inp.outputs[0].value.getString() == `[1,{"q":"w"}]`, "PL/SQL IN");
    inp = conn.query("DECLARE j JSON := :1; BEGIN :2 := JSON_SERIALIZE(j); END;", parseJSON(`{"r":[true]}`),
            Parameter.output!string()); // again: re-executed
    enforce(inp.outputs[0].value.getString() == `{"r":[true]}`, "PL/SQL IN, re-executed");
    auto io = conn.query("DECLARE o JSON_OBJECT_T := JSON_OBJECT_T(:1); BEGIN o.put('n', 7); :1 := o.to_json; END;",
            Parameter.inOut(parseJSON(`{"a":1}`)));
    enforce(io.outputs[0].value.getString() == `{"a":1,"n":7}`, "PL/SQL IN OUT: " ~ io.outputs[0].value.getString());
    conn.rollback();
    dropTable(conn, "itest_jsonb");
}

/// VECTOR columns and binds (23ai): every format, sparse vectors, texts as FROM_VECTOR writes them.
void testVectors()
{
    auto conn = connectToServer();
    scope (exit)
        conn.close();
    if (majorVersion(conn) < 23)
        return;
    dropTable(conn, "itest_vec");
    conn.exec("CREATE TABLE itest_vec (id NUMBER, f32 VECTOR(3, FLOAT32), f64 VECTOR(*, FLOAT64),"
            ~ " i8 VECTOR(3, INT8), bin VECTOR(16, BINARY), sp VECTOR(6, FLOAT32, SPARSE), anyv VECTOR)");
    Vector sparse;
    sparse.sparse = true;
    sparse.dimensions = 6;
    sparse.indices = [0, 4];
    sparse.float32s = [1.5f, -2];
    conn.exec("INSERT INTO itest_vec VALUES (1, :1, :2, :3, :4, :5, :6)", [1.5f, -0.1f, 3.4e38f],
            [0.1, 1e-300, -2.5], Vector.of(cast(byte[])[1, -2, 127]), Vector.ofBits([0xF0, 0x0F]), sparse,
            [1.0, 2.0]);
    conn.exec("INSERT INTO itest_vec VALUES (2, TO_VECTOR('[1,2,3]', 3, FLOAT32), NULL, NULL, NULL,"
            ~ " TO_VECTOR('[6,[1,5],[3,4]]', 6, FLOAT32, SPARSE), TO_VECTOR('[7]'))");
    conn.exec("INSERT INTO itest_vec (id, f32) VALUES (3, :1)", Parameter.nullOf!Vector);
    foreach (row; conn.query("SELECT id, f32, f64, i8, bin, sp, anyv, FROM_VECTOR(f32), FROM_VECTOR(f64),"
            ~ " FROM_VECTOR(i8), FROM_VECTOR(bin), FROM_VECTOR(sp), FROM_VECTOR(anyv) FROM itest_vec ORDER BY id"))
    {
        foreach (c; 1 .. 7)
        {
            enforce(row.columns[c].type == OracleType.vector, "VECTOR type");
            enforce(row.getString(c) == row.getString(c + 6), "text of " ~ row.columns[c].name ~ " in row "
                    ~ row.getString(0) ~ ": " ~ row.getString(c) ~ " vs " ~ row.getString(c + 6));
        }
    }
    auto first = conn.query("SELECT f32, f64, i8, bin, sp, anyv FROM itest_vec WHERE id = 1").front;
    enforce(first.columns[0].vectorDimensions == 3 && first.columns[0].vectorFormat == VectorFormat.float32,
            "VECTOR(3, FLOAT32) metadata");
    enforce(first.columns[3].vectorFormat == VectorFormat.binary && first.columns[5].vectorDimensions == 0,
            "BINARY and flexible metadata");
    enforce(first.getVector(0).float32s == [1.5f, -0.1f, 3.4e38f], "float32");
    enforce(first.getVector(1).float64s == [0.1, 1e-300, -2.5], "float64");
    enforce(first.getVector(2).int8s == [1, -2, 127] && first.getVector(3).binary == [0xF0, 0x0F], "int8, binary");
    const sp = first.getVector(4);
    enforce(sp.sparse && sp.indices == [0, 4] && sp.toDoubles() == [1.5, 0, 0, 0, -2, 0], "sparse");
    enforce(first.getVariant(5).type == typeid(Vector), "Variant");
    enforce(conn.queryValue!long("SELECT id FROM itest_vec WHERE VECTOR_DISTANCE(f32, :1, EUCLIDEAN) < 0.001",
            [1f, 2, 3]) == 2, "a vector bind in a query");
    conn.rollback();
    dropTable(conn, "itest_vec");
}

/// Column metadata of 23ai: SQL domains and annotations.
void testColumnMetadata()
{
    auto conn = connectToServer();
    scope (exit)
        conn.close();
    if (majorVersion(conn) < 23)
        return;
    dropTable(conn, "itest_meta");
    collectException(conn.exec("DROP DOMAIN itest_dom"));
    conn.exec("CREATE DOMAIN itest_dom AS NUMBER(5)");
    scope (exit)
        collectException(conn.exec("DROP DOMAIN itest_dom"));
    conn.exec("CREATE TABLE itest_meta (id NUMBER, d itest_dom ANNOTATIONS (Display 'The value', Hidden),"
            ~ " plain VARCHAR2(10))");
    scope (exit)
        dropTable(conn, "itest_meta");
    auto r = conn.query("SELECT id, d, plain FROM itest_meta");
    const c = r.columns;
    enforce(c[1].domainName == "ITEST_DOM" && c[1].domainSchema.length, "domain: " ~ c[1].domainSchema ~ "."
            ~ c[1].domainName);
    enforce(c[1].annotations.canFind(["DISPLAY", "The value"]) && c[1].annotations.canFind([
        "HIDDEN", ""
    ]),
    "annotations: " ~ c[1].annotations.to!string);
    enforce(c[0].domainName is null && c[2].annotations.length == 0, "plain columns");
    r.close();
}

/// End-to-end attributes: module, action, client identifier and information, sent with the next call.
void testEndToEnd()
{
    auto conn = connectToServer();
    scope (exit)
        conn.close();
    enum sql = "SELECT SYS_CONTEXT('USERENV', 'MODULE'), SYS_CONTEXT('USERENV', 'ACTION'),"
        ~ " SYS_CONTEXT('USERENV', 'CLIENT_IDENTIFIER'), SYS_CONTEXT('USERENV', 'CLIENT_INFO') FROM dual";
    conn.moduleName = "itest module";
    conn.action = "Grüße";
    conn.clientIdentifier = "user 42";
    conn.clientInfo = "info";
    conn.dbOp = "itest_op";
    auto r = conn.query(sql);
    auto row = r.front;
    enforce(row.getString(0) == "itest module" && row.getString(1) == "Grüße", "module and action: "
            ~ row.getString(
                0) ~ ", " ~ row.getString(1));
    enforce(row.getString(2) == "user 42" && row.getString(3) == "info", "client identifier and information");
    r.close();
    conn.action = null; // cleared; the others stay
    r = conn.query(sql);
    row = r.front;
    enforce(row.getString(0) == "itest module" && row.isNull(1) && row.getString(2) == "user 42", "cleared action");
    r.close();
    enforce(conn.moduleName == "itest module" && conn.action is null, "properties");
}
