/++
Integration test harness shared by the thread (Phobos) and fiber (vibe.d)
runners. Tests are written once here; each runner calls `runAllTests` in its
own I/O context. Tests that need a server run only when `ORACLE_HOST` is set.
+/
module integrationtests.harness;

import core.exception : AssertError;
import std.stdio : stderr, writefln;

import integrationtests.basic;
import integrationtests.binds;
import integrationtests.connect;
import integrationtests.server : serverConfigured;
import integrationtests.types;

/// Integration test entry point. Throws on failure.
alias TestFunction = void function();

/// A named integration test.
struct TestCase
{
    /// Test name used in reports.
    string name;
    /// Test body.
    TestFunction run;
    /// Whether the test needs a server.
    bool needsServer;
}

/// All integration tests, in execution order.
immutable TestCase[] allTests = [
    TestCase("connect, session information, ping", &testConnect, true),
    TestCase("URL, Easy Connect and descriptor strings", &testConnectionStrings, true),
    TestCase("failover to the next address", &testFailover, true),
    TestCase("failed login and unknown service", &testLoginErrors, true),
    TestCase("small SDU and long statements", &testSdu, true),
    TestCase("receive timeout closes the connection", &testReceiveTimeout, true),
    TestCase("TLS (TCPS)", &testTls, true),
    TestCase("NUMBER values", &testNumbers, true),
    TestCase("VARCHAR2, CHAR and Unicode text", &testStrings, true),
    TestCase("NULL values and ROWIDs", &testNullsAndRowids, true),
    TestCase("exec row counts, commit and rollback", &testTransactions, true),
    TestCase("auto-commit", &testAutoCommit, true),
    TestCase("server errors keep the connection", &testServerErrors, true),
    TestCase("fetching in batches, repeated column values", &testFetchBatches, true),
    TestCase("closed results and many cursors", &integrationtests.basic.testCursors, true),
    TestCase("busy and closed connections", &testBusy, true),
    TestCase("BINARY_FLOAT and BINARY_DOUBLE", &testFloats, true),
    TestCase("NUMBER as exact decimals, Variant types", &testDecimals, true),
    TestCase("DATE and TIMESTAMP", &testDatesAndTimestamps, true),
    TestCase("time zones: offsets, regions, local time zone", &testTimeZones, true),
    TestCase("INTERVAL YEAR TO MONTH and DAY TO SECOND", &testIntervals, true),
    TestCase("RAW, LONG, LONG RAW, ROWID, UROWID", &testBinaryLongAndRowids, true),
    TestCase("booleans", &testBooleans, true),
    TestCase("NULL through every getter", &testNullGetters, true),
    TestCase("binds of every D type, re-executed", &testBindTypes, true),
    TestCase("placeholders: named, ?, repeated, Variant", &testPlaceholders, true),
    TestCase("DML with binds", &testBindDml, true),
    TestCase("array DML, batch errors", &testArrayDml, true),
    TestCase("OUT, IN OUT and RETURNING INTO", &testOutputs, true),
    TestCase("implicit results and REF cursors", &integrationtests.binds.testCursors, true),
    TestCase("statement cache", &testStatementCache, true),
];

/// Runner identity, for reports.
struct RunnerContext
{
    /// Runner name used in reports, e.g. "phobos" or "vibe".
    string name;
}

/++
Runs all integration tests, plus `extraTests` from the runner, and prints a report.

Returns: the number of failed tests.
+/
int runAllTests(RunnerContext runner, const TestCase[] extraTests = null)
{
    const withServer = serverConfigured();
    if (!withServer)
        writefln("[%s] ORACLE_HOST is not set: skipping tests that need a server", runner.name);
    int failures, skipped;
    foreach (test; allTests ~ extraTests)
    {
        if (test.needsServer && !withServer)
        {
            skipped++;
            writefln("[%s] SKIP  %s", runner.name, test.name);
            continue;
        }
        try
        {
            test.run();
            writefln("[%s] PASS  %s", runner.name, test.name);
        }
        catch (AssertError e)
        {
            failures++;
            stderr.writefln("[%s] FAIL  %s: %s (%s:%s)", runner.name, test.name, e.msg, e.file, e.line);
        }
        catch (Exception e)
        {
            failures++;
            stderr.writefln("[%s] FAIL  %s: %s", runner.name, test.name, e.msg);
        }
    }
    writefln("[%s] %d test(s), %d failed, %d skipped", runner.name, allTests.length + extraTests.length, failures,
            skipped);
    return failures;
}
