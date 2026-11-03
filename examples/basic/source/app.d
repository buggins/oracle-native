/++
Basic oracle-native usage: connect, run statements with bind variables, insert
and query structs, call PL/SQL with OUT parameters, read a CLOB, commit and
roll back.

Run with `dub run :example-basic`. The connection string comes from the
`ORACLE_CONNECTION` environment variable: a URL
(`oracle://scott:tiger@localhost:1521/FREEPDB1`), Easy Connect
(`localhost:1521/FREEPDB1`, then set `ORACLE_USER` and `ORACLE_PASSWORD`) or
a connect descriptor.
+/
module app;

import std.datetime : DateTime;
import std.process : environment;
import std.stdio : writefln, writeln;
import std.typecons : Nullable;

import oracle;

/// One row of the `example_orders` table.
struct Order
{
    /// Order number.
    int id;
    /// Customer; stored in the column `customer_name`.
    @column("customer_name") string customer;
    /// Exact amount.
    Decimal amount;
    /// When it was shipped; NULL while not shipped.
    Nullable!DateTime shipped;
}

void main()
{
    auto options = ConnectionOptions.parse(environment.get("ORACLE_CONNECTION", "localhost:1521/FREEPDB1"));
    if (auto user = environment.get("ORACLE_USER"))
        options.user = user;
    if (auto password = environment.get("ORACLE_PASSWORD"))
        options.password = password;
    auto conn = new Connection(options);
    scope (exit)
        conn.close();
    writefln("Connected to Oracle Database %s, service %s, session %s", conn.serverVersion, conn.serviceName,
            conn.sessionId);

    try
        conn.exec("DROP TABLE example_orders PURGE");
    catch (ServerException e)
    {
        // ORA-00942: there was no table yet
    }
    conn.exec("CREATE TABLE example_orders (id NUMBER(10) PRIMARY KEY, customer_name VARCHAR2(50),"
            ~ " amount NUMBER(18,2), shipped DATE, notes CLOB)");

    // Bind variables: :1, :name or ?
    conn.exec("INSERT INTO example_orders (id, customer_name, amount, shipped) VALUES (:1, :2, :3, :4)", 1,
            "Grüße GmbH", Decimal.fromString("1234.50"), DateTime(2026, 1, 15, 9, 30, 0));

    // Structs: fields map to columns by name; inserted with array DML
    Order[] more;
    foreach (i; 2 .. 6)
        more ~= Order(i, "customer " ~ cast(char)('A' + i), Decimal.fromLong(i * 100));
    writeln("inserted ", conn.insert("example_orders", more), " rows");
    conn.commit(); // transactions are explicit
    foreach (o; conn.query!Order("SELECT * FROM example_orders WHERE amount >= :1 ORDER BY id", 300))
        writefln("%s  %-12s %10s  %s", o.id, o.customer, o.amount.toString(), o.shipped.isNull ? "-"
                : o.shipped.get.toString());
    writefln("total %s", conn.queryValue!Decimal("SELECT SUM(amount) FROM example_orders").toString());

    // PL/SQL with OUT parameters
    auto r = conn.query("BEGIN SELECT COUNT(*), MAX(amount) INTO :n, :m FROM example_orders; END;",
            Parameter.output!long.named("n"), Parameter.output!Decimal.named("m"));
    writefln("%s orders, the largest %s", r.output("n").getLong, r.output("m").getString);

    // A CLOB: any length of text goes in and comes out as a string
    conn.exec("UPDATE example_orders SET notes = :1 WHERE id = 1", "a long note. " ~ "x".replicate(100_000));
    writefln("note of %s characters", conn.queryValue!string("SELECT notes FROM example_orders WHERE id = 1").length);

    // A transaction rolled back
    conn.exec("DELETE FROM example_orders");
    conn.rollback();
    writefln("%s orders after the rollback", conn.queryValue!long("SELECT COUNT(*) FROM example_orders"));
    conn.exec("DROP TABLE example_orders PURGE");
}

private string replicate(string s, size_t n)
{
    import std.array : replicate;

    return s.replicate(n);
}
