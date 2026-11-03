# Contributing to oracle-native

Thank you for your interest in contributing.

## Workflow

Every change goes through an issue and a pull request; nothing is pushed to
`main` directly. Open an issue first (or pick one from the
[roadmap](https://github.com/buggins/oracle-native/issues/10)), work on a feature
branch, and mention `Closes #N` in the pull request.

## Development setup

- A D compiler with frontend **2.097 or newer**: DMD 2.097+ or LDC 1.27+.
- [dub](https://code.dlang.org).
- For integration tests: an Oracle Database in Docker, e.g. Oracle Database Free 23ai:

  ```sh
  docker run -d --name oracle-free -p 1521:1521 -e ORACLE_PASSWORD=Oracle_test123 \
      -e APP_USER=testuser -e APP_USER_PASSWORD=Test_password123 gvenzl/oracle-free:23
  ```

  The pluggable database's service is `FREEPDB1`. For 21c and 18c XE use
  `gvenzl/oracle-xe:21` or `:18` (service `XEPDB1`). The first start takes a
  few minutes (the `-faststart` tags start faster); the containers need about
  2 GB of memory.

## Building and testing

```sh
dub build       # library (thread mode, no C dependencies)
dub test        # unit tests, no server needed
```

## Code style and checks

CI runs these checks, so run them before sending a pull request:

```sh
dub run dscanner@0.15.2 -- --styleCheck .                   # static analysis
dub run dfmt@0.15.2 -- --inplace $(git ls-files '*.d')      # formatting
dub build -b docs                                           # documentation builds
```

- Formatting follows `dfmt`, configured in `.editorconfig`: Allman braces, 4-space indentation.
- **Document every public symbol with a Ddoc comment.** D-Scanner reports undocumented public declarations.
- **Add unit tests next to the code they test.** A unittest preceded by `///` becomes a usage example in the generated docs.
- Prefer `@safe`. Keep `@trusted` blocks small, with a comment explaining why each one is safe.
- Anything that can block goes through dbwire's I/O backends, never directly through `std.socket`, `core.sync` or vibe.d.
- vibe.d-specific code belongs under `version (Have_vibe_core)`. The default build must not depend on vibe-core.
- Don't use language or library features newer than frontend 2.097.

## Licensing of contributions

oracle-native is licensed under the [Boost Software License 1.0](LICENSE). By contributing, you agree that your contributions are licensed under the same terms.

- **Oracle has not published a specification of its network protocol.** The implementation is written from facts: packet layouts, constants and algorithm steps, as servers show them and as open-source clients document them.
- **Other clients are reference only**: reading Oracle's python-oracledb and node-oracledb thin modes (UPL-1.0 or Apache-2.0) or go-ora (MIT) to understand the protocol is fine; copying or translating their code is not, and line-by-line translation counts as copying. Reproducing wire-format facts is fine.
- Test data (golden bytes) comes from real servers, not from other clients' test suites. Data tables (e.g. time zone region IDs) are generated from the server.
- Third-party code or data needs the maintainer's agreement before it is added.
