/++
Benchmark cases: the client's work for queries, binds, array DML (`insert`),
value conversions, OSON, VECTOR and long values, against the in-memory
`FakeServer` or directly on the encoders and decoders.

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module benchmarks.cases;

import core.time : Duration;
import std.datetime.date : DateTime;
import std.variant : Variant;

import oracle;
import oracle.protocol.ttc : TtcWriter;
import oracle.types.encode;
import dbwire.io.transport : Transport;

import benchmarks.fakeserver;
import benchmarks.runner : BenchCase, Prepared;

/// All cases.
BenchCase[] allCases()
{
    return queryCases() ~ bindCases() ~ valueCases() ~ encodingCases();
}

private:

// A check that release builds keep (they drop asserts, and with them the work inside).
void check(bool ok) @safe
{
    if (!ok)
        throw new Exception("benchmark check failed");
}

// A connection to a new fake server.
Connection connect(FakeServer server)
{
    auto o = ConnectionOptions.parse("oracle://bench:" ~ password ~ "@fake/BENCH");
    Transport factory(string, ushort, Duration) @safe
    {
        return server;
    }

    o.transportFactory = &factory;
    return new Connection(o);
}

// --- queries ---

enum Col[] rowColumns = [
    Col(OracleType.number, 22, "ID"), Col(OracleType.number, 22, "AMOUNT"),
    Col(OracleType.varchar, 80, "NAME"),
    Col(OracleType.date, 7, "DAY"), Col(OracleType.timestamp, 11, "TS"),
    Col(OracleType.binaryDouble, 8, "RATIO"),
    Col(OracleType.number, 22, "FLAG"), Col(OracleType.varchar, 80, "NOTE"),
];

// The values of row `i`: integers, a decimal, text, a DATE, a TIMESTAMP(6), a BINARY_DOUBLE, a small number, NULL.
immutable(ubyte)[][] rowValues(size_t i)
{
    import dbwire.types.decimal : Decimal;

    const amount = Decimal.fromString("12345.67");
    return [
        encodeNumber(cast(long)(1_000_000 + i)), encodeNumber(amount),
        cast(immutable(ubyte)[]) "customer name number 1",
        encodeDate(DateTime(2026, 11, 10, 12, 30, 45)),
        encodeTimestamp(DateTime(2026, 11, 10, 12, 30, 45), 123_456_000),
        encodeBinaryDouble(1234.5678 + i),
        encodeNumber(cast(long)(i % 2)), null
    ];
}

// The responses to a query of `rows` rows: the first with the columns, then FETCH responses of `fetchSize` rows.
const(ubyte)[][] queryResponses(size_t rows, size_t fetchSize = 100)
{
    const(ubyte)[][] responses;
    size_t done;
    do
    {
        TtcWriter w;
        if (done == 0)
            putDescribe(w, rowColumns);
        const n = rows - done < fetchSize ? rows - done : fetchSize;
        foreach (i; done .. done + n)
            putRow(w, rowValues(i));
        done += n;
        putEnd(w, done == rows ? 1403 : 0, 3);
        responses ~= w.data;
    }
    while (done < rows);
    return responses;
}

size_t wireSize(const(ubyte[][]) responses)
{
    size_t n;
    foreach (r; responses)
        n += r.length;
    return n;
}

BenchCase[] queryCases()
{
    BenchCase[] cases;
    cases ~= BenchCase("query/rows", (size_t rows) {
        auto server = new FakeServer;
        auto conn = connect(server);
        const responses = queryResponses(rows);
        return Prepared(rows, wireSize(responses), () {
            server.respond(responses);
            size_t n;
            foreach (row; conn.query("SELECT * FROM t"))
                n += row.length;
            check(n == rows * rowColumns.length);
        });
    }, 200_000);
    cases ~= BenchCase("query/rows+getters", (size_t rows) {
        auto server = new FakeServer;
        auto conn = connect(server);
        const responses = queryResponses(rows);
        return Prepared(rows, wireSize(responses), () {
            server.respond(responses);
            long sum;
            size_t chars;
            foreach (row; conn.query("SELECT * FROM t"))
            {
                sum += row.getLong(0) + row.getLong(6);
                chars += row.getString(1).length + row.getString(2).length + row.getString(3)
                .length
                + row.getString(4).length + row.isNull(7);
                sum += cast(long) row.getDouble(5);
            }
            check(sum > 0 && chars > 0);
        });
    }, 200_000);
    return cases;
}

// --- binds and array DML ---

struct Order
{
    long id;
    string customer;
    double amount;
    DateTime created;
    int status;
}

BenchCase[] bindCases()
{
    BenchCase[] cases;
    cases ~= BenchCase("exec/5 binds", (size_t rows) {
        auto server = new FakeServer;
        auto conn = connect(server);
        TtcWriter w;
        putEnd(w, 0, 4, 1);
        auto responses = new const(ubyte)[][rows];
        responses[] = w.data;
        return Prepared(rows, 0, () {
            server.respond(responses);
            foreach (i; 0 .. rows)
                conn.exec("INSERT INTO t VALUES (:1, :2, :3, :4, :5)", cast(long) i, "name", 12.5, cast(int) i, 7L);
        });
    }, 100_000);
    cases ~= BenchCase("insert/structs (1000 per round trip)", (size_t rows) {
        auto server = new FakeServer;
        auto conn = connect(server);
        auto orders = new Order[rows];
        foreach (i, ref o; orders)
            o = Order(i, "customer name", 100.25 + i, DateTime(2026, 11, 10, 8, 0, 0), cast(int)(i % 5));
        const(ubyte)[][] responses;
        for (size_t done = 0; done < rows; done += 1000)
        {
            TtcWriter w;
            putEnd(w, 0, 5, rows - done < 1000 ? rows - done : 1000);
            responses ~= w.data;
        }
        return Prepared(rows, 0, () {
            server.respond(responses);
            check(conn.insert("orders", orders) == rows);
        });
    }, 200_000);
    cases ~= BenchCase("params/Parameter.of int, long, string, double", (size_t rows) {
        return Prepared(rows, 0, () {
            size_t n;
            foreach (i; 0 .. rows)
            {
                n += Parameter.of(cast(int) i).data.length + Parameter.of(1_234_567_890_123L + i).data.length;
                n += Parameter.of("text").data.length + Parameter.of(0.25 * i).data.length;
            }
            check(n > 0);
        });
    }, 1_000_000);
    cases ~= BenchCase("params/Parameter.of Variant (int, Date)", (size_t rows) {
        import std.datetime.date : Date;

        const values = [Variant(42), Variant(Date(2026, 11, 10))];
        return Prepared(rows, 0, () {
            size_t n;
            foreach (i; 0 .. rows)
                n += Parameter.of(values[i % 2]).data.length;
            check(n > 0);
        });
    }, 1_000_000);
    return cases;
}

// --- value conversions ---

Value value(OracleType type, immutable(ubyte)[] bytes, int scale = 0)
{
    ColumnInfo c;
    c.name = "V";
    c.type = type;
    c.scale = cast(byte) scale;
    return Value(c, bytes);
}

BenchCase valueCase(string name, const Value v, void function(const Value) @safe get)
{
    return BenchCase(name, (size_t rows) {
        return Prepared(rows, 0, () {
            foreach (i; 0 .. rows)
                get(v);
        });
    }, 2_000_000);
}

BenchCase[] valueCases()
{
    import core.time : seconds;
    import dbwire.types.decimal : Decimal;

    const number = value(OracleType.number, encodeNumber(Decimal.fromString("12345.67")));
    const integer = value(OracleType.number, encodeNumber(1_234_567_890L));
    const date = value(OracleType.date, encodeDate(DateTime(2026, 11, 10, 12, 30, 45)));
    const ts = value(OracleType.timestamp, encodeTimestamp(DateTime(2026, 11, 10, 12, 30, 45), 123_456_000), 6);
    const dbl = value(OracleType.binaryDouble, encodeBinaryDouble(1234.5678));
    const interval = value(OracleType.intervalDs, encodeIntervalDs(seconds(123_456)), 6);
    return [
        valueCase("value/NUMBER getLong", integer, (const Value v) => cast(void) v.getLong()),
        valueCase("value/NUMBER getString", number, (const Value v) => cast(void) v.getString()),
        valueCase("value/NUMBER getDouble", number, (const Value v) => cast(void) v.getDouble()),
        valueCase("value/NUMBER getDecimal", number, (const Value v) => cast(void) v.getDecimal()),
        valueCase("value/DATE getString", date, (const Value v) => cast(void) v.getString()),
        valueCase("value/TIMESTAMP getString", ts, (const Value v) => cast(void) v.getString()),
        valueCase("value/BINARY_DOUBLE getString", dbl, (const Value v) => cast(void) v.getString()),
        valueCase("value/INTERVAL DS getString", interval, (const Value v) => cast(void) v.getString()),
    ];
}

// --- encodings: long values, OSON, VECTOR, LOB writes ---

// A transport that serves the same bytes again on every `rewind`.
final class Replay : Transport
{
    immutable(ubyte)[] data;
    size_t pos;

    this(immutable(ubyte)[] data) @safe
    {
        this.data = data;
    }

    void rewind() @safe
    {
        pos = 0;
    }

    override size_t read(scope ubyte[] buffer) @safe
    {
        const n = data.length - pos < buffer.length ? data.length - pos : buffer.length;
        buffer[0 .. n] = data[pos .. pos + n];
        pos += n;
        return n;
    }

    override void write(scope const(ubyte)[] bytes) @safe
    {
    }

    override bool dataAvailable() @safe
    {
        return pos < data.length;
    }

    override void close() @safe nothrow
    {
    }

    override bool connected() const @safe nothrow
    {
        return true;
    }

    override void setTimeouts(Duration receive, Duration send) @safe
    {
    }
}

enum jsonText = `{"id":1234,"name":"customer name","active":true,"tags":["a","b","c"],`
    ~ `"address":{"street":"Main Street 1","city":"Lisbon","zip":"1000-001"},"amount":12345.67,"ratio":0.25}`;

BenchCase[] encodingCases()
{
    import dbwire.io.buffer : BufferedReader;
    import oracle.lob : LobOperation, LobRequest, buildLobOperation;
    import oracle.protocol.ttc : TtcReader;
    import oracle.types.oson : encodeOson, osonToText;
    import oracle.types.vector : decodeVector, encodeVector;

    BenchCase[] cases;
    cases ~= BenchCase("long value/1 MB chunked CLR", (size_t rows) {
        auto big = new ubyte[1024 * 1024];
        TtcWriter w;
        foreach (i; 0 .. rows)
            w.clr(big);
        auto replay = new Replay(w.data.idup);
        return Prepared(rows, replay.data.length, () {
            replay.rewind();
            auto r = TtcReader(new BufferedReader(replay));
            foreach (i; 0 .. rows)
                check(r.clr(size_t.max).length == big.length);
        });
    }, 100);
    const image = encodeOson(jsonText, false);
    cases ~= BenchCase("OSON/to text (180 B document)", (size_t rows) {
        return Prepared(rows, image.length * rows, () {
            foreach (i; 0 .. rows)
                check(osonToText(image).length > 100);
        });
    }, 200_000);
    cases ~= BenchCase("OSON/from text (180 B document)", (size_t rows) {
        return Prepared(rows, jsonText.length * rows, () {
            foreach (i; 0 .. rows)
                check(encodeOson(jsonText, false).length > 50);
        });
    }, 200_000);
    auto floats = new float[1024];
    foreach (i, ref f; floats)
        f = i * 0.001f;
    const vector = Vector.of(floats);
    const vectorImage = encodeVector(vector);
    cases ~= BenchCase("VECTOR/encode FLOAT32[1024]", (size_t rows) {
        return Prepared(rows, vectorImage.length * rows, () {
            foreach (i; 0 .. rows)
                check(encodeVector(vector).length == vectorImage.length);
        });
    }, 20_000);
    cases ~= BenchCase("VECTOR/decode FLOAT32[1024]", (size_t rows) {
        return Prepared(rows, vectorImage.length * rows, () {
            foreach (i; 0 .. rows)
                check(decodeVector(vectorImage).length == 1024);
        });
    }, 20_000);
    cases ~= BenchCase("VECTOR/text FLOAT32[1024]", (size_t rows) {
        return Prepared(rows, 0, () {
            foreach (i; 0 .. rows)
                check(vector.toString().length > 1024);
        });
    }, 2_000);
    cases ~= BenchCase("LOB/write request 1 MB", (size_t rows) {
        auto data = new ubyte[1024 * 1024];
        return Prepared(rows, data.length * rows, () {
            foreach (i; 0 .. rows)
            {
                LobRequest q;
                q.operation = LobOperation.write;
                q.locator = new ubyte[40];
                q.sourceOffset = 1;
                q.data = data;
                check(buildLobOperation(q, 1, fieldVersion).length > data.length);
            }
        });
    }, 200);
    return cases;
}
