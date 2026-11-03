/++
Connection pool for thread mode and fiber mode.

Example:
---
auto pool = new ConnectionPool("oracle://app:secret@db/FREEPDB1?pool_max=8");
// In any thread, or in any vibe.d task:
{
    auto conn = pool.lockConnection();       // waits if all 8 are in use
    conn.exec("INSERT INTO log VALUES (SYSTIMESTAMP, :1)", "x");
    conn.commit();
}                                            // returned to the pool here
---

In thread mode all threads share one set of connections. In fiber mode each
thread has its own set, because a vibe.d connection cannot move between event
loops; the limits apply per thread. Which mode a call uses follows
`ConnectionOptions.ioMode`, as for single connections.

A connection handed out again has the previous user's open transaction rolled
back first (uncommitted changes are not carried over). Other session state
stays: `ALTER SESSION` settings, package variables, the statement cache (which
saves parsing). Idle connections are checked lazily, when connections are
taken or returned, so the pool needs no background thread or timer.

With DRCP (`ConnectionOptions.serverType` `pooled`) a returned connection
also hands its session back to the database's pool (`Connection.releaseSession`),
so many client connections can share few server sessions. The pool's
connections share one connection class (`ConnectionOptions.connectionClass`,
generated when not set) and purity `self` by default: a connection may get a
session with the state an earlier user of the class left (its statement cache
stays valid when it gets the same session back).

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module oracle.pool;

import dbwire.client.pool : PoolCore, PoolLease, Poolable;
import oracle.connection : Connection;
import oracle.settings : ConnectionOptions;

/// Pool limits and connection reuse rules; from `dbwire.client.pool` (package dbwire), re-exported here.
public import dbwire.client.pool : PoolOptions;

/++
A pool of connections to one database (or one set of failover addresses).

`lockConnection` hands out a `PooledConnection`, which returns the connection
when it goes out of scope. Connections that are closed, broken, or still busy
with an unread result when returned are not reused.

The pool logic is `dbwire.client.pool.PoolCore`; this class opens
`Connection`s for it.
+/
final class ConnectionPool
{
    private PoolCore core;

    /++
    Creates an empty pool; connections are opened on demand.

    Params:
        connectionOptions = options for every connection of the pool.
        poolOptions = pool limits.
    Throws: `ClientException` if `poolOptions.maxConnections` is 0.
    +/
    this(ConnectionOptions connectionOptions, PoolOptions poolOptions = PoolOptions.init) @safe
    {
        import oracle.settings : Purity;

        if (connectionOptions.usesDrcp)
        {
            if (connectionOptions.connectionClass.length == 0)
                connectionOptions.connectionClass = newConnectionClass();
            if (connectionOptions.purity == Purity.default_)
                connectionOptions.purity = Purity.self;
        }

        Poolable open() @safe
        {
            return new Connection(connectionOptions);
        }

        core = new PoolCore(poolOptions, connectionOptions.ioMode, &open);
    }

    /++
    Creates a pool from a connection string with its `pool_*` parameters
    (`pool_max`, `pool_min`, `pool_wait`, ...; see `PoolOptions.fromParams`)
    in a URL or Easy Connect string; see `ConnectionOptions.parse`.
    +/
    this(string connectionString) @safe
    {
        this(ConnectionOptions.parse(connectionString), poolOptionsOf(connectionString));
    }

    /++
    Takes a connection from the pool, opening a new one if none is idle and
    the limit allows it; otherwise waits up to `PoolOptions.waitTimeout`.

    Throws: `ClientException` if the pool is closed or no connection became
    free in time; connection errors when a new connection cannot be opened.
    +/
    PooledConnection lockConnection() @safe
    {
        return PooledConnection(core.acquire());
    }

    /// Number of idle connections available to the caller (its thread's set in fiber mode).
    @property size_t idleConnections() @safe
    {
        return core.idleConnections;
    }

    /// Number of connections handed out to the caller's context and not yet returned.
    @property size_t activeConnections() @safe
    {
        return core.activeConnections;
    }

    /++
    Closes all idle connections and stops handing out new ones. Connections in
    use are closed when they are returned. In fiber mode, the idle connections
    of other threads are closed by those threads when they next use the pool.
    +/
    void close() @safe
    {
        core.close();
    }
}

/++
A connection taken from a `ConnectionPool`. It behaves like the `Connection`
itself and returns it to the pool when it goes out of scope (or on `release`).
It cannot be copied.
+/
struct PooledConnection
{
    private PoolLease lease;
    private Connection conn;

    @disable this(this);

    ~this() @safe
    {
        release();
    }

    private this(PoolLease lease) @trusted
    {
        import std.algorithm.mutation : move;

        // the pool's factory only creates Connections
        conn = cast(Connection) lease.connection();
        this.lease = move(lease);
        if (conn.inTransaction)
            conn.rollback(); // the previous user's uncommitted changes
    }

    /// The pooled connection. Null after `release`.
    @property Connection connection() @safe pure nothrow
    {
        return conn;
    }

    ///
    alias connection this;

    /++
    Returns the connection to the pool now (DRCP: after releasing its
    session; a connection whose release fails is closed). Calling it again
    does nothing.
    +/
    void release() @safe
    {
        if (conn !is null && conn.isOpen && !conn.isBusy)
        {
            try
                conn.releaseSession();
            catch (Exception)
                conn.close();
        }
        conn = null;
        lease.release();
    }
}

/// A connection class for the DRCP sessions of one pool: `ONA:` and 16 random bytes in base64.
private string newConnectionClass() @safe
{
    import std.base64 : Base64;
    import std.random : uniform;

    ubyte[16] bytes;
    foreach (ref b; bytes)
        b = cast(ubyte) uniform(0, 256);
    return "ONA:" ~ Base64.encode(bytes[]).idup;
}

/// The pool options of a connection string: its `pool_*` parameters (URL or Easy Connect).
private PoolOptions poolOptionsOf(string connectionString) @safe
{
    import std.algorithm.searching : findSplit, startsWith;
    import std.string : strip;
    import dbwire.client.dsn : parseQuery;

    const s = connectionString.strip;
    if (s.startsWith("oracle://"))
        return PoolOptions.fromDsn(s);
    if (s.startsWith("("))
        return PoolOptions.init; // descriptors have no pool parameters
    string[string] params;
    if (auto q = s.findSplit("?"))
        params = parseQuery(q[2], "Easy Connect");
    return PoolOptions.fromParams(params);
}
