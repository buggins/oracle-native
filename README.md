# oracle-native

A native client for **Oracle Database** in D: the Oracle Net (TNS) and TTC
protocols over TCP, written in pure D, for ordinary threads (blocking sockets)
and vibe.d fibers. No Oracle Instant Client, no OCI, no ODBC, no C libraries at
build time.

> **Status: under development.** Nothing is released yet; the plan is tracked
> in the [roadmap issue](https://github.com/buggins/oracle-native/issues/10).
> It connects (TCP or TLS, password logins), runs statements and reads `NUMBER`
> and character columns; the other types, bind variables and the rest come in
> the next milestones.

```d
import oracle;
import std.stdio;

void main()
{
    auto conn = new Connection("oracle://scott:tiger@localhost:1521/FREEPDB1");
    // or: new Connection("localhost:1521/FREEPDB1", "scott", "tiger"), or a (DESCRIPTION=...) descriptor
    scope (exit)
        conn.close();
    conn.exec("CREATE TABLE notes (id NUMBER, text VARCHAR2(100))");
    conn.exec("INSERT INTO notes VALUES (1, 'first')");
    conn.commit(); // transactions are explicit (or set auto_commit=true)
    foreach (row; conn.query("SELECT id, text FROM notes ORDER BY id"))
        writeln(row.getLong(0), " ", row.getString(1));
}
```

Planned for the first release (0.1.0):

- Oracle Database 12.1 and newer (tested on 23ai Free, 21c XE and 18c XE),
  Oracle Cloud (Autonomous Database) over TLS;
- password logins (11g and 12c verifiers), TLS with certificate verification
  and wallets in PEM form;
- Easy Connect strings, TNS descriptors, `tnsnames.ora` aliases and
  `oracle://` URLs; failover over several addresses;
- queries and bind variables (`:1`, `:name`, or `?`), a statement cache, array
  DML, `RETURNING INTO`, PL/SQL with OUT parameters, REF cursors, implicit
  results, cancellation, transactions;
- the common types, read and sent exactly: `NUMBER` (as exact decimals),
  `BINARY_FLOAT`/`BINARY_DOUBLE`, `VARCHAR2`/`CHAR`/`NVARCHAR2`/`NCHAR`, `RAW`,
  `DATE`, `TIMESTAMP` (with its nanoseconds, time zones and local time zone),
  `INTERVAL`s, `ROWID`, LOBs (`CLOB`, `NCLOB`, `BLOB`, `BFILE`), `BOOLEAN`
  (23ai);
- a connection pool and struct mapping.

Later: `JSON` (OSON) and `VECTOR`, a [ddbc](https://github.com/buggins/ddbc)
driver and a [hibernated](https://github.com/buggins/hibernated) dialect.
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
on untrusted networks.

## Tests

```sh
dub test                                   # unit tests, no server needed
docker run -d --name oracle-free -p 1521:1521 -e ORACLE_PASSWORD=Oracle_test123 \
    -e APP_USER=testuser -e APP_USER_PASSWORD=Test_password123 gvenzl/oracle-free:23-slim-faststart
ORACLE_HOST=localhost:1521 ORACLE_SERVICE=FREEPDB1 ORACLE_PASSWORD=Test_password123 \
    dub run :integration-tests-phobos      # or :integration-tests-vibe for vibe.d fibers
```

## Disclaimer

This is an unofficial project, not affiliated with, endorsed or sponsored by
Oracle. Oracle is a registered trademark of Oracle and/or its affiliates. Oracle
has not published a specification of its network protocol: this client is an
independent implementation written from the observable behaviour of servers
and from facts documented by open-source clients.

## License

[Boost Software License 1.0](LICENSE).
