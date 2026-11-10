# AGENTS.md

Guidance for AI coding agents working on **oracle-native**, a native D client for Oracle Database.

## Project at a glance

- **What:** a pure-D client for Oracle Database over the **Oracle Net (TNS) and TTC protocols** (TCP, port 1521; TCPS for TLS), for Oracle Database 12.1 and later (TNS version ≥ 315), with blocking (thread) and vibe.d (fiber) I/O. dub package `oracle-native`, root module `oracle`.
- **Repo:** `git@github.com:buggins/oracle-native.git`, default branch `main`. Author Vadim Lopatin (GitHub `buggins`). License BSL-1.0.
- **Status:** 0.3.1 released on 2026-11-07 (0.1.0: O0–O5: connect, types, binds and statements, LOBs, pool and mapping; 0.2.0: O6: TTC field version 24, JSON, VECTOR, native BOOLEAN, end-to-end attributes; 0.3.0: proxy authentication, tnsnames.ora, wallets, pipelining, DRCP, JSON binds as OSON: #20–#24; 0.3.1: dbwire 0.8); roadmap issue #10 lists milestones O0–O8 (one issue each). Published on code.dlang.org as `oracle-native`. O7 (ddbc driver) done in ddbc 0.10.0.
- **Builds on dbwire** (`../dbwire`, 0.9): `dbwire:types` (exceptions, `Decimal`, `MonthInterval`), `:io` (transports, I/O backends, buffers), `:tls` (OpenSSL loaded at run time), `:client` (DSN, failover, pool core), `:crypto` (AES-CBC, PBKDF2, secure random for O5LOGON), `:charset` (UTF-16 for the national character set). Anything not protocol-specific is added to dbwire (issue + PR there), not here.
- **Sibling projects:** `../mssql-native` (SQL Server, the closest model: packet layer over a byte stream, result streaming, parameters, pool, mapping, tests) and `../clickhoused` (ClickHouse). Follow their structure, API style, tests and conventions (their `AGENTS.md`).
- **`PLAN.md` (local and optional):** the design plan (protocol overview, types, milestones, decisions) is a local, untracked file (excluded through `.git/info/exclude`). If present, read it before design-level changes and keep it up to date; never `git add` it.

## Workflow

- **Every change goes through an issue and a pull request. Never push to `main` directly.** One feature branch per issue; the PR says `Closes #N`. The author merges.
- Commit, push and open PRs only when the user asks. Releases and tags only on request (version constants in `source/oracle/package.d` and `CHANGELOG.md`; the author pushes the `vX.Y.Z` tag).

## Key design rules

1. **Pure D, zero C dependencies by default.** OpenSSL is loaded at run time through dbwire for TLS only; the password exchange uses dbwire's pure-D crypto.
2. **Dual I/O.** Anything that can block goes through dbwire's `IoBackend`/`Transport`; never call `std.socket`, `core.sync`, `Thread.sleep` or vibe APIs from protocol, connection or pool code. vibe code under `version (Have_vibe_core)`.
3. **Runtime interfaces, not templates**, for what a `Connection` holds; `Connection` stays one non-templated class (for the ddbc driver).
4. **Connection invariants** (as in clickhoused and mssql-native): one call at a time; a result holds the connection until drained or closed; cancel (break) is the only call allowed from another thread or task; a broken stream poisons the connection, which is never returned to a pool.
5. **Robust decoding:** malformed or truncated input throws `ProtocolException`; never crash, never allocate from an unchecked length.
6. **Version gating:** many TTC message fields depend on the negotiated **TTC field version** (7 = 12.1 … 24 = 23.4) and the TNS version (315, 318, 319). Gate every such field explicitly, with constants named after the release that introduced them. A wrong gate desynchronizes the stream silently (e.g. the 23ai token number on a 21c server gives ORA-03120).
7. **Text:** the client declares AL32UTF8 (873) as its character set, so the server converts all text to UTF-8; national character data arrives as AL16UTF16 (UTF-16BE).

## Licensing rules (important)

- **There is no public specification of the protocol.** Write the implementation from facts (layouts, constants, algorithm steps), verified against real servers (golden bytes).
- **Other clients are reference only — never copy or translate their code:** python-oracledb thin and node-oracledb thin (Oracle, UPL-1.0 OR Apache-2.0), go-ora (MIT). Line-by-line translation counts as copying. Wire-format facts are fine to reproduce.
- Data tables (e.g. time zone region IDs → names) are generated from the server, not copied from other clients.
- If any third-party code or data seems necessary, **stop and ask the user first**.
- The README says the project is unofficial and not affiliated with Oracle, and notes the trademark.

## Decisions (2026-11-02)

Oracle 12.1+ on the wire, tested on 23ai Free, 21c XE and 18c XE (no free 19c image); explicit commits with an `autoCommit` option; `:1`/`:name` bind placeholders plus `?` rewritten to `:1, :2, ...`; timestamps keep their nanoseconds raw (`getSysTime` truncates to 100 ns, plus `getNanoseconds`); Native Network Encryption refused in 0.x (TLS instead; `NA_DISABLED` in CONNECT); the time zone region table is generated from the server.

## Commands

The recipe format is **`dub.json`**.

```sh
dub build                                                  # library
dub test                                                   # unit tests
dub run dscanner@0.15.2 -- --styleCheck .                  # lint (CI fails on any warning)
dub run dfmt@0.15.2 -- --inplace $(git ls-files '*.d')     # format (CI fails if this changes files)
dub build -b docs                                          # docs into /docs/ (git-ignored)
dub run :integration-tests-phobos                          # integration tests, threads
dub run :integration-tests-vibe                            # the same tests in vibe.d tasks
dub run :integration-tests-vibe1                           # ... with vibe-core 1.x
ORACLE_HOST=localhost:11521 ORACLE_SERVICE=FREEPDB1 ORACLE_PASSWORD=Test_password123 dub run :integration-tests-phobos
sh integration-tests/tls/start-proxy.sh 127.0.0.1:11521 12484   # TLS proxy as a TCPS stand-in, then add:
ORACLE_TLS_HOST=127.0.0.1:12484 ORACLE_TLS_CA=$PWD/integration-tests/tls/ca.pem
sh integration-tests/tls/start-proxy.sh 127.0.0.1:11521 12485 oracle-native-tls-client client   # mutual TLS:
ORACLE_TLS_CLIENT_HOST=127.0.0.1:12485
```

Integration tests: a `void function()` that throws on failure in an `integrationtests.*` module, listed in `allTests` (`integration-tests/source/integrationtests/harness.d`); mode-specific ones in `threadTests` (`integration-tests-phobos/source/threadtests.d`) and `vibeTests` (`integration-tests-vibe/source/vibetests.d`). Server tests use `connectToServer()` and `scalar()` from `integrationtests.server`.

Run lint and format before committing D code. dfmt 0.15.2 mangles lambdas with attributes (`() nothrow {` → `() nothrow{`): use named nested functions. It merges `@safe return` into `@safereturn`: avoid the `return` attribute. Run dfmt twice when it changes files. `dub.selections.json` files are git-ignored (a root one listing vibe-core would enable vibe support silently).

## Local environment

- WSL2 Linux. **LDC 1.36.0** (`ldc2`); DMD is not installed. Test the minimum frontend with LDC 1.27.1 (download `https://github.com/ldc-developers/ldc/releases/download/v1.27.1/ldc2-1.27.1-linux-x86_64.tar.xz` into the scratchpad, run dub with `--compiler=<path>/bin/ldc2`).
- Oracle in Docker: container `oracle-free` (`gvenzl/oracle-free:23`, 23ai Free) on port **11521**, service `FREEPDB1`; `SYSTEM` password `Oracle_test123`, application user `testuser` / `Test_password123`. `sqlplus` is inside the container: `docker exec -it oracle-free sqlplus testuser/Test_password123@FREEPDB1`.
- 21c and 18c: containers `oracle-xe21` (port **11522**) and `oracle-xe18` (port **11523**; its XEPDB1 has `DBTIMEZONE` `+05:00`, the only local database where WITH LOCAL TIME ZONE values differ from UTC)
- BFILE tests need the directory `ITEST_DIR` (`/tmp`, readable by testuser) with `/tmp/hello.txt` = "hello from a bfile\n" in the container; set up in oracle-free and oracle-xe18 and by a CI step (see `.github/workflows/ci.yml`); skipped without it., images `gvenzl/oracle-xe:21-slim-faststart` / `:18-slim-faststart`, service `XEPDB1`, same users. Each needs about 2 GB of memory: run one besides `oracle-free` at a time (`docker start`/`docker stop`).
- The local `grep` is ugrep, which treats files with odd bytes as binary and prints nothing: use `grep -a` on wire dumps.

## Layout

```
source/oracle/
  package.d            public imports, version constants, oracleHasVibe
  connection.d         Connection: listener handshake (REDIRECT, RESEND, REFUSE), TLS, negotiation, O5LOGON,
                       exec/query/commit/rollback/ping/close, response reading, deferred cursor closing
  result.d             QueryResult (input range, fetches in batches), Row (typed getters)
  settings.d           ConnectionOptions; URL, Easy Connect and descriptor parsing (DescriptorNode)
  tnsnames.d           tnsnames.ora: finding (config_dir, TNS_ADMIN, ORACLE_HOME), parsing, IFILE
  pipeline.d           Pipeline, PipelineResult (run by Connection.runPipeline)
  statement.d          statement classification by first keyword
  exception.d          ServerException (ORA code, message, position) + dbwire's exceptions
  protocol/            tns.d (packets, TnsStream), ttc.d (ub*/CLR), negotiate.d (protocol and data-type messages,
                       capabilities, the generated type table), auth.d (O5LOGON), messages.d (function header,
                       key/value pairs, ERROR), execute.d (EXECUTE/FETCH, describe info, rows, piggybacks),
                       scripted.d (unittest builds: scripted server responses for `Connection.scripted`, a
                       logged-in connection over dbwire's MockTransport)
  value.d              Value: one column value and its getters (Row delegates to it)
  params.d             Parameter (D values → bind types and wire values), placeholders, ? rewriting
  lob.d                Lob (locator operations: length, read, write, trim, temporary LOBs, BFILE), LOB_OP messages
  pool.d, mapping.d    ConnectionPool (dbwire PoolCore), struct mapping (as in mssql-native)
  types/               typeinfo.d (OracleType, ColumnInfo), number.d (NUMBER), floats.d (BINARY_FLOAT/DOUBLE),
                       encode.d (D values → NUMBER, BINARY_*, DATE, TIMESTAMP*, INTERVALs for binds),
                       temporal.d (DATE, TIMESTAMP*, INTERVALs), rowid.d (ROWID, UROWID),
                       tzregions.d (generated by tools/tzregions.d: region ID → name), oson.d (OSON decoder: JSON text; encoder for JSON binds), vector.d (Vector, VECTOR images and text)
tools/                 tzregions.d: regenerates the time zone region table from a server
integration-tests/     shared harness (dub subpackage `:integration-tests`); tls/ has the test CA, server certificate
                       and the TLS proxy script
integration-tests-phobos/, integration-tests-vibe/, integration-tests-vibe1/   runners (vibe1: vibe-core 1.22.6,
                       sharing the vibe runner's sources)
examples/basic, examples/vibe   dub subpackages :example-basic, :example-vibe (ORACLE_CONNECTION, ORACLE_USER, ORACLE_PASSWORD)
```

## Protocol behaviour learned from real servers

Checked on 26ai Free (23.26), 21c XE and 18c XE.

- **Versions:** the client offers TNS 319 and TTC field version **24** (23.4). With 23ai (accept flags 2 `0x02000000`) it then asks for END_OF_RESPONSE (TTC4 `0x20`, with TTC5 `0x04`/`0x10` for pipelining): every function response ends with message type 29 after its ERROR/STATUS (negotiation responses don't); older servers answer with 318 or lower, where a response ends at its ERROR or STATUS. No fast auth. The negotiated field version is min(client, server); 26ai's is 27 (→ 24), 21c's 16, 18c's 11. Gated fields up to 24: ERROR 20.1 fields (see below), the function and piggyback header token number (18), describe information (17, 20, 24, below). END_OF_RESPONSE (TNS 319) is not needed for any of it.
- **Describe layout needs the UDS type:** the server sends the 23.x describe fields (domain, annotations, VECTOR metadata) only when the data-type list includes **type 663 (UDS)**, although its identity-conversion answer doesn't list it; without it the describe keeps the 19c layout whatever field version was negotiated (and the stream desynchronizes). With it: after the UDS flags (`0x100` IS JSON, `0x800` OSON), from 23.1 the domain schema and name (text with length each), from 23.1 ext3 the annotations (ub4 count; if non-zero: a byte, ub4 count, a byte, then per annotation key, value (text with length) and ub4 flags, then ub4 flags), from 23.4 the VECTOR dimensions (ub4), format (u8) and flags (u8).
- **Pipelines** (needs END_OF_RESPONSE): the first request starts with the BEGIN_PIPELINE piggyback (function 199: ub2 error set ID 0, u8 error set mode 0, u8 mode 1 continue / 2 abort on error) and its packets have data flag `0x1000`; the last packet of every request has `0x0800` (end of request); then END_PIPELINE (function 200, ub4 0). The server answers each request in order (each ending with message 29), then the end call. MARKER packets in between are skipped (no reset handshake): the ERROR follows. In abort mode the calls after a failed one are not run (their responses are errors). A query with LOB/JSON/VECTOR columns returns no rows until its DEFINE, which is done after the pipeline.
- **Data-type negotiation:** the server needs its internal TTC types listed, or it closes the connection at the first call (its trace says "Network protocol error on first data after new connect", ORA-28546). `negotiate.d` lists every type 26ai accepts with an identity conversion (generated from its answer to a request for types 1–1023), plus NUMBER and DATE (and their aliases) in representation 10, and **type 27 in representation 10**: in the universal representation, one-byte fields such as a column's scale come as length-prefixed integers.
- **ERROR message:** the end-to-end sequence number (ub2) after the call status is sent to clients with the OCI1 capability bit 0x10, which this client sets: without it the server ignores end-to-end attributes (SET_END_TO_END_ATTR piggyback, function 135). STATUS then has it too (ub4 call status, ub2 sequence number). The SQL type and checksum fields (20.1) depend on the *server's* field version (≥ 14), whatever the client announces (checked with client versions 10–24 on 26ai; absent on 18c). The ROWID in it has no length byte (in fetched rows it has one). STATUS (ping, logoff) is just the ub4 call status.
- **Describe information** honours the client's field version. A column's position and flags vary; NULL literals are VARCHAR2 with buffer size 0.
- **Rows:** a column with buffer size 0 sends no bytes at all (always NULL), except LONG, LONG RAW and UROWID. Duplicate-column bit vectors arrive in BIT_VECTOR messages *or* inside ROW_HEADERs (length, the length again, the bits); a clear bit repeats the previous row's value, also across fetches. The first response to a query may have no rows even with rows to come.
- **Cursors:** every EXECUTE with cursor 0 opens a cursor on the server (300 open cursors by default). The client closes them with the close-cursors piggyback (function 105) sent before the next call; the cursor ID comes in the ERROR message, also after errors.
- **Text:** with AL32UTF8 as both client character sets, NCHAR/NVARCHAR2 still arrive as AL16UTF16 (UTF-16BE, describe charset ID 2000).
- **Login:** a wrong password and an unknown user both give ORA-01017 (a server error: failover stops). An unknown service is the listener's REFUSE with ERR=12514 (a connection error: failover goes on). `AUTH_VERSION_NO` decodes as major.minor(8 bits).patch.port(8 bits).build from server field version 18.1 ext1 on. **Proxy authentication:** both phases carry the proxy user's name; phase 2 adds `PROXY_CLIENT_NAME` (the target user) as its first key/value pair, and the password is the proxy user's. A target that doesn't allow the proxy is refused with ORA-01017, like a wrong password (not ORA-28150).
- **Logoff:** function 9, its STATUS, then a DATA packet with the EOF flag.
- **DRCP** (`SERVER=POOLED`; checked on 23ai, 21c, 18c): the client must set OCI2 (compile capability 31) `0x10`, else the login fails with ORA-56606. Phase 2 adds `AUTH_KPPL_CONN_CLASS` (when set) and `AUTH_KPPL_PURITY` ("1" new, "2" self; flags 1) after `AUTH_ALTER_SESSION`. Releasing the session is a one-way call (message type 26, function 163: u8 0, u8 0 (no tag), ub4 mode: 0 keep for the class, 2 deauthenticate); the server sends nothing back. The next call attaches a session and its response carries the session-return server piggyback (opcode 4: ub2, u8, ub2 number of key/value pairs, if any a u8 then per pair ub2 + bytes for key and value and ub2 flags; then ub4 flags, `0x04` = another session, ub4 session ID, ub2 serial number); a standalone connection gets one with its first call too (the login's `AUTH_SESSION_ID` may not be the session used). With another session the cached cursor IDs are invalid: the cache is dropped, and no close-cursors piggyback goes before the first call after a release. A DRCP connection closes without logoff (deauthenticating release, then EOF). A released session with an open transaction must be rolled back first. A released session keeps its end-to-end attributes (CLIENT_IDENTIFIER etc.; checked on 23ai): a new connection with purity self can get it with another client's attributes, and a connection that gets another session loses its own; so all five are sent with the first call after the login and after every release (#45). Released sessions usually go back to the same connection (affinity); a third connection takes one that is released.
- **BOOLEAN** (field version ≥ 23.1): values are CLRs `01 01` (true) and `00` (false); a NULL BOOLEAN bind is written as the bytes 253, 1. Below 23.1 columns and `TRUE` arrive as NUMBER 1/0, and `bool` binds are converted to NUMBER (`asNumberBoolean`); 23ai converts BOOLEAN binds into NUMBER columns itself.
- **JSON and VECTOR:** JSON columns are type 119 from field version 21.1 (below, a BLOB with the OSON UDS flag, which a LONG RAW define makes fail with ORA-01002). VECTOR is type 127 when the client sends TTC5 (cap 44) bit 0x08 and VECTOR features (cap 52) 0x01 binary / 0x02 sparse at field version 23.4; otherwise the server converts it to CLOB text. Both need a DEFINE with the LOB prefetch flag (0x2000000) and a prefetch length (JSON 32 MB, VECTOR 1 MB) as buffer size and "max chars"; values arrive as ub4 length (0 = NULL), ub8 size, ub4 chunk size, the image (CLR), the locator (CLR, unused). A VECTOR bind has the same prefetch metadata and the value ub4 40, a byte 40, a 40-byte value-based locator (u16 38, u16 version 4, flags 0x61, 0x08, u16 0, u16 1, u64 image length, 22 zero bytes), then the image as a CLR. The server's texts: `JSON_SERIALIZE` writes NUMBERs plainly with at most 40 digits before and after the point, else `1.5E-40`; dates and timestamps as ISO 8601 with 6 fraction digits for timestamps; DAY TO SECOND as `P1DT2H3M4.500000S`; RAW in upper-case hex. `FROM_VECTOR` writes FLOAT32 with 9 and FLOAT64 with 17 significant digits (`1.5E+000`, trailing zeros dropped, exponent at least 3 digits), zero as `0`. 21c refuses JSON keys longer than 255 bytes (ORA-40476). **JSON binds** (field version ≥ 21.1; checked on 23ai and 21c): type 119 with the LOB prefetch flag and prefetch length 32 MB, the value written like a VECTOR bind (QLocator, then the OSON image); OUT values and `RETURNING ... INTO` come like fetched JSON. Older servers get the text. **OSON images the server accepts** (as python-oracledb writes them): field names hashed with FNV-1a 32 (offset basis 0x811C9DC5, prime 16777619; short names store the low byte, long ones the low 16 bits), sorted by (hash byte, length, bytes), IDs 1-based in that order (short names first); header flags 0x2106 (+0x0400/0x08 for 16/32-bit field IDs, +0x0800 for a short-name segment over 64 KB, +0x1000 for a tree over 64 KB), version 3 only with names over 255 bytes (23.1+); a scalar image has flags 0x0016 and only the tree size. Containers: object 0x84 / array 0xC0, +0x20 for 32-bit child offsets (absolute from the tree start), +0x08/0x10 for 16/32-bit counts. Members may stay in the given order: the server finds them (its own parser sorts objects of more than about 10 members by field ID). The server's JSON parser refuses repeated member names (ORA-40444 on 23ai, ORA-40473 on 21c), rounds numbers to NUMBER's 20 base-100 digits (half up), and stores numbers outside NUMBER's range as BINARY_DOUBLE on 23ai (21c: ORA-01426 overflow). In images: INTERVAL YEAR TO MONTH is node 0x3D + 5 bytes (text `P1Y2M`, `-P3M`, `P0Y`); `JSON_SERIALIZE` writes BINARY_FLOAT/DOUBLE with their shortest digits in the NUMBER format (`0.00001`, `1E+300`), except denormal floats (`1.4E-45` where the shortest is 1E-45, `4.9E-324` for the smallest double) and 2^53 (`9007199254740993`). At other powers of two it takes the nearest digits, one more when the nearest of the shortest length doesn't read back (2^-24 is `0.000000059604644775390625`, not the shortest `5.960464477539063E-8`), as C's `%.*g` with growing precision does; `floatText`/`floatDigits` do the same (checked on 23ai, #46). **Re-executing PL/SQL:** the REEXECUTE response has no IO_VECTOR (the client keeps the directions of the first execution) and takes no values for OUT parameters (as the IO vector says; IN OUT ones get theirs).
- **Types at field version 13:** BOOLEAN (23ai) columns and `TRUE` arrive as NUMBER 1/0 (real BOOLEAN needs field version ≥ 23.1). LONG and LONG RAW values are a chunked CLR followed by an sb4 indicator and a ub4 return code; their describe buffer size is 0. UROWID is a ub4 length plus a CLR; a logical one prints as `*` + base64 (no padding) of the bytes after the first. TIMESTAMP values with no fraction come as 7 bytes. TIMESTAMP WITH TIME ZONE carries UTC plus an offset (hours + 20, minutes + 60) or a region ID (`(b11 & 0x7F) << 6 | b12 >> 2`); region IDs are the same across time zone file versions (18c's 595 are a subset of 26ai's 600, same IDs). **WITH LOCAL TIME ZONE values come in the database time zone (`DBTIMEZONE`)**, not the session's: the client reads DBTIMEZONE once, when a result first has such a column, and converts. Intervals: years/days + 2³¹, the other parts + 60, nanoseconds + 2³¹.
- **Binds** (checked against python-oracledb's bytes for the same calls): EXECUTE gets the BIND option and the bind count; after al8i4 come per bind its metadata (type, flags 01, precision/scale 0, ub4 buffer size, then zeros except charset 873 and form 1 for text; oaccolid from 12.2) and per execution a ROW_DATA with the values (CLRs). **No ROW_DATA without values to send** (no binds, or only RETURNING targets): an empty one gives ORA-03146. Python sizes VARCHAR2 binds at 4 × the UTF-8 length.
- **Re-execution** of a cached cursor: REEXECUTE (4: cursor, executions, options 0, commit 0/1) or REEXECUTE_AND_FETCH (78: cursor, prefetch rows, options 0x20, 0), then only the values. A re-executed query gets no describe information (the cache keeps the columns). ORA-01007/00932 on a cached query: its tables changed, parse again.
- **PL/SQL binds:** option PLSQL_BIND (0x400) instead of NOT_PLSQL; the response starts with an IO_VECTOR (a direction per bind: 0x10 OUT, 0x20 IN, 0x30 IN OUT), then a ROW_DATA with the OUT and IN OUT values only, each followed by an sb4. **RETURNING INTO:** no IO_VECTOR; the targets (placeholders after `RETURNING ... INTO`) get no value sent; the ROW_DATA has, per target, a ub4 row count and that many values (each with an sb4).
- **Array DML:** executions in al8i4[1], one ROW_DATA per row; DML row counts (option field `1, n, 1` and flag 0x4000) come after the return parameters (ub4 count, ub8 each). With BATCH_ERRORS (0x80000) the server sends a BREAK and a RESET marker before the ERROR (ORA-24381), which lists codes, row offsets and messages; the arrays' end byte is only there when their first byte is 254. A cached cursor runs again with an EXECUTE without PARSE (cursor ID, no SQL).
- **Child cursors:** IMPLICIT_RESULTSET (ub4 count; per result a length-prefixed skip, describe information without its leading CLR, ub2 cursor ID) and REF cursor values (a byte, the same describe, ub2 cursor ID). Their first fetch is an EXECUTE with options FETCH | NOT_PLSQL and the cursor ID (al8i4[1] = rows), then FETCH.
- **Cancel:** the server here doesn't accept out-of-band breaks, so cancel is an in-band INTERRUPT marker. Every INTERRUPT, busy or idle, gets one RESET marker (the client answers RESET) and an ORA-01013 ERROR, possibly after the interrupted call's own response; when the RESET marker comes first the client must not wait for another one. The server checks for interrupts while it works (a busy query stops within a second) but not during `DBMS_SESSION.SLEEP` (python-oracledb waits the same).
- **LOBs** (checked against python-oracledb's bytes): a query with LOB columns returns no rows from its execution; the client sends an EXECUTE with only DEFINE (no EXECUTE option; al8i4[1] = rows to fetch) and a define per column (bind-like metadata), and the rows come with that response. Defining CLOB/NCLOB as LONG and BLOB as LONG RAW (buffer 0x7FFFFFFF, charset 873 with the column's form) brings the contents inline in the LONG format; as CLOB/BLOB (buffer 112, continuation flag 0x2000000) brings locators: ub4 length, ub8 size, ub4 chunk size, CLR locator (BFILE: ub4 length, CLR locator). A cursor keeps its defines when re-executed.
- **LOB_OP (96):** source locator and its length, operation, 1-based offsets, an optional amount; data comes in LOB_DATA (14) messages; the PARAMETER answer is the locator, then echoes of what was sent: the character set (CREATE_TEMP), the amount, the NULL-LOB flag byte (CREATE_TEMP, is-open/exists). CREATE_TEMP puts the charset form in the source offset, the LOB type in the destination offset, the duration (10, session) in the destination length, and sends a 40-byte zero locator. BFILE reads are wrapped in FILE_ISOPEN / FILE_OPEN (amount 11, read-only) / FILE_CLOSE. CLOB data in a variable-width database character set is UTF-16 (locator byte 6 has 0x80; little-endian if byte 7 has 0x40); amounts, offsets and `LENGTH` count UTF-16 units.
- **Long binds:** strings and bytes over 32767 bytes bind as VARCHAR2/RAW with a large buffer (4 × the UTF-8 length) and a chunked CLR; within a row such values must come **after all the other values**, else the server applies them to the wrong position (ORA-01461 on the next bind). `CAST(NULL AS BFILE)` is refused in SQL (ORA-22849). 21c refuses one placeholder used twice in SQL with a long value (two LONG binds: ORA-22284); 18c and 23ai accept it.
- **Server text:** `TO_CHAR` prints region names upper case and NUMBER as `.5`; oracle-native keeps IANA case and `0.5` (the rest of the date, timestamp and interval texts match the server). `INTERVAL YEAR(9)` values exceed `MonthInterval`.
- **TLS tests** use a socat proxy (`integration-tests/tls/start-proxy.sh`) in front of the plain listener: TCPS is TLS from the first byte with the same TNS traffic inside. A second proxy (`client` mode) requires client certificates, for mutual TLS with the test wallet (`integration-tests/tls/wallet/ewallet.pem`: the encrypted client key, the client certificate, the CA; password `Wallet_pw123`). Server-side TCPS features (RESEND with renegotiation, the listener's own wallet) are not covered.
- **Wallets:** thin clients read the PEM form `ewallet.pem` (`orapki wallet pem_asn1`), not `ewallet.p12`/`cwallet.sso`: the certificates are the trusted CAs, and a private key (usually `ENCRYPTED PRIVATE KEY`, PKCS#8) with the first certificate after it is the client certificate. `SSL_SERVER_CERT_DN` is compared as a set of attribute/value pairs with the certificate's RFC 2253 subject, instead of the host name; the chain is still verified.
- **Debugging:** set `ConnectionOptions.transportFactory` to wrap the transport in a logging one to see the bytes.

## Conventions

- `@safe` by default; small commented `@trusted` blocks only in I/O and reinterpret-cast hot paths.
- **Every public symbol gets a Ddoc comment**; documented unittests as usage examples.
- Every type gets golden-byte unit tests and server round trips in both I/O modes; cover NULLs, extremes, non-ASCII text, national character sets, time zones (offsets and regions), nanoseconds.

## D idioms and review lessons

Learned from the review of the MySQL 8 work in mysql-native (mysql-d/mysql-native#288, 2026-11). All of these work on the minimum frontend 2.097; checked with LDC 1.27.1.

- **`BigInt` and bytes: never go through hex or decimal strings.**
  - Bytes to `BigInt`: `BigInt(false, bytes)` takes any finite range of unsigned integers, most significant first.
  - `BigInt` to words or bytes: `value.getDigit!uint(i)` or `getDigit!ulong(i)` for `i` below `uintLength` or `ulongLength`, least significant first. dbwire's `WideInt.fromBigInt` does this.
  - Modular exponentiation: `std.bigint.powmod`.
  - `format("%x", bigint)` groups digits with `_` until Phobos 2.114 (dlang/phobos#11051).
- **Enums for protocol names.** For a fixed set of wire strings such as plugin names, use a `ubyte` enum whose members are spelled exactly like the wire names; the protocol's own spelling beats camelCase here.
  - `to!string` then gives the name to send. It returns the stored literal and doesn't allocate for a valid member, but it isn't `nothrow` or `@nogc`.
  - To parse untrusted input, loop over the members: `static foreach (m; __traits(allMembers, E)) if (name == m) return __traits(getMember, E, m);`. This is `nothrow @nogc` and compares the packet slice directly, with no `idup`. Don't use `to!E(name)`, which throws `ConvException` on unknown names.
  - Each name then appears once, instead of in a parse table and a format table that can drift apart.
  - With a `string`-based enum, `to!string` returns the member's identifier, not its value.
- **Small idioms:**
  - Test byte vectors: `cast(const(ubyte)[]) std.conv.hexString!"0a1b..."` instead of hand-written hex decoding.
  - Strip leading zero bytes with `find!(b => b != 0)`.
  - Copy (`idup`) a slice only where it must outlive the buffer; an error message built inside `enforce` is lazy, so copying there is fine.
- **Function attributes** (`@safe`, `@trusted`, `pure`, `nothrow`, `@nogc`, `scope`). Sources: the D spec (function.html, attribute.html), the D blog's memory-safety series, and the D forum consensus. Behaviour checked with LDC 1.27.1 and 1.36 (2026-11-08).
  - **Inference.** Templates, `auto` functions, nested functions and lambdas infer `@safe`, `pure`, `nothrow` and `@nogc`. Other functions infer nothing, even when their body is visible.
    - Write the attributes on ordinary functions, public API first.
    - Leave them off templates. An attribute written on a template binds every instantiation (an `@safe` template rejects a `T` whose copy is `@system`).
    - Lock in what a template infers with an attributed unittest that instantiates it with plain types, e.g. `@safe pure nothrow @nogc unittest`.
  - **`@safe:` at module scope** covers everything after it, templates included; they still infer the other attributes. `pure`, `nothrow` and `@nogc` don't propagate into struct and class bodies.
  - **`@trusted` promises a safe interface.** For every argument a `@safe` caller can pass, the function must not corrupt memory or create an unsafe value, such as a dangling pointer or a `bool` other than 0 or 1. The compiler doesn't check the body.
    - Keep the trusted part as small as possible: trust the one `@system` call, e.g. `(() @trusted => v.get!T)()`, with a comment saying why it is safe.
    - A trusted lambda makes the enclosing function part of the review. Whatever the lambda relies on, such as a length checked a few lines earlier, must stay true when that function changes.
    - A `cast(ubyte[])` view of values without indirections is fine for reading. Writing arbitrary bytes into `bool` or enum values through such a view creates invalid values; normalize them before `@safe` code sees them.
  - **Never mark a template `@trusted` if its body copies, constructs or destroys a `T`.** The attribute hides `T`'s `@system` postblit, copy constructor or destructor. Checked: `V wrap(T)(ref T v) @trusted { T copy = v; ... }` compiles in `@safe` code for a struct with a `@system` postblit. Trust only the `@system` call inside, which lets inference catch `T`, or constrain `T` (`!hasIndirections!T`, `!hasElaborateCopyConstructor!T`).
  - **`nothrow`**: only `Error`s may escape.
    - Wrap calls that can't actually throw in `std.exception.assumeWontThrow`, or in `try ... catch (Exception e) assert(0, e.msg);`.
    - Never catch `Error` or `Throwable` to make code `nothrow`.
  - **`@nogc`** forbids `new`, array appending and concatenation, closures that escape, and `throw new`. Use it for leaf hot paths (codecs, parsers); error paths that throw stay outside it.
  - **`debug` statements** may break `pure`, `nothrow` and `@nogc`, which helps temporary logging. They compile only with `-debug`; don't leave them in committed code.
  - **`scope` and `return scope`** are checked only in `@safe` code compiled with `-preview=dip1000`, which is still not the default (D 2.113, August 2026).
    - Without that switch, `scope` is an unchecked promise. With it, callers may pass stack memory to a `scope` parameter, so a `@trusted` or `@system` function that keeps such a parameter has a memory bug.
    - dbwire, clickhoused and postgresql-native are dip1000-clean on current compilers: CI runs their unit tests with `-preview=dip1000` on dmd-latest and ldc-latest (dbwire#50, clickhoused#71, postgresql-native#37). Older Phobos isn't: 2.097's `std.socket` has no `scope` annotations. oracle-native and mssql-native haven't been checked yet. Don't add `scope` speculatively.
- **Changes to someone else's code: keep the diff small.** Keep the existing structure, and change the input instead of the cases. For example, when MySQL 8.4 inserted a `Language` column after `Type` in `SHOW PROCEDURE STATUS` (5.7, 8.0 and MariaDB don't have it; the manual doesn't list it), the fix kept the old switch on column numbers: skip column 3 when there are 12 columns, and shift the later indexes down by one.
- **Check facts before writing them down.** Verify server behaviour on the real servers, since manuals lag behind. Take CI failure reasons from the job logs, not from memory. A wrong reason in a commit message had to be corrected during that review.
- **CI facts (November 2026):**
  - GitHub retired the `ubuntu-20.04` runners. When a matrix tests old compilers, pin a concrete image instead of `ubuntu-latest`, and prefer the oldest one still offered: `ubuntu-22.04` today (likely until mid-2027). The mysql-native reviewers asked for that as the most conservative choice, and old compilers down to dmd 2.097 / ldc 1.27 pass on it.
  - `macos-latest` is macOS 26 on arm64. There:
    - `setup-dlang` installs no DMD;
    - `setup-dlang@v1` requests `ldc2-1.28.1-osx-aarch64.tar.xz`, while LDC names the file `osx-arm64`, so the download fails with a 404.
  - `macos-15-intel` runs dmd-latest, dmd 2.098.1 and LDC 1.28.1. On macOS 15, even Intel, the dmd 2.101.2 binary doesn't run and LDC 1.31.0's dub crashes (SIGSEGV).
  - With `setup-dlang@v2.0.0`, programs built by LDC 1.30, 1.35 or 1.40.1 crash (segfault, even hello world) on `macos-latest`, `macos-15` and `macos-15-intel`. LDC 1.41.0 is the oldest that works there, so our CI tests ldc-latest and 1.41.0 on macOS, and the older LDCs on Linux.
  - `WebFreak001/dub-upgrade@v0.1.1` uses GitHub's retired cache service ("getCacheEntry failed"); v0.2.0 works.
