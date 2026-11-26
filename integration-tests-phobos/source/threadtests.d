/// Thread-mode tests: connections used by several threads at once.
module threadtests;

import core.thread : Thread;
import std.exception : enforce;

import oracle;
import integrationtests.harness : TestCase;
import integrationtests.server : connectToServer, scalar;
import oracle : ConnectionPool, PoolOptions, ServerException;

/// Tests registered by the thread runner.
immutable TestCase[] threadTests = [
    TestCase("thread: one connection per thread", &testThreads, true),
    TestCase("thread: cancel from another thread", &testCancelFromThread, true),
    TestCase("thread: a cancel during a lock wait doesn't hide the result", &testCancelLockWait, true),
    TestCase("thread: a pool shared by threads", &testPoolThreads, true),
];

/// Eight threads share a pool of three connections; each waits for a free one.
void testPoolThreads()
{
    import core.atomic : atomicOp;
    import integrationtests.server : serverOptions;

    auto pool = new ConnectionPool(serverOptions(), PoolOptions(3));
    scope (exit)
        pool.close();
    shared int done;
    shared int failed;
    Thread[] threads;
    foreach (i; 0 .. 8)
    {
        threads ~= new Thread({
            try
            {
                foreach (k; 0 .. 5)
                {
                    auto conn = pool.lockConnection();
                    if (conn.queryValue!int("SELECT :1 + :2 FROM dual", k, 1) != k + 1)
                        atomicOp!"+="(failed, 1);
                }
                atomicOp!"+="(done, 1);
            }
            catch (Exception)
                atomicOp!"+="(failed, 1);
        });
        threads[$ - 1].start();
    }
    foreach (t; threads)
        t.join();
    enforce(done == 8 && failed == 0, "threads failed");
    enforce(pool.idleConnections <= 3 && pool.activeConnections == 0, "at most three connections");
}

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

/++
A cancel during a row-lock wait. Oracle 21c and 23ai can't interrupt the
wait (19c not checked): the lock holder commits, and the UPDATE runs. Its row count comes back,
and the ORA-01013 that follows is dropped (#76). Oracle 18c interrupts the
wait: ORA-01013, and the UPDATE didn't run. Either way the result matches the
table.
+/
void testCancelLockWait()
{
    import core.time : msecs;
    import std.exception : collectException;
    import integrationtests.server : dropTable;

    auto conn = connectToServer();
    scope (exit)
        conn.close();
    dropTable(conn, "itest_cancel_lock");
    conn.exec("CREATE TABLE itest_cancel_lock (id NUMBER)");
    scope (exit)
        dropTable(conn, "itest_cancel_lock");
    conn.exec("INSERT INTO itest_cancel_lock VALUES (1)");
    conn.commit();
    auto holder = connectToServer();
    scope (exit)
        holder.close();
    holder.exec("UPDATE itest_cancel_lock SET id = 2");
    auto helper = new Thread({
        Thread.sleep(500.msecs);
        conn.cancel(); // the UPDATE waits for the lock
        Thread.sleep(1000.msecs);
        holder.commit(); // the lock goes: the UPDATE runs
    });
    helper.start();
    ulong rows;
    auto e = collectException!ServerException(rows = conn.exec("UPDATE itest_cancel_lock SET id = 3"));
    helper.join();
    if (e is null)
    {
        enforce(rows == 1, "row count lost");
        conn.commit();
        enforce(scalar(conn, "SELECT id FROM itest_cancel_lock") == "3", "the UPDATE didn't run");
    }
    else
    {
        enforce(e.code == 1013, "the UPDATE failed: " ~ e.msg);
        // tells an interrupted wait from an UPDATE that ran and then got the cancel's late ORA-01013
        enforce(scalar(conn, "SELECT id FROM itest_cancel_lock") == "2", "the UPDATE ran, yet: " ~ e.msg);
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
