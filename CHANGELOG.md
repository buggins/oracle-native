# Changelog

All notable changes to oracle-native are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[semantic versioning](https://semver.org/).

## Unreleased

### Changed

- dbwire 0.8 (`~>0.8.0`, #38), the same as postgresql-native 0.5 and
  clickhoused 0.9, so they can be used in one build (and in ddbc). With it,
  `TIMESTAMP WITH TIME ZONE` values with a region name follow the tz
  database's TZif files (buggins/dbwire#33): the local mean time before a
  zone's first transition and daylight saving time after 2037.

## 0.3.0 — 2026-11-03

### Added

- Proxy authentication (#21): `ConnectionOptions.proxyClient` (parameter
  `proxy_client`), or the user name written `proxy[target]`: the proxy user
  logs in with its own password to a session of the target user, who must
  allow it (`ALTER USER target GRANT CONNECT THROUGH proxy`).
- `tnsnames.ora` connect aliases (#22): `ConnectionOptions.parse` (and so
  `new Connection(alias, user, password)` and pools) resolves a name such as
  `SALES` through `tnsnames.ora` in `config_dir` (new option `configDir`),
  `$TNS_ADMIN` or `$ORACLE_HOME/network/admin`, with several names per
  entry, comments and `IFILE` includes; parameters may follow the alias
  (`SALES?config_dir=/etc/oracle`).
- Wallets and server certificate subjects (#22): `walletLocation`
  (`wallet_location`, `MY_WALLET_DIRECTORY` in descriptors) reads an Oracle
  wallet in PEM form (`ewallet.pem`): its certificates are the trusted CAs,
  and its private key (password `walletPassword` / `wallet_password`) and
  certificate are used for mutual TLS. `serverCertDn` (`ssl_server_cert_dn`,
  `SSL_SERVER_CERT_DN`) checks the server certificate's subject instead of
  the host name; `ssl_server_dn_match=off` / `SSL_SERVER_DN_MATCH=off` checks
  only the certificate chain. Needs dbwire 0.6.
- Pipelines (#20): `conn.pipeline().exec(...).query(...).commit().run()`
  sends the statements together and reads their responses afterwards on 23ai
  (one round trip; `Connection.supportsPipelining`), and runs them one by
  one on older servers, with the same `PipelineResult`s (row counts, OUT
  values, all rows of queries, errors with `run(true)`). The client now
  offers TNS 319 and uses END_OF_RESPONSE when the server offers it.
- DRCP, Database Resident Connection Pooling (#23): `serverType` `pooled`
  (`:pooled`, `server=pooled`, `(SERVER=POOLED)`) with a connection class
  (`connectionClass`, `pool_connection_class`, `POOL_CONNECTION_CLASS`) and
  purity (`purity`, `pool_purity`, `POOL_PURITY`). A `ConnectionPool` hands
  the session back to the database's pool when a connection is returned
  (`Connection.releaseSession`), with a connection class of its own and
  purity `self`; closing a DRCP connection ends its session without a logoff.
- JSON parameters (#24): `std.json.JSONValue` values and JSON text
  (`Parameter.json`) are sent as JSON, encoded by the client in Oracle's
  binary format (OSON), so the server doesn't parse text: for JSON columns,
  PL/SQL `JSON` parameters (IN, OUT, IN OUT) and `RETURNING ... INTO`
  (`Parameter.output!JSONValue`). Numbers in JSON text are kept exactly
  (rounded to NUMBER's precision, or BINARY_DOUBLE outside its range, as the
  server's parser does); field names longer than 255 bytes need 23ai. Servers
  before 21c get the text. `Variant` parameters take `JSONValue` too.
- `INTERVAL YEAR TO MONTH` values inside JSON are decoded (`P1Y2M`).

### Fixed

- The session-return server piggyback was read with the wrong layout (it
  comes with DRCP). `Connection.sessionId` and `serialNumber` follow the
  session the server attaches.
- A statement parsed again while its SQL was cached and in use (an open
  result of the same SQL) kept its cursor open on the server after its result
  was done; it is closed now.
- Running a PL/SQL block with OUT parameters a second time on a connection
  (a re-execution of its cached cursor) failed with ORA-03146 and the server
  closed the connection: the client sent values for the OUT parameters and
  didn't know their directions without the server's IO vector.
- `BINARY_FLOAT` and `BINARY_DOUBLE` values inside JSON read as
  `JSON_SERIALIZE` writes them (`0.00001`, `100`, `1E+300`), not as
  `1e-05`, `1e+02`, `1e+300`.

## 0.2.0 — 2026-11-03

### Added

- Newer types and the 23.4 protocol (#7): the client now speaks TTC field
  version 24 (23.4; 21c negotiates 16, 18c 11). `JSON` columns (21c) are
  decoded from Oracle's binary JSON (OSON) to their text, as
  `JSON_SERIALIZE` writes it, and `Value.getJson` gives a `std.json` value.
  `VECTOR` columns (23ai) read as `Vector` (FLOAT32, FLOAT64, INT8, BINARY,
  sparse; `getVector`, text as `FROM_VECTOR` writes it), and `Vector`,
  `float[]` and `double[]` parameters are sent as VECTOR. `BOOLEAN` columns
  arrive natively, and `bool` parameters are sent as `BOOLEAN` to 23ai
  (`NUMBER` 1/0 to older servers), also for PL/SQL `BOOLEAN` parameters.
- Column metadata of 23ai: SQL domain, annotations, VECTOR dimensions and
  format; `isJson` / `isOson` flags (`ColumnInfo`).
- End-to-end attributes: `Connection.moduleName`, `action`,
  `clientIdentifier`, `clientInfo`, `dbOp`, sent with the next call.

### Fixed

- Queries with a `JSON` column failed with ORA-01002.

## 0.1.0 — 2026-11-03

First release.

### Added

- High-level API (#6): `ConnectionPool` / `PooledConnection` for threads and
  vibe.d fibers (dbwire's pool core; `pool_*` connection string parameters;
  uncommitted changes rolled back when a connection is handed out again),
  struct mapping (`query!T`, `queryRow!T`, `queryValue!T`, `insert` with
  array DML; `@column`, `@ignore`), fiber-mode tests against vibe-core 1.x
  and 2.x, examples (`:example-basic`, `:example-vibe`).
- LOBs and long data (#5): CLOB, NCLOB and BLOB columns fetched with their
  contents (as LONG / LONG RAW) or, with the `lob_locators` option, as
  locators; `Lob` (length, read and readText at offsets, write and
  writeText, trim, free), `Value.getLob`, `getLobSize`; temporary LOBs
  (`Connection.createLob`) bound as parameters; BFILE reads; strings and
  bytes of any length bound (values over 32767 bytes are sent after the
  others, as LONG binds require).
- Bind variables and statements (#4): `:1`, `:name` and `?` placeholders,
  `Parameter` (D values to Oracle types, NULLs, named binds, `Variant`),
  OUT and IN OUT parameters (`Parameter.output`, `inOut`, `refCursor`),
  `RETURNING ... INTO` (one value per changed row), `QueryResult.outputs`,
  `rowCount` and `implicitResults`, REF cursors; array DML (`execMany`) with
  row counts per row and batch errors; a statement cache per connection
  (re-execution with new values, re-parse when a table changed; option
  `statement_cache_size`); `Connection.cancel`.
- Data types (#3): `BINARY_FLOAT`/`BINARY_DOUBLE`, `DATE`, `TIMESTAMP` (with
  nanoseconds), `WITH TIME ZONE` (offsets and regions, with a region table
  generated from the server by `tools/tzregions.d`), `WITH LOCAL TIME ZONE`
  (converted from the database to the session time zone), `INTERVAL YEAR TO
  MONTH`, `INTERVAL DAY TO SECOND`, `LONG`, `LONG RAW`, `UROWID`; `NUMBER` as an
  exact `Decimal`. New `Value` type and getters (`getInt`, `getBool`,
  `getDecimal`, `getDate`, `getTime`, `getDateTime`, `getSysTime`,
  `getNanoseconds`, `getDuration`, `getMonthInterval`, `getVariant`); the
  texts of dates, timestamps and intervals are those of the server.
- Connecting and first statements (#2):
  - the listener handshake (TNS 318: CONNECT, ACCEPT, REFUSE, REDIRECT,
    RESEND, SDU up to 2 MB), protocol and data-type negotiation, Native Network
    Encryption declined (servers requiring it are refused with a clear error);
  - O5LOGON password logins with 11g and 12c verifiers, the server's proof
    checked, session information (`serverVersion`, `sessionId`,
    `serialNumber`, `serviceName`, `databaseName`, `maxIdentifierLength`);
  - TLS (TCPS) through dbwire with certificate and host name verification;
  - `oracle://` URLs, Easy Connect (`[tcps://]host[:port]/service[:server][/instance]`)
    and connect descriptors (address lists, `LOAD_BALANCE`, `SID`,
    `INSTANCE_NAME`, `SERVER`); failover to the next address; client
    identification and session time zone options;
  - `exec` (row counts), `query` (rows fetched in batches, duplicate-column
    compression), `commit`, `rollback`, `ping`, `close` (logoff), an
    `autoCommit` option, server errors with ORA code and position, cursors
    closed with the next call;
  - `NUMBER` (text, `long`, `double`), `VARCHAR2`/`CHAR`/`NVARCHAR2`/`NCHAR`
    text, `RAW` (hex), `ROWID`;
  - integration tests on 23ai, 21c and 18c in thread and fiber mode, TLS
    through a test proxy.
- Repository scaffold (#1): dub package `oracle-native` (module `oracle`) on
  dbwire 0.5, CI on Linux, Windows and macOS with DMD and LDC down to frontend
  2.097, Oracle Database Free 23ai and XE 21c service containers for
  integration tests, lint and documentation checks.
