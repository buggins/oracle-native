/// Thread-mode tests: connections used by several threads at once.
module threadtests;

import core.thread : Thread;
import std.exception : enforce;

import oracle;
import integrationtests.harness : TestCase;
import integrationtests.server : connectToServer, scalar;
import oracle : ServerException;

/// Tests registered by the thread runner.
immutable TestCase[] threadTests = [
    TestCase("thread: one connection per thread", &testThreads, true),
    TestCase("thread: cancel from another thread", &testCancelFromThread, true),
];

/++
`Connection.cancel` from another thread stops a call; the connection stays
usable; racing cancels are harmless. (The server checks for cancels while it
works, not during `DBMS_SESSION.SLEEP`: a busy query is cancelled.)
+/
void testCancelFromThread()
{
    import core.time : MonoTime, msecs, seconds;
    import std.exception : collectException;

    auto conn = connectToServer();
    scope (exit)
        conn.close();
    conn.cancel(); // idle: nothing happens
    enforce(scalar(conn, "SELECT 'idle' FROM dual") == "idle", "cancel when idle");

    auto canceller = new Thread({ Thread.sleep(500.msecs); conn.cancel(); });
    canceller.start();
    const start = MonoTime.currTime;
    enum busyQuery = "SELECT COUNT(*) FROM all_objects a, all_objects b WHERE ROWNUM < 100000000";
    auto e = collectException!ServerException(scalar(conn, busyQuery));
    canceller.join();
    enforce(e !is null && e.code == 1013, e is null ? "not cancelled" : e.msg);
    enforce(MonoTime.currTime - start < 5.seconds, "the cancel didn't stop the call");
    enforce(scalar(conn, "SELECT 'after' FROM dual") == "after", "usable after the cancel");

    // cancels racing with short calls: each call gets its own answer
    foreach (i; 0 .. 20)
    {
        auto racer = new Thread({ conn.cancel(); });
        racer.start();
        try
            conn.exec("BEGIN NULL; END;");
        catch (ServerException x)
            enforce(x.code == 1013, x.msg);
        racer.join();
        enforce(scalar(conn, "SELECT 'ok' FROM dual") == "ok", "in step after a racing cancel");
    }
}

/// Four threads, each with its own connection, run queries at the same time.
void testThreads()
{
    import core.atomic : atomicOp;

    shared int done;
    shared int failed;
    Thread[] threads;
    foreach (i; 0 .. 4)
    {
        threads ~= new Thread({
            try
            {
                auto conn = connectToServer();
                scope (exit)
                    conn.close();
                foreach (k; 0 .. 20)
                    if (scalar(conn, "SELECT COUNT(*) FROM dual CONNECT BY LEVEL <= 100") != "100")
                        atomicOp!"+="(failed, 1);
                atomicOp!"+="(done, 1);
            }
            catch (Exception)
                atomicOp!"+="(failed, 1);
        });
        threads[$ - 1].start();
    }
    foreach (t; threads)
        t.join();
    enforce(done == 4 && failed == 0, "threads failed");
}
