# AGENTS.md

Guidance for AI coding agents working on **oracle-native**, a native D client for Oracle Database.

## Project at a glance

- **What:** a pure-D client for Oracle Database over the **Oracle Net (TNS) and TTC protocols** (TCP, port 1521; TCPS for TLS), for Oracle Database 12.1 and later (TNS version ≥ 315), with blocking (thread) and vibe.d (fiber) I/O. dub package `oracle-native`, root module `oracle`.
- **Repo:** `git@github.com:buggins/oracle-native.git`, default branch `main`. Author Vadim Lopatin (GitHub `buggins`). License BSL-1.0.
- **Status:** under development; roadmap issue #10 lists milestones O0–O8 (one issue each).
- **Builds on dbwire** (`../dbwire`, 0.5): `dbwire:types` (exceptions, `Decimal`, `MonthInterval`), `:io` (transports, I/O backends, buffers), `:tls` (OpenSSL loaded at run time), `:client` (DSN, failover, pool core), `:crypto` (AES-CBC, PBKDF2, secure random for O5LOGON), `:charset` (UTF-16 for the national character set). Anything not protocol-specific is added to dbwire (issue + PR there), not here.
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
ORACLE_HOST=localhost:11521 ORACLE_SERVICE=FREEPDB1 ORACLE_PASSWORD=Test_password123 dub run :integration-tests-phobos
sh integration-tests/tls/start-proxy.sh 127.0.0.1:11521 12484   # TLS proxy as a TCPS stand-in, then add:
ORACLE_TLS_HOST=127.0.0.1:12484 ORACLE_TLS_CA=$PWD/integration-tests/tls/ca.pem
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
  statement.d          statement classification by first keyword
  exception.d          ServerException (ORA code, message, position) + dbwire's exceptions
  protocol/            tns.d (packets, TnsStream), ttc.d (ub*/CLR), negotiate.d (protocol and data-type messages,
                       capabilities, the generated type table), auth.d (O5LOGON), messages.d (function header,
                       key/value pairs, ERROR), execute.d (EXECUTE/FETCH, describe info, rows, piggybacks)
  value.d              Value: one column value and its getters (Row delegates to it)
  params.d             Parameter (D values → bind types and wire values), placeholders, ? rewriting
  lob.d                Lob (locator operations: length, read, write, trim, temporary LOBs, BFILE), LOB_OP messages
  types/               typeinfo.d (OracleType, ColumnInfo), number.d (NUMBER), floats.d (BINARY_FLOAT/DOUBLE),
                       encode.d (D values → NUMBER, BINARY_*, DATE, TIMESTAMP*, INTERVALs for binds),
                       temporal.d (DATE, TIMESTAMP*, INTERVALs), rowid.d (ROWID, UROWID),
                       tzregions.d (generated by tools/tzregions.d: region ID → name)
tools/                 tzregions.d: regenerates the time zone region table from a server
integration-tests/     shared harness (dub subpackage `:integration-tests`); tls/ has the test CA, server certificate
                       and the TLS proxy script
integration-tests-phobos/, integration-tests-vibe/   runners
```

## Protocol behaviour learned from real servers

Checked on 26ai Free (23.26), 21c XE and 18c XE.

- **Versions:** the client offers TNS 318 (no END_OF_RESPONSE, no fast auth: a response ends after its ERROR or STATUS message) and TTC field version **13** (19.1 ext1). The negotiated field version is min(client, server); 26ai's is 27, 21c's 16, 18c's 11. Raising the client's means implementing every gated field in between (describe information has 23.1 fields from 17; the function header gets a token number from 18). `readDescribeInfo` refuses field versions ≥ 23.1 until then.
- **Data-type negotiation:** the server needs its internal TTC types listed, or it closes the connection at the first call (its trace says "Network protocol error on first data after new connect", ORA-28546). `negotiate.d` lists every type 26ai accepts with an identity conversion (generated from its answer to a request for types 1–1023), plus NUMBER and DATE (and their aliases) in representation 10, and **type 27 in representation 10**: in the universal representation, one-byte fields such as a column's scale come as length-prefixed integers.
- **ERROR message:** the end-to-end sequence number after the call status is only sent to clients with the OCI1 capability bit 0x10 (not set here). The SQL type and checksum fields (20.1) depend on the *server's* field version (≥ 14), whatever the client announces (checked with client versions 10–24 on 26ai; absent on 18c). The ROWID in it has no length byte (in fetched rows it has one). STATUS (ping, logoff) is just the ub4 call status.
- **Describe information** honours the client's field version. A column's position and flags vary; NULL literals are VARCHAR2 with buffer size 0.
- **Rows:** a column with buffer size 0 sends no bytes at all (always NULL), except LONG, LONG RAW and UROWID. Duplicate-column bit vectors arrive in BIT_VECTOR messages *or* inside ROW_HEADERs (length, the length again, the bits); a clear bit repeats the previous row's value, also across fetches. The first response to a query may have no rows even with rows to come.
- **Cursors:** every EXECUTE with cursor 0 opens a cursor on the server (300 open cursors by default). The client closes them with the close-cursors piggyback (function 105) sent before the next call; the cursor ID comes in the ERROR message, also after errors.
- **Text:** with AL32UTF8 as both client character sets, NCHAR/NVARCHAR2 still arrive as AL16UTF16 (UTF-16BE, describe charset ID 2000).
- **Login:** a wrong password and an unknown user both give ORA-01017 (a server error: failover stops). An unknown service is the listener's REFUSE with ERR=12514 (a connection error: failover goes on). `AUTH_VERSION_NO` decodes as major.minor(8 bits).patch.port(8 bits).build from server field version 18.1 ext1 on.
- **Logoff:** function 9, its STATUS, then a DATA packet with the EOF flag.
- **Types at field version 13:** BOOLEAN (23ai) columns and `TRUE` arrive as NUMBER 1/0 (real BOOLEAN needs field version ≥ 23.1). LONG and LONG RAW values are a chunked CLR followed by an sb4 indicator and a ub4 return code; their describe buffer size is 0. UROWID is a ub4 length plus a CLR; a logical one prints as `*` + base64 (no padding) of the bytes after the first. TIMESTAMP values with no fraction come as 7 bytes. TIMESTAMP WITH TIME ZONE carries UTC plus an offset (hours + 20, minutes + 60) or a region ID (`(b11 & 0x7F) << 6 | b12 >> 2`); region IDs are the same across time zone file versions (18c's 595 are a subset of 26ai's 600, same IDs). **WITH LOCAL TIME ZONE values come in the database time zone (`DBTIMEZONE`)**, not the session's: the client reads DBTIMEZONE once, when a result first has such a column, and converts. Intervals: years/days + 2³¹, the other parts + 60, nanoseconds + 2³¹.
- **Binds** (checked against python-oracledb's bytes for the same calls): EXECUTE gets the BIND option and the bind count; after al8i4 come per bind its metadata (type, flags 01, precision/scale 0, ub4 buffer size, then zeros except charset 873 and form 1 for text; oaccolid from 12.2) and per execution a ROW_DATA with the values (CLRs). **No ROW_DATA without values to send** (no binds, or only RETURNING targets): an empty one gives ORA-03146. Python sizes VARCHAR2 binds at 4 × the UTF-8 length.
- **Re-execution** of a cached cursor: REEXECUTE (4: cursor, executions, options 0, commit 0/1) or REEXECUTE_AND_FETCH (78: cursor, prefetch rows, options 0x20, 0), then only the values. A re-executed query gets no describe information (the cache keeps the columns). ORA-01007/00932 on a cached query: its tables changed, parse again.
- **PL/SQL binds:** option PLSQL_BIND (0x400) instead of NOT_PLSQL; the response starts with an IO_VECTOR (a direction per bind: 0x10 OUT, 0x20 IN, 0x30 IN OUT), then a ROW_DATA with the OUT and IN OUT values only, each followed by an sb4. **RETURNING INTO:** no IO_VECTOR; the targets (placeholders after `RETURNING ... INTO`) get no value sent; the ROW_DATA has, per target, a ub4 row count and that many values (each with an sb4).
- **Array DML:** executions in al8i4[1], one ROW_DATA per row; DML row counts (option field `1, n, 1` and flag 0x4000) come after the return parameters (ub4 count, ub8 each). With BATCH_ERRORS (0x80000) the server sends a BREAK and a RESET marker before the ERROR (ORA-24381), which lists codes, row offsets and messages; the arrays' end byte is only there when their first byte is 254. A cached cursor runs again with an EXECUTE without PARSE (cursor ID, no SQL).
- **Child cursors:** IMPLICIT_RESULTSET (ub4 count; per result a length-prefixed skip, describe information without its leading CLR, ub2 cursor ID) and REF cursor values (a byte, the same describe, ub2 cursor ID). Their first fetch is an EXECUTE with options FETCH | NOT_PLSQL and the cursor ID (al8i4[1] = rows), then FETCH.
- **Cancel:** the server here doesn't accept out-of-band breaks, so cancel is an in-band INTERRUPT marker. Every INTERRUPT, busy or idle, gets one RESET marker (the client answers RESET) and an ORA-01013 ERROR, possibly after the interrupted call's own response; when the RESET marker comes first the client must not wait for another one. The server checks for interrupts while it works (a busy query stops within a second) but not during `DBMS_SESSION.SLEEP` (python-oracledb waits the same).
- **LOBs** (checked against python-oracledb's bytes): a query with LOB columns returns no rows from its execution; the client sends an EXECUTE with only DEFINE (no EXECUTE option; al8i4[1] = rows to fetch) and a define per column (bind-like metadata), and the rows come with that response. Defining CLOB/NCLOB as LONG and BLOB as LONG RAW (buffer 0x7FFFFFFF, charset 873 with the column's form) brings the contents inline in the LONG format; as CLOB/BLOB (buffer 112, continuation flag 0x2000000) brings locators: ub4 length, ub8 size, ub4 chunk size, CLR locator (BFILE: ub4 length, CLR locator). A cursor keeps its defines when re-executed.
- **LOB_OP (96):** source locator and its length, operation, 1-based offsets, an optional amount; data comes in LOB_DATA (14) messages; the PARAMETER answer is the locator, then echoes of what was sent: the character set (CREATE_TEMP), the amount, the NULL-LOB flag byte (CREATE_TEMP, is-open/exists). CREATE_TEMP puts the charset form in the source offset, the LOB type in the destination offset, the duration (10, session) in the destination length, and sends a 40-byte zero locator. BFILE reads are wrapped in FILE_ISOPEN / FILE_OPEN (amount 11, read-only) / FILE_CLOSE. CLOB data in a variable-width database character set is UTF-16 (locator byte 6 has 0x80; little-endian if byte 7 has 0x40); amounts, offsets and `LENGTH` count UTF-16 units.
- **Long binds:** strings and bytes over 32767 bytes bind as VARCHAR2/RAW with a large buffer (4 × the UTF-8 length) and a chunked CLR; within a row such values must come **after all the other values**, else the server applies them to the wrong position (ORA-01461 on the next bind). `CAST(NULL AS BFILE)` is refused in SQL (ORA-22849).
- **Server text:** `TO_CHAR` prints region names upper case and NUMBER as `.5`; oracle-native keeps IANA case and `0.5` (the rest of the date, timestamp and interval texts match the server). `INTERVAL YEAR(9)` values exceed `MonthInterval`.
- **TLS tests** use a socat proxy (`integration-tests/tls/start-proxy.sh`) in front of the plain listener: TCPS is TLS from the first byte with the same TNS traffic inside. Server-side TCPS features (RESEND with renegotiation, client certificates checked by the server) are not covered by it.
- **Debugging:** set `ConnectionOptions.transportFactory` to wrap the transport in a logging one to see the bytes.

## Conventions

- `@safe` by default; small commented `@trusted` blocks only in I/O and reinterpret-cast hot paths.
- **Every public symbol gets a Ddoc comment**; documented unittests as usage examples.
- Every type gets golden-byte unit tests and server round trips in both I/O modes; cover NULLs, extremes, non-ASCII text, national character sets, time zones (offsets and regions), nanoseconds.
