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
```

Run lint and format before committing D code. dfmt 0.15.2 mangles lambdas with attributes (`() nothrow {` → `() nothrow{`): use named nested functions. It merges `@safe return` into `@safereturn`: avoid the `return` attribute. Run dfmt twice when it changes files. `dub.selections.json` files are git-ignored (a root one listing vibe-core would enable vibe support silently).

## Local environment

- WSL2 Linux. **LDC 1.36.0** (`ldc2`); DMD is not installed. Test the minimum frontend with LDC 1.27.1 (download `https://github.com/ldc-developers/ldc/releases/download/v1.27.1/ldc2-1.27.1-linux-x86_64.tar.xz` into the scratchpad, run dub with `--compiler=<path>/bin/ldc2`).
- Oracle in Docker: container `oracle-free` (`gvenzl/oracle-free:23`, 23ai Free) on port **11521**, service `FREEPDB1`; `SYSTEM` password `Oracle_test123`, application user `testuser` / `Test_password123`. `sqlplus` is inside the container: `docker exec -it oracle-free sqlplus testuser/Test_password123@FREEPDB1`. 21c/18c: `gvenzl/oracle-xe:21` / `:18` (service `XEPDB1`).

## Conventions

- `@safe` by default; small commented `@trusted` blocks only in I/O and reinterpret-cast hot paths.
- **Every public symbol gets a Ddoc comment**; documented unittests as usage examples.
- Every type gets golden-byte unit tests and server round trips in both I/O modes; cover NULLs, extremes, non-ASCII text, national character sets, time zones (offsets and regions), nanoseconds.
