/// Fiber-mode tests that need vibe-core: waiting for the server doesn't block the event loop.
module vibetests;

import core.time : MonoTime, msecs;
import std.exception : enforce;

import vibe.core.core : runTask;

import oracle;
import integrationtests.harness : TestCase;
import integrationtests.server : connectToServer, scalar;

/// Tests registered by the vibe.d runner.
immutable TestCase[] vibeTests = [
    TestCase("fiber: statements run concurrently", &testConcurrentStatements, true),
];

/// Four tasks, each with its own connection, sleep one second on the server: about a second in all.
void testConcurrentStatements()
{
    string[4] results;
    void work(size_t i) nothrow
    {
        try
        {
            auto conn = connectToServer();
            scope (exit)
                conn.close();
            enforce(conn.ioBackend == "vibe", "vibe backend");
            conn.exec("BEGIN DBMS_SESSION.SLEEP(1); END;");
            results[i] = scalar(conn, "SELECT 'ok' FROM dual");
        }
        catch (Exception e)
            results[i] = e.msg;
    }

    const start = MonoTime.currTime;
    typeof(runTask(&work, cast(size_t) 0))[] tasks;
    foreach (i; 0 .. 4)
        tasks ~= runTask(&work, cast(size_t) i);
    foreach (t; tasks)
        t.join();
    const elapsed = MonoTime.currTime - start;
    foreach (r; results)
        enforce(r == "ok", "a task failed: " ~ r);
    enforce(elapsed < 3500.msecs, "the statements didn't run concurrently");
}
