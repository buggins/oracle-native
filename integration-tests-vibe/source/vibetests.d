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
    TestCase("fiber: cancel from another task", &testCancelFromTask, true),
];

/// `Connection.cancel` from another task stops a call that waits on the server.
void testCancelFromTask()
{
    import core.time : seconds;
    import std.exception : collectException;
    import vibe.core.core : sleep;

    auto conn = connectToServer();
    scope (exit)
        conn.close();
    auto canceller = runTask({
        try
        {
            sleep(500.msecs);
            conn.cancel();
        }
        catch (Exception)
        {
        }
    });
    const start = MonoTime.currTime;
    enum busyQuery = "SELECT COUNT(*) FROM all_objects a, all_objects b WHERE ROWNUM < 100000000";
    auto e = collectException!ServerException(scalar(conn, busyQuery));
    canceller.join();
    enforce(e !is null && e.code == 1013, e is null ? "not cancelled" : e.msg);
    enforce(MonoTime.currTime - start < 5.seconds, "the cancel didn't stop the call");
    enforce(scalar(conn, "SELECT 'after' FROM dual") == "after", "usable after the cancel");
}

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
