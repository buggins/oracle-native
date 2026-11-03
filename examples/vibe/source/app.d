/++
oracle-native in a vibe.d application: tasks share a connection pool, and
waiting for the server suspends only the waiting task, not the thread.

Run with `dub run :example-vibe`. The connection comes from
`ORACLE_CONNECTION`, `ORACLE_USER` and `ORACLE_PASSWORD` (see the basic example).
+/
module app;

import std.datetime.stopwatch : AutoStart, StopWatch;
import std.process : environment;
import std.stdio : writefln;

import vibe.core.core : exitEventLoop, runEventLoop, runTask;
import vibe.core.task : Task;

import oracle;

void main()
{
    // Inside vibe.d tasks the pool's connections use vibe-core sockets automatically
    auto options = ConnectionOptions.parse(environment.get("ORACLE_CONNECTION", "localhost:1521/FREEPDB1"));
    if (auto user = environment.get("ORACLE_USER"))
        options.user = user;
    if (auto password = environment.get("ORACLE_PASSWORD"))
        options.password = password;
    auto pool = new ConnectionPool(options, PoolOptions(4));

    // Runs one call on a pooled connection
    void query(int n) nothrow
    {
        try
        {
            auto conn = pool.lockConnection();
            conn.exec("BEGIN DBMS_SESSION.SLEEP(0.5); END;");
            const value = conn.queryValue!int("SELECT :1 * 10 FROM dual", n);
            print("task %s: got %s", n, value);
        }
        catch (Exception e)
            print("task %s failed: %s", n, e.msg);
    }

    void work() nothrow
    {
        scope (exit)
            exitEventLoop();
        try
        {
            auto sw = StopWatch(AutoStart.yes);
            Task[] tasks;
            foreach (i; 0 .. 8)
                tasks ~= runTask(&query, i);
            foreach (t; tasks)
                t.join();
            // 8 half-second calls on 4 pooled connections: about one second in total
            print("8 calls in %s", sw.peek);
            pool.close();
        }
        catch (Exception e)
            print("error: %s", e.msg);
    }

    runTask(&work);
    runEventLoop();
}

/// `writefln` that never throws, for use in tasks.
void print(Args...)(string format, Args args) nothrow
{
    try
        writefln(format, args);
    catch (Exception)
    {
    }
}
