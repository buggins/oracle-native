# Changelog

All notable changes to oracle-native are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[semantic versioning](https://semver.org/).

## Unreleased

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
