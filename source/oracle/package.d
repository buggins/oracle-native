/++
Native Oracle Database client library for D.

oracle-native talks to Oracle Database over the Oracle Net (TNS) and TTC
protocols and works both with blocking Phobos sockets (ordinary threads) and
with vibe-core sockets (vibe.d fibers), through [dbwire](https://github.com/buggins/dbwire).

This is an unofficial project, not affiliated with Oracle.

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
Authors:   Vadim Lopatin
+/
module oracle;

public import oracle.connection : Connection;
public import oracle.exception;
public import oracle.lob : Lob;
public import oracle.mapping : RowRange, column, ignore, readValue;
public import oracle.params : BindDirection, Parameter;
public import oracle.pipeline : Pipeline, PipelineResult;
public import oracle.pool : ConnectionPool, PoolOptions, PooledConnection;
public import oracle.result : BatchError, BatchResult, Output, QueryResult, Row;
public import oracle.settings : ConnectionOptions, HostPort, HostSelection, Purity;
public import oracle.types.typeinfo : CharsetForm, ColumnInfo, OracleType;
public import oracle.types.vector : Vector, VectorFormat;
public import oracle.value : Value;
public import dbwire.types.decimal : Decimal;
public import dbwire.types.interval : MonthInterval;
public import dbwire.io.backend : IoMode;

/// Library version.
enum uint oracleVersionMajor = 0;
/// ditto
enum uint oracleVersionMinor = 4;
/// ditto
enum uint oracleVersionPatch = 0;

/// Library version as a string, e.g. `"0.1.0"`.
enum string oracleVersion = versionString(oracleVersionMajor, oracleVersionMinor, oracleVersionPatch);

/// Driver name reported to the server at login.
enum string oracleClientName = "oracle-native";

version (Have_vibe_core)
    private enum bool hasVibeCore = true;
else
    private enum bool hasVibeCore = false;

/++
True when vibe-core support is compiled in.

dub defines `Have_vibe_core` when vibe-core is anywhere in the application's
dependency graph. oracle-native then supports fiber mode in addition to the
always-available thread mode.
+/
enum bool oracleHasVibe = hasVibeCore;

private string versionString(uint major, uint minor, uint patch) pure @safe
{
    import std.conv : to;

    return major.to!string ~ "." ~ minor.to!string ~ "." ~ patch.to!string;
}

///
@safe unittest
{
    import std.algorithm.searching : count;

    assert(oracleVersion.count('.') == 2 && oracleClientName == "oracle-native");
}
