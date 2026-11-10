# oracle-native

A native client for **Oracle Database** in D: the Oracle Net (TNS) and TTC
protocols over TCP, written in pure D, for ordinary threads (blocking sockets)
and vibe.d fibers. No Oracle Instant Client, no OCI, no ODBC, no C libraries at
build time.

> **Status: 0.4.0.** The API may still change before 1.0;
> the plan is tracked in the
> [roadmap issue](https://github.com/buggins/oracle-native/issues/10), changes
> in the [changelog](CHANGELOG.md).

Add it to your `dub.json`:

```json
"dependencies": {
    "oracle-native": "~>0.4.0"
}
```

```d
import oracle;
import std.stdio;

void main()
{
    auto conn = new Connection("oracle://scott:tiger@localhost:1521/FREEPDB1");
    // or: new Connection("localhost:1521/FREEPDB1", "scott", "tiger"), a (DESCRIPTION=...) descriptor,
    // or a tnsnames.ora alias: new Connection("SALES", "scott", "tiger") ($TNS_ADMIN or ?config_dir=...)
    scope (exit)
        conn.close();
    conn.exec("CREATE TABLE notes (id NUMBER, text VARCHAR2(100))");
    conn.exec("INSERT INTO notes VALUES (1, 'first')");
    conn.commit(); // transactions are explicit (or set auto_commit=true)
    foreach (row; conn.query("SELECT id, text FROM notes ORDER BY id"))
        writeln(row.getLong(0), " ", row.getString(1));
}
```

Features:

- Oracle Database 12.1 and newer, tested on 23ai Free, 21c XE and 18c XE;
- password logins (11g and 12c verifiers), proxy authentication
  (`app_user[end_user]` or `proxy_client=end_user`), TLS (TCPS) with wallets
  (`ewallet.pem`, mutual TLS), `SSL_SERVER_CERT_DN`, and
  certificate and host name verification;
- `oracle://` URLs, Easy Connect strings, connect descriptors and
  `tnsnames.ora` aliases; failover
  over several addresses;
- pipelines (23ai: several statements in one round trip; one by one on
  older servers);
- bind variables (`:1`, `:name`, or `?`), a statement cache, array DML with
  batch errors, `RETURNING INTO`, PL/SQL with OUT parameters, REF cursors,
  implicit results, cancellation, transactions (explicit, or auto-commit);
- the common types, read and sent exactly: `NUMBER` (as exact decimals),
  `BINARY_FLOAT`/`BINARY_DOUBLE`, `VARCHAR2`/`CHAR`/`NVARCHAR2`/`NCHAR`,
  `RAW`, `DATE`, `TIMESTAMP` (with its nanoseconds, time zone offsets and
  regions, local time zone), `INTERVAL`s, `ROWID`/`UROWID`, `LONG`, LOBs
  (`CLOB`, `NCLOB`, `BLOB`, `BFILE`), `JSON` (21c), `VECTOR` and `BOOLEAN`
  (23ai);
- end-to-end attributes (module, action, client identifier) for monitoring;
- a connection pool for threads and vibe.d fibers, and DRCP (Database
  Resident Connection Pooling); struct mapping; a
  [ddbc](https://github.com/buggins/ddbc) driver (configuration `ORACLE`).

Later: a [hibernated](https://github.com/buggins/hibernated) dialect.
Native Network Encryption (Oracle's own encryption, an alternative to TLS) is
not supported: servers that require it are refused with a clear error.

It builds on [dbwire](https://github.com/buggins/dbwire), the pure-D building
blocks shared with [clickhoused](https://github.com/buggins/clickhoused) and
[mssql-native](https://github.com/buggins/mssql-native): transports for threads
and fibers, TLS with OpenSSL loaded at run time, cryptography for the password
exchange, exact decimals, connection pools.

Requires a D frontend 2.097 or newer (DMD 2.097+, LDC 1.27+).

Without TLS, only the password exchange is encrypted: the rest of the session
(statements and data) travels in clear. Use TLS (`tcps://` or `secure=true`)
on untrusted networks. Turning the host name check off
(`ssl_server_dn_match=off`) needs a wallet or `tls_ca_file` (or
`SSL_SERVER_CERT_DN`): with the system's CAs alone, any certificate a public
CA issued would pass.

## Tests

```sh
dub test                                   # unit tests, no server needed
docker run -d --name oracle-free -p 1521:1521 -e ORACLE_PASSWORD=Oracle_test123 \
    -e APP_USER=testuser -e APP_USER_PASSWORD=Test_password123 gvenzl/oracle-free:23-slim-faststart
ORACLE_HOST=localhost:1521 ORACLE_SERVICE=FREEPDB1 ORACLE_PASSWORD=Test_password123 \
    dub run :integration-tests-phobos      # or :integration-tests-vibe (vibe-core 2.x), :integration-tests-vibe1 (1.x)
```

## Bind variables

```d
conn.exec("INSERT INTO notes VALUES (:1, :2)", 2, "second");          // positional
conn.exec("UPDATE notes SET text = ? WHERE id = ?", "2nd", 2);         // ? becomes :1, :2
conn.exec("DELETE FROM notes WHERE id = :id", Parameter.of(2).named("id"));

// array DML: one round trip; per-row counts; with batch errors, failing rows don't stop the others
auto batch = conn.execMany("INSERT INTO notes VALUES (:1, :2)", [tuple(3, "c"), tuple(4, "d")], true);

// PL/SQL OUT and IN OUT parameters, RETURNING INTO, REF cursors, implicit results
auto r = conn.query("BEGIN :1 := 'out ' || :2; :3 := :3 * 2; END;",
    Parameter.output!string, "in", Parameter.inOut(21));
writeln(r.output(0).getString, " ", r.output(2).getLong);   // "out in 42"
```

D values are sent as: integers and `Decimal` → `NUMBER`; `bool` → `BOOLEAN`
(23ai; `NUMBER` 1/0 for older servers); `float` / `double` → `BINARY_FLOAT` /
`BINARY_DOUBLE`; strings → `VARCHAR2`; `ubyte[]`, `UUID` → `RAW`; `Date`,
`DateTime` → `DATE`; `SysTime` → `TIMESTAMP WITH TIME ZONE`; `Duration`,
`MonthInterval` → intervals; `Vector`, `float[]`, `double[]` → `VECTOR`
(23ai); `JSONValue` and `Parameter.json(text)` → `JSON`; `null` and
`Nullable` → NULL. JSON parameters go in Oracle's binary format (OSON, built
by the client: the server doesn't parse text) to JSON columns and PL/SQL
`JSON` parameters, also as OUT parameters and `RETURNING ... INTO` targets
(`Parameter.output!JSONValue`); numbers in JSON text stay exact. Servers
before 21c get the text.
Statements are kept parsed per connection (option `statement_cache_size`,
default 20) and run again with new values only. `Connection.cancel` (from
another thread or task; for a fiber-mode connection, a task of its own
thread) stops a running call with ORA-01013.

## Pipelines

```d
auto results = conn.pipeline()
    .exec("INSERT INTO notes VALUES (:1, :2)", 3, "third")
    .exec("UPDATE counters SET n = n + 1 WHERE id = :1", 7)
    .query("SELECT id, text FROM notes ORDER BY id")
    .commit()
    .run();                       // run(true): go on after errors, which are in the results
foreach (row; results[2].result)
    writeln(row.getLong(0), " ", row.getString(1));
```

On 23ai the statements go to the server together and their responses are read
afterwards (`conn.supportsPipelining`); older servers run them one by one. A
query's rows are all read before `run` returns.

## Structs

```d
struct Order
{
    int id;
    @column("customer_name") string customer;
    Decimal amount;
    Nullable!DateTime shipped;
    @ignore string note;
}

conn.insert("orders", orders);                       // array DML, 1000 rows per round trip
conn.commit();
foreach (o; conn.query!Order("SELECT * FROM orders WHERE amount > :1", 5))
    writeln(o.customer, " ", o.amount);
auto total = conn.queryValue!long("SELECT COUNT(*) FROM orders");
```

## Connection pool and vibe.d

```d
auto pool = new ConnectionPool("oracle://app:secret@db/FREEPDB1?pool_max=8");
{
    auto conn = pool.lockConnection();   // waits while all 8 are in use
    conn.exec("UPDATE stats SET hits = hits + 1");
    conn.commit();
}                                        // back to the pool
```

The same code runs in threads (blocking sockets) and in vibe.d tasks, where
waiting for the server suspends only the task: the I/O mode follows the
caller (`ConnectionOptions.ioMode`). A returned connection has its
uncommitted changes rolled back and its end-to-end attributes cleared, and
the LOBs read through it can't be used any more. See `examples/` (`dub run
:example-basic`, `dub run :example-vibe`).

### DRCP

With Database Resident Connection Pooling the database keeps a pool of
sessions that many client connections share (start it with
`EXEC DBMS_CONNECTION_POOL.START_POOL()`). Ask for a pooled server with
`:pooled` in Easy Connect, `server=pooled` in a URL or `(SERVER=POOLED)` in a
descriptor:

```d
auto pool = new ConnectionPool("db:1521/FREEPDB1:pooled?pool_max=50");
```

A returned connection hands its session back to the database's pool, and
gets one again with its next call. The pool's connections share a
connection class (`pool_connection_class`, generated if not set) and purity
`self`: a connection may get a session with the state an earlier user of the
class left (session settings, package state, and the statement cache stays
valid when the session is the same). A single connection gets a fresh session
(`pool_purity=new`) unless told otherwise; `Connection.releaseSession`
releases its session by hand.

## LOBs

CLOB, NCLOB and BLOB columns come with their contents (`getString`,
`getBytes`); strings and bytes of any length bind to CLOB, BLOB, LONG and
LONG RAW columns. For values too big to hold at once, fetch locators
(`lob_locators=true`) and use `Lob`:

```d
foreach (row; conn.query("SELECT doc FROM documents WHERE id = :1", 1)) // with lob_locators=true
{
    auto doc = row.getLob(0);
    for (ulong at = 1; at <= doc.length; at += 1_000_000)
        process(doc.readText(at, 1_000_000));
}
auto tmp = conn.createLob(OracleType.clob);   // a temporary LOB, written in pieces, then bound
tmp.writeText("part one");
tmp.writeText(", part two", 9);
conn.exec("INSERT INTO documents VALUES (2, :1)", tmp);
tmp.free();
```

BFILE columns are always locators (`getLob(i).read()`).

## Reading values

`Row` getters convert a column to D types (`getLong`, `getInt`, `getBool`,
`getDouble`, `getDecimal`, `getString`, `getBytes`, `getDate`, `getTime`,
`getDateTime`, `getSysTime`, `getNanoseconds`, `getDuration`,
`getMonthInterval`, `getJson`, `getVector`, `getVariant`); NULL gives the
type's default value (`isNull` tells).

| Oracle type | Natural D type (`getVariant`) | Notes |
|---|---|---|
| `NUMBER(p)`, p ≤ 18 | `long` | |
| other `NUMBER`, `FLOAT` | `Decimal` (exact) | `getString`: plain decimal text (`0.5`, `-0.001`) |
| `BINARY_FLOAT` / `BINARY_DOUBLE` | `float` / `double` | text: shortest exact (`0.1`), `Nan`, `Inf` |
| `VARCHAR2`, `CHAR`, `NVARCHAR2`, `NCHAR`, `LONG` | `string` | UTF-8 |
| `RAW`, `LONG RAW` | `ubyte[]` | text: hexadecimal |
| `DATE` | `DateTime` | |
| `TIMESTAMP` | `SysTime` (UTC) | nanoseconds with `getNanoseconds` |
| `TIMESTAMP WITH TIME ZONE` | `SysTime` in its zone | offsets and regions (`Europe/Lisbon`) |
| `TIMESTAMP WITH LOCAL TIME ZONE` | `SysTime` in the session time zone | option `time_zone`, default `+00:00` |
| `INTERVAL YEAR TO MONTH` | `MonthInterval` | |
| `INTERVAL DAY TO SECOND` | `Duration` | nanoseconds with `getNanoseconds` |
| `ROWID`, `UROWID` | `string` | |
| `CLOB`, `NCLOB` / `BLOB` | `string` / `ubyte[]` | contents; locators: `getLob` |
| `BFILE` | `Lob` | read-only |
| `BOOLEAN` (23ai) | `bool` | text `true` / `false` |
| `JSON` (21c) | `string` (its text) | `getJson`: `std.json` value; text as `JSON_SERIALIZE` writes it |
| `VECTOR` (23ai) | `Vector` | FLOAT32, FLOAT64, INT8, BINARY, sparse; text as `FROM_VECTOR` writes it |

`getString` writes dates, timestamps and intervals as the server does
(`2026-11-03 10:20:30.123456`, `+02-03`, `+03 04:05:06.789000`). Time zone
regions use the system's time zone database for their local time (Windows has
none: such values are shown in UTC). JSON values arrive in Oracle's binary
format (OSON) and are decoded by the client; dates and timestamps in them read
as ISO 8601 strings. Column metadata (`ColumnInfo`) also has the 23ai SQL
domain, annotations and VECTOR dimensions and format.

Monitoring tools see the end-to-end attributes of a session (`V$SESSION`,
`SYS_CONTEXT('USERENV', ...)`); they are sent with the next call (with DRCP
also after a session switch, so they follow the connection):

```d
conn.moduleName = "billing";
conn.action = "monthly run";
conn.clientIdentifier = "user 42";
```

## Disclaimer

This is an unofficial project, not affiliated with, endorsed or sponsored by
Oracle. Oracle is a registered trademark of Oracle and/or its affiliates. Oracle
has not published a specification of its network protocol: this client is an
independent implementation written from the observable behaviour of servers
and from facts documented by open-source clients.

## License

[Boost Software License 1.0](LICENSE).
