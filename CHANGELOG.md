# Changelog

All notable changes to oracle-native are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[semantic versioning](https://semver.org/).

## Unreleased

### Added

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
