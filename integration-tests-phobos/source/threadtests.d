/// Thread-mode tests: connections used by several threads at once.
module threadtests;

import core.thread : Thread;
import std.exception : enforce;

import oracle;
import integrationtests.harness : TestCase;
import integrationtests.server : connectToServer, scalar;

/// Tests registered by the thread runner.
immutable TestCase[] threadTests = [
    TestCase("thread: one connection per thread", &testThreads, true),
];

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
