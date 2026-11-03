/++
A connection to Oracle Database: connecting (the listener handshake, TLS,
the TTC negotiation, O5LOGON), statements and their responses.

Example:
---
auto conn = new Connection("oracle://scott:tiger@localhost:1521/FREEPDB1");
scope (exit)
    conn.close();
conn.exec("CREATE TABLE t (id NUMBER, name VARCHAR2(50))");
conn.exec("INSERT INTO t VALUES (1, 'one')");
conn.commit();
foreach (row; conn.query("SELECT id, name FROM t ORDER BY id"))
    writeln(row.getLong(0), " ", row.getString(1));
---

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module oracle.connection;

import dbwire.client.hosts : connectFirst, orderHosts;
import dbwire.client.pool : Poolable;
import dbwire.io.backend : IoBackend, backendFor;
import dbwire.io.buffer : BufferedReader;
import dbwire.io.transport : Transport;
import dbwire.tls.transport : TlsContext, TlsTransport;
import oracle.exception;
import oracle.protocol.auth;
import oracle.protocol.execute;
import oracle.protocol.messages;
import oracle.protocol.negotiate;
import oracle.protocol.tns;
import oracle.protocol.ttc : TtcReader, TtcWriter;
import oracle.lob : Lob, LobOperation, LobRequest, LobResponse, buildLobOperation;
import oracle.mapping : RowRange, columnNames, fieldParameters, fieldPositions, quoteIdentifier, readStruct, readValue;
import oracle.result : BatchResult, QueryResult;
import oracle.settings : ConnectionOptions, HostPort;
import oracle.params : BindDirection, Parameter, Placeholders, findPlaceholders, maxBindBytes, parameters,
    rewritePlaceholders;
import oracle.statement : StatementKind, classify;
import std.range.primitives : ElementType, isInputRange;
import dbwire.io.backend : IoLock;
import oracle.types.typeinfo : CharsetForm, ColumnInfo, OracleType;
import std.datetime.timezone : TimeZone;
import std.datetime.timezone : UTC;
import std.typecons : Rebindable;

/++
One connection to Oracle Database.

One call at a time: a `QueryResult` keeps the connection busy until all its
rows are read or it is closed. The connection is not thread-safe. Call
`close` when done; the garbage collector does not close it.

Transactions are explicit: changes are committed by `commit` (or by DDL
statements), unless `ConnectionOptions.autoCommit` is set.
+/
final class Connection : Poolable
{
    package enum State
    {
        closed,
        ready,
        busy,
    }

    package State state = State.closed;
    package ConnectionOptions options;
    private IoBackend backend;
    private Transport transport;
    private TnsStream tns;
    private TtcReader reader;
    private ubyte lastSequence;
    private ubyte negotiatedFieldVersion;
    private ubyte serverFieldVersion;
    private ServerInfo serverInfo;
    private HostPort connectedHost;
    private KeyValue[] sessionValues;
    private uint[] cursorsToClose; // closed with the next call
    private EndToEnd endToEnd; // end-to-end attributes, changes sent with the next call
    private CachedStatement[string] statements; // the statement cache, by SQL text
    private ulong useCounter; // for the least recently used statement
    private IoLock writeLock; // writes from cancel() and the calls
    private shared bool cancelPending; // an INTERRUPT was sent and its ORA-01013 not yet read
    private uint lastCallStatus;
    package Rebindable!(immutable TimeZone) sessionZone; // the session time zone, for WITH LOCAL TIME ZONE values
    package Rebindable!(immutable TimeZone) databaseZone; // DBTIMEZONE: WITH LOCAL TIME ZONE values come in it
    private bool databaseZoneKnown;

    /++
    Connects and logs in.

    Throws: `ConnectionException` if no listener can be reached, all refuse the
    connection or TLS fails; `ServerException` if the server rejects the login
    (e.g. ORA-01017); `ClientException` for invalid options.
    +/
    this(ConnectionOptions options) @safe
    {
        this.options = options;
        connect();
    }

    /++
    Connects with a connection string: a URL (`oracle://...`), Easy Connect
    (`host:port/service`) or a connect descriptor (`(DESCRIPTION=...)`); see
    `ConnectionOptions.parse`.
    +/
    this(string connectString) @safe
    {
        this(ConnectionOptions.parse(connectString));
    }

    /// Connects with a connection string and credentials.
    this(string connectString, string user, string password) @safe
    {
        auto o = ConnectionOptions.parse(connectString);
        o.user = user;
        o.password = password;
        this(o);
    }

    /// Whether the connection is open (it may be busy).
    @property bool isOpen() const @safe pure nothrow
    {
        return state != State.closed;
    }

    /// Whether a query result is still open.
    @property bool isBusy() const @safe pure nothrow
    {
        return state == State.busy;
    }

    /// The I/O backend in use: `"phobos"` (threads) or `"vibe"` (fibers).
    @property string ioBackend() const @safe pure nothrow
    {
        return backend is null ? null : backend.name;
    }

    /// The listener the connection went to.
    @property HostPort host() const @safe pure nothrow
    {
        return connectedHost;
    }

    /// The server version, e.g. `"23.26.3.0.0"`.
    @property string serverVersion() const @safe pure
    {
        import std.conv : ConvException, to;
        import std.format : format;

        uint v;
        try
            v = sessionValue("AUTH_VERSION_NO").to!uint;
        catch (ConvException)
            return null;
        if (serverFieldVersion >= TtcFieldVersion.v18_1_ext1)
            return format("%d.%d.%d.%d.%d", v >> 24, (v >> 16) & 0xFF, (v >> 12) & 0x0F, (v >> 4) & 0xFF, v & 0x0F);
        return format("%d.%d.%d.%d.%d", v >> 24, (v >> 20) & 0x0F, (v >> 12) & 0xFF, (v >> 8) & 0x0F, v & 0x0F);
    }

    /// The session's ID and serial number (`V$SESSION.SID`, `SERIAL#`).
    @property uint sessionId() const @safe pure
    {
        return sessionNumber("AUTH_SESSION_ID");
    }

    /// ditto
    @property uint serialNumber() const @safe pure
    {
        return sessionNumber("AUTH_SERIAL_NUM");
    }

    /// The service and instance the session runs on, and the database (PDB) name.
    @property string serviceName() const @safe pure nothrow
    {
        return sessionValue("AUTH_SC_SERVICE_NAME");
    }

    /// ditto
    @property string instanceName() const @safe pure nothrow
    {
        return sessionValue("AUTH_INSTANCENAME");
    }

    /// ditto
    @property string databaseName() const @safe pure nothrow
    {
        return sessionValue("AUTH_DBNAME");
    }

    /// The longest identifier the server accepts (30 before 12.2, 128 since).
    @property uint maxIdentifierLength() const @safe pure
    {
        const n = sessionNumber("AUTH_MAX_IDEN_LENGTH");
        return n ? n : 30;
    }

    /// The TTC field version in use: the lower of the client's and the server's.
    @property ubyte fieldVersion() const @safe pure nothrow
    {
        return negotiatedFieldVersion;
    }

    /// Whether the session has uncommitted changes (as of the last call).
    @property bool inTransaction() const @safe pure nothrow
    {
        return (lastCallStatus & 0x02) != 0;
    }

    /++
    End-to-end attributes of the session, shown in `V$SESSION` and by
    `SYS_CONTEXT('USERENV', ...)` for monitoring and tracing: the client
    identifier (`CLIENT_IDENTIFIER`), module (`MODULE`), action (`ACTION`),
    client information (`CLIENT_INFO`) and database operation (`DBOP`). A
    change is sent with the next call (no round trip of its own); null or
    empty clears the attribute.
    +/
    @property string clientIdentifier() const @safe pure nothrow
    {
        return endToEnd.values[EndToEndAttribute.clientIdentifier];
    }

    /// ditto
    @property void clientIdentifier(string value) @safe pure nothrow
    {
        setEndToEnd(EndToEndAttribute.clientIdentifier, value);
    }

    /// ditto
    @property string moduleName() const @safe pure nothrow
    {
        return endToEnd.values[EndToEndAttribute.module_];
    }

    /// ditto
    @property void moduleName(string value) @safe pure nothrow
    {
        setEndToEnd(EndToEndAttribute.module_, value);
    }

    /// ditto
    @property string action() const @safe pure nothrow
    {
        return endToEnd.values[EndToEndAttribute.action];
    }

    /// ditto
    @property void action(string value) @safe pure nothrow
    {
        setEndToEnd(EndToEndAttribute.action, value);
    }

    /// ditto
    @property string clientInfo() const @safe pure nothrow
    {
        return endToEnd.values[EndToEndAttribute.clientInfo];
    }

    /// ditto
    @property void clientInfo(string value) @safe pure nothrow
    {
        setEndToEnd(EndToEndAttribute.clientInfo, value);
    }

    /// ditto
    @property string dbOp() const @safe pure nothrow
    {
        return endToEnd.values[EndToEndAttribute.dbOp];
    }

    /// ditto
    @property void dbOp(string value) @safe pure nothrow
    {
        setEndToEnd(EndToEndAttribute.dbOp, value);
    }

    private void setEndToEnd(EndToEndAttribute a, string value) @safe pure nothrow
    {
        endToEnd.values[a] = value.length ? value : null;
        endToEnd.changed |= 1 << a;
    }

    /++
    Runs a statement that returns no rows (DML, DDL, a PL/SQL block) and
    returns the number of rows it changed. Arguments are bound to the
    statement's placeholders (`:1`, `:name`, or `?`), in order, or by name for
    `Parameter.named` ones; see `oracle.params` for the types.

    Throws: `ServerException` if the statement fails (the connection stays
    usable); `ClientException` if the arguments don't match the placeholders.
    +/
    ulong exec(string sql) @safe
    {
        return run(sql, null).rowCount;
    }

    /// ditto
    ulong exec(Args...)(string sql, Args args) if (Args.length > 0)
    {
        return run(sql, parameters(args)).rowCount;
    }

    /++
    Runs a statement and returns its result: the rows of a query (the
    connection stays busy until all rows are read or the result is closed),
    or for other statements their row count, the values of OUT and
    `RETURNING ... INTO` parameters (`QueryResult.outputs`) and the implicit
    results of PL/SQL. Arguments are bound as in `exec`.

    Throws: `ServerException` if the statement fails (the connection stays
    usable); `ClientException` if the arguments don't match the placeholders.
    +/
    QueryResult query(string sql) @safe
    {
        return run(sql, null);
    }

    /// ditto
    QueryResult query(Args...)(string sql, Args args) if (Args.length > 0)
    {
        return run(sql, parameters(args));
    }

    /++
    Runs a query (with arguments as in `exec`, if any) and returns its rows as
    structs of type `T` (see `oracle.mapping`): an input range that holds the
    connection until all rows are read or it is closed.

    Throws: `ClientException` if a field has no column; as `query`.
    +/
    RowRange!T query(T, Args...)(string sql, Args args) if (is(T == struct))
    {
        return RowRange!T(runArgs(sql, args));
    }

    /++
    The first row of a query as a `T` (see `query!T`); the other rows are discarded.

    Throws: `ClientException` if there is no row or a field has no column; as `query`.
    +/
    T queryRow(T, Args...)(string sql, Args args) if (is(T == struct))
    {
        auto result = runArgs(sql, args);
        scope (exit)
            result.close();
        const positions = fieldPositions!T(result);
        if (result.empty)
            throw new ClientException("The query returned no rows");
        return readStruct!T(result, positions);
    }

    /++
    The first column of the first row of a query, as a `T` (any field type of
    `oracle.mapping`; `Nullable!T` to tell NULL apart), e.g.
    `queryValue!long("SELECT COUNT(*) FROM t")`.

    Throws: `ClientException` if there is no row, or the value can't be converted; as `query`.
    +/
    T queryValue(T, Args...)(string sql, Args args)
    {
        auto result = runArgs(sql, args);
        scope (exit)
            result.close();
        if (result.empty || result.columns.length == 0)
            throw new ClientException("The query returned no value");
        return readValue!T(result.front[0]);
    }

    /++
    Inserts structs as rows of `table`: one column per mapped field (see
    `oracle.mapping`), with array DML, 1000 rows per round trip. The rows
    are part of the current transaction (commit them; with `autoCommit`, each
    round trip commits).

    `table` is used as given (e.g. `orders` or `sales.orders`).

    Returns: the number of rows inserted.
    Throws: `ServerException` if the server refuses a row (the rows of the
    round trips before are inserted); `ClientException` for a value that
    can't be sent.
    +/
    ulong insert(R)(string table, R rows) if (isInputRange!R && is(ElementType!R == struct))
    {
        import std.array : join;
        import std.conv : to;

        alias E = ElementType!R;
        enum columns = columnNames!E;
        static assert(columns.length > 0, E.stringof ~ " has no mapped fields");
        string[] quoted, placeholders;
        foreach (i, c; columns)
        {
            quoted ~= quoteIdentifier(c);
            placeholders ~= ":" ~ (i + 1).to!string;
        }
        const sql = "INSERT INTO " ~ table ~ " (" ~ quoted.join(", ") ~ ") VALUES (" ~ placeholders.join(", ") ~ ")";
        const(Parameter[])[] batch;
        ulong inserted;
        foreach (ref row; rows)
        {
            batch ~= fieldParameters(row);
            if (batch.length == 1000)
            {
                inserted += execMany(sql, batch).rowCount;
                batch = null;
            }
        }
        if (batch.length)
            inserted += execMany(sql, batch).rowCount;
        return inserted;
    }

    /// ditto
    ulong insert(T)(string table, T row) if (is(T == struct) && !isInputRange!T)
    {
        return insert(table, (&row)[0 .. 1]);
    }

    private QueryResult runArgs(Args...)(string sql, Args args)
    {
        static if (Args.length)
            return run(sql, parameters(args));
        else
            return run(sql, null);
    }

    /++
    Runs a DML statement (or PL/SQL block) once for each row of `rows` in a
    single round trip (array DML) and returns each execution's row count.
    With `batchErrors`, rows that fail don't stop the others: their errors are
    in the result; without, the first error is thrown (the rows before it are done).

    Throws: `ServerException` for errors (without `batchErrors`);
    `ClientException` if the rows don't match the placeholders or their types
    differ from row to row.
    +/
    BatchResult execMany(string sql, const(Parameter[])[] rows, bool batchErrors = false) @safe
    {
        return runMany(sql, rows, batchErrors);
    }

    /// ditto; each element of `rows` is a `Tuple` or an array of values.
    BatchResult execMany(R)(string sql, R rows, bool batchErrors = false)
            if (isInputRange!R && !is(ElementType!R : const(Parameter)[]))
    {
        import std.typecons : isTuple;

        const(Parameter[])[] converted;
        foreach (row; rows)
        {
            static if (isTuple!(typeof(row)))
                converted ~= parameters(row.expand).dup;
            else
            {
                Parameter[] values;
                foreach (v; row)
                    values ~= Parameter.of(v);
                converted ~= values;
            }
        }
        return runMany(sql, converted, batchErrors);
    }

    /++
    Cancels the running call: a statement being executed or rows being
    fetched. The call then fails with ORA-01013 and the connection stays
    usable. This is the one method that may be called from another thread
    (or task); it does nothing when the connection isn't busy.
    +/
    void cancel() @safe nothrow
    {
        import core.atomic : atomicStore;

        if (state != State.busy || writeLock is null)
            return;
        try
        {
            writeLock.lock();
            scope (exit)
                writeLock.unlock();
            atomicStore(cancelPending, true);
            tns.sendMarker(MarkerType.interrupt);
        }
        catch (Exception)
        {
            // the connection broke: the reading side sees it
        }
    }

    /// Commits the transaction.
    void commit() @safe
    {
        bareCall(FunctionCode.commit);
    }

    /// Rolls the transaction back.
    void rollback() @safe
    {
        bareCall(FunctionCode.rollback);
    }

    /// Checks that the server answers (one round trip).
    void ping() @safe
    {
        bareCall(FunctionCode.ping);
    }

    /// Logs off and closes the connection. Calling it again does nothing.
    void close() @safe nothrow
    {
        if (state == State.closed)
            return;
        const wasReady = state == State.ready;
        state = State.closed;
        try
        {
            if (wasReady)
            {
                call(seq => buildBareCall(FunctionCode.logoff, seq, negotiatedFieldVersion));
                readResponse(null);
                tns.sendEof();
            }
        }
        catch (Exception)
        {
            // the connection is going away anyway
        }
        if (transport !is null)
            transport.close();
    }

    // --- calls and responses ---

    /// ORA-01403: the end of a query's rows.
    package enum uint noMoreRows = 1403;

    /// ORA-01007 and ORA-00932 on a cached query: its tables changed, parse it again.
    private static bool needsReparse(uint number) @safe pure nothrow @nogc
    {
        return number == 1007 || number == 932;
    }

    /// The cache entry for `sql` (a new, uncached one if it isn't there or is in use).
    private CachedStatement statementFor(string sql, StatementKind kind) @safe
    {
        if (auto cached = sql in statements)
            if (!cached.inUse)
                return *cached;
        auto s = new CachedStatement;
        s.sql = sql;
        s.kind = kind;
        s.placeholders = findPlaceholders(sql);
        return s;
    }

    /// Keeps `s` (whose cursor is `cursorId`) in the cache, evicting the least recently used entry.
    private void cache(CachedStatement s, uint cursorId) @safe
    {
        s.cursorId = cursorId;
        s.lastUse = ++useCounter;
        if (s.sql in statements)
            return;
        if (statements.length >= options.statementCacheSize)
        {
            CachedStatement oldest;
            foreach (c; statements)
                if (!c.inUse && (oldest is null || c.lastUse < oldest.lastUse))
                    oldest = c;
            if (oldest is null)
                return;
            closeCursorLater(oldest.cursorId);
            statements.remove(oldest.sql);
        }
        statements[s.sql] = s;
    }

    /// Forgets a cached statement and closes its cursor.
    private void uncache(CachedStatement s) @safe nothrow
    {
        if (s.sql in statements && statements[s.sql] is s)
            statements.remove(s.sql);
        closeCursorLater(s.cursorId);
        s.cursorId = 0;
    }

    /++
    The binds of a statement in the order the server expects them (each
    occurrence of a placeholder in SQL, each distinct one in PL/SQL), from
    positional or named parameters.
    +/
    private Parameter[] arrangeBinds(const ref Placeholders ph, StatementKind kind,
            const(Parameter)[] params, out string[] names) @safe
    {
        import oracle.params : asNumberBoolean, asTextVector;

        import std.algorithm.searching : countUntil;
        import std.conv : to;
        import std.uni : toUpper;

        auto byName = new Parameter[ph.names.length];
        size_t named;
        foreach (ref p; params)
            if (p.name.length)
                named++;
        if (named && named != params.length)
            throw new ClientException("Parameters must be all positional or all named");
        if (named)
        {
            auto set = new bool[ph.names.length];
            foreach (ref p; params)
            {
                auto i = ph.names.countUntil(p.name);
                if (i < 0)
                    i = ph.names.countUntil(p.name.toUpper);
                if (i < 0)
                    throw new ClientException("The statement has no placeholder :" ~ p.name);
                byName[i] = p;
                set[i] = true;
            }
            foreach (i, done; set)
                if (!done)
                    throw new ClientException("No value for placeholder :" ~ ph.names[i]);
        }
        else
        {
            if (params.length != ph.names.length)
                throw new ClientException("The statement has " ~ ph.names.length.to!string ~ " placeholders but "
                        ~ params.length.to!string ~ " arguments were given");
            byName[] = params[];
        }
        names = (kind == StatementKind.plsql ? ph.names : ph.occurrences).dup;
        auto binds = new Parameter[names.length];
        const nativeBoolean = negotiatedFieldVersion >= TtcFieldVersion.v23_1;
        const nativeVector = negotiatedFieldVersion >= TtcFieldVersion.v23_4;
        foreach (i, n; names)
        {
            binds[i] = byName[ph.names.countUntil(n)];
            if (!nativeBoolean)
                binds[i] = asNumberBoolean(binds[i]);
            if (!nativeVector)
                binds[i] = asTextVector(binds[i]);
        }
        return binds;
    }

    /// Whether binds can be sent with the metadata of a parsed cursor: same types, values that fit.
    private static bool fits(const(Parameter)[] cached, Parameter[] binds) @safe pure nothrow
    {
        if (cached.length != binds.length)
            return false;
        foreach (i, ref b; binds)
        {
            if (b.isNull && b.type == OracleType.varchar && b.direction == BindDirection.input)
                b.type = cached[i].type; // an untyped NULL takes the cursor's type
            if (b.type != cached[i].type || b.bufferSize > cached[i].bufferSize || b.direction != cached[i].direction)
                return false;
        }
        return true;
    }

    /// Runs one statement; see `query`.
    private QueryResult run(string sql, const(Parameter)[] params) @safe
    {
        import std.algorithm.searching : canFind;

        checkReady();
        size_t questionMarks;
        const text = rewritePlaceholders(sql, questionMarks);
        const kind = classify(text);
        auto stmt = statementFor(text, kind);
        string[] names;
        auto binds = arrangeBinds(stmt.placeholders, kind, params, names);
        auto result = new QueryResult(this);
        result.isQuery = kind == StatementKind.query;
        result.isPlsql = kind == StatementKind.plsql;
        result.bindNames = names;
        result.returning = new bool[binds.length];
        auto send = new bool[binds.length];
        send[] = true;
        if (kind == StatementKind.dml)
            foreach (i, n; names)
                if (stmt.placeholders.returning.canFind(n))
                {
                    result.returning[i] = true; // its value comes back, none is sent
                    send[i] = false;
                    binds[i].direction = BindDirection.output;
                    binds[i].bufferSize = binds[i].type == OracleType.varchar || binds[i].type == OracleType.raw
                        ? cast(uint) maxBindBytes : binds[i].bufferSize;
                }
        result.binds = binds;
        guarded({
            state = State.busy;
            scope (failure)
                if (state == State.busy)
                    state = State.ready;
            auto e = executeStatement(stmt, result, binds, send);
            if (e.number != 0 && e.number != noMoreRows)
            {
                if (!result.keepCursor)
                    closeCursorLater(e.cursorId);
                throwIfError(e);
            }
            if (result.isQuery && (e.number == 0 || e.number == noMoreRows) && needsDefine(result.columnInfo))
                e = define(result);
            result.rowCount = result.isQuery ? 0 : e.rowCount;
            foreach (c; result.outputCursors)
                if (c !is null && c.columnInfo.length == 0)
                    c.allFetched = true; // a NULL cursor
            result.allFetched = e.number == noMoreRows || !result.isQuery;
            if (!databaseZoneKnown)
                foreach (ref c; result.columnInfo)
                    if (c.type == OracleType.timestampLtz)
                    {
                        loadDatabaseZone();
                        break;
                    }
        });
        if (result.allFetched)
            result.release(); // every row is here: the connection is free
        return result;
    }

    /++
    Executes `stmt` once: re-executes its cached cursor when the binds fit,
    else parses it (again). Returns the end-of-call status.
    +/
    private ErrorInfo executeStatement(CachedStatement stmt, QueryResult result, Parameter[] binds, bool[] send) @safe
    {
        const kind = stmt.kind;
        const cacheable = kind != StatementKind.ddl && options.statementCacheSize > 0;
        const commit = options.autoCommit && kind != StatementKind.query;
        if (stmt.cursorId && fits(stmt.binds, binds))
        {
            call(seq => buildReexecute(stmt.cursorId, kind == StatementKind.query, options.fetchSize, commit, [
                binds
            ],
            send, seq, negotiatedFieldVersion));
            result.columnInfo = stmt.columns.dup;
            result.cursorId = stmt.cursorId;
            auto e = readResponse(result);
            if (!needsReparse(e.number))
            {
                result.keepCursor = true;
                stmt.lastUse = ++useCounter;
                stmt.inUse = kind == StatementKind.query && e.number != noMoreRows;
                result.statement = stmt;
                return e;
            }
            uncache(stmt); // its tables changed: parse it again
            result.reset();
        }
        else if (stmt.cursorId)
            uncache(stmt); // other bind types: parse it again
        ExecuteRequest r;
        r.sql = stmt.sql;
        r.options = ExecuteOption.parse | ExecuteOption.execute;
        r.binds = binds;
        if (binds.length)
        {
            r.options |= ExecuteOption.bind;
            r.rows = [binds];
            r.sendValue = send;
        }
        if (kind == StatementKind.plsql)
        {
            r.flags = ExecuteFlag.implicitResultSet;
            if (binds.length)
                r.options |= ExecuteOption.plsqlBind;
        }
        else
            r.options |= ExecuteOption.notPlsql;
        if (kind == StatementKind.query)
        {
            r.options |= ExecuteOption.fetch;
            r.prefetchRows = options.fetchSize;
            r.isQuery = true;
        }
        else
        {
            r.executions = 1;
            if (commit)
                r.options |= ExecuteOption.commit;
        }
        call(seq => buildExecute(r, seq, negotiatedFieldVersion));
        auto e = readResponse(result);
        result.cursorId = e.cursorId;
        if (cacheable && e.cursorId && (e.number == 0 || e.number == noMoreRows))
        {
            stmt.binds = binds.dup;
            stmt.columns = result.columnInfo.dup;
            stmt.inUse = kind == StatementKind.query && e.number != noMoreRows;
            cache(stmt, e.cursorId);
            result.keepCursor = true;
            result.statement = stmt;
        }
        return e;
    }

    /// Whether a query's columns need a define: LOBs not defined yet.
    private static bool needsDefine(const(ColumnInfo)[] columns) @safe pure nothrow
    {
        foreach (ref c; columns)
            if ((c.isLob || c.type == OracleType.json || c.type == OracleType.vector) && c.fetchType == 0)
                return true;
        return false;
    }

    /++
    Defines the columns of a query with LOB columns (CLOB and NCLOB as LONG,
    BLOB as LONG RAW: their contents come with the rows; or as locators with
    `lobLocators`; BFILE always as locators) and fetches the first rows: the
    server sends no rows for such queries until they are defined.
    +/
    private ErrorInfo define(QueryResult result) @safe
    {
        foreach (ref c; result.columnInfo)
        {
            if (c.type == OracleType.clob)
                c.fetchType = options.lobLocators ? OracleType.clob : OracleType.long_;
            else if (c.type == OracleType.blob)
                c.fetchType = options.lobLocators ? OracleType.blob : OracleType.longRaw;
            else if (c.type == OracleType.bfile || c.type == OracleType.json || c.type == OracleType.vector)
                c.fetchType = c.type; // BFILE: locators; JSON, VECTOR: their images
        }
        ExecuteRequest r;
        r.cursorId = result.cursorId;
        r.options = ExecuteOption.define | ExecuteOption.notPlsql;
        r.executions = options.fetchSize;
        r.prefetchRows = options.fetchSize;
        r.isQuery = true;
        r.defines = result.columnInfo;
        call(seq => buildExecute(r, seq, negotiatedFieldVersion));
        auto e = readResponse(result);
        if (result.statement !is null)
        {
            result.statement.columns = result.columnInfo.dup;
            result.statement.inUse = e.number != noMoreRows;
        }
        return e;
    }

    /++
    Runs a LOB operation (see `oracle.lob`). Allowed while a query result is
    open: LOBs are read while their rows are.
    +/
    package LobResponse lobOperation(const ref LobRequest q) @safe
    {
        if (state == State.closed)
            throw new ClientException("The connection is closed");
        LobResponse response;
        guarded({
            const wasReady = state == State.ready;
            state = State.busy;
            scope (exit)
                if (wasReady && state == State.busy)
                    state = State.ready;
            call(seq => buildLobOperation(q, seq, negotiatedFieldVersion));
            for (;;)
            {
                const type = reader.u8();
                switch (type)
                {
                case MessageType.lobData:
                    response.data ~= reader.clr(options.maxValueLength);
                    break;
                case MessageType.parameter:
                    // the locator, then echoes of what was sent: the character set, the amount, the NULL-LOB flag
                    response.locator = reader.bytes(q.locator.length);
                    if (q.charset)
                        reader.ub2();
                    if (q.withAmount)
                        response.amount = reader.ub8();
                    if (q.nullLobPointer)
                        response.flag = reader.u8() != 0;
                    break;
                case MessageType.warning:
                    skipWarning(reader);
                    break;
                case MessageType.serverSidePiggyback:
                    skipServerPiggyback(reader);
                    break;
                case MessageType.status:
                    reader.ub4();
                    reader.ub2(); // end-to-end sequence number
                    checkResponseEnd();
                    return;
                case MessageType.error:
                    const e = readErrorInfo(reader, serverFieldVersion);
                    checkResponseEnd();
                    throwIfError(e);
                    return;
                default:
                    throw new ProtocolException("Unexpected message type " ~ toText(type) ~ " in a LOB response");
                }
            }
        });
        return response;
    }

    /++
    Creates a temporary LOB (`OracleType.clob` or `OracleType.blob`; an
    NCLOB with `national`), to write and then bind as a parameter. Free it
    with `Lob.free` when done (the server frees it at the session's end).

    Throws: `ClientException` for other types; `ServerException` for server errors.
    +/
    Lob createLob(OracleType type, bool national = false) @safe
    {
        if (type != OracleType.clob && type != OracleType.blob)
            throw new ClientException("Temporary LOBs are CLOBs or BLOBs");
        checkReady();
        const form = type == OracleType.blob ? CharsetForm.none : national ? CharsetForm.nchar : CharsetForm.implicit;
        LobRequest q;
        q.operation = LobOperation.createTemporary;
        q.locator = new ubyte[40];
        q.destinationLength = 10; // duration: the session
        q.sourceOffset = form == CharsetForm.none ? 1 : form;
        q.destinationOffset = type;
        q.charset = CharsetId.al32utf8;
        q.nullLobPointer = true;
        const r = lobOperation(q);
        return new Lob(this, type, form, r.locator);
    }

    /// Array DML; see `execMany`.
    private BatchResult runMany(string sql, const(Parameter[])[] rows, bool batchErrors) @safe
    {
        import std.conv : to;

        checkReady();
        size_t questionMarks;
        const text = rewritePlaceholders(sql, questionMarks);
        const kind = classify(text);
        if (kind == StatementKind.query || kind == StatementKind.ddl)
            throw new ClientException("execMany runs DML statements and PL/SQL blocks");
        BatchResult batch;
        if (rows.length == 0)
            return batch;
        auto stmt = statementFor(text, kind);
        if (stmt.placeholders.returning.length)
            throw new ClientException("execMany doesn't support RETURNING INTO");
        Parameter[][] arranged;
        foreach (row; rows)
        {
            string[] names;
            arranged ~= arrangeBinds(stmt.placeholders, kind, row, names);
        }
        // one type per bind (NULLs take the others' type), the largest size
        auto binds = arranged[0].dup;
        foreach (row; arranged[1 .. $])
            foreach (i, ref p; row)
            {
                if (p.isNull && p.type == OracleType.varchar)
                    continue;
                if (binds[i].isNull && binds[i].type == OracleType.varchar)
                    binds[i].type = p.type;
                else if (p.type != binds[i].type)
                    throw new ClientException("Bind " ~ (i + 1).to!string ~ " has different types in different rows");
                if (p.bufferSize > binds[i].bufferSize)
                    binds[i].bufferSize = p.bufferSize;
            }
        foreach (ref b; binds)
            if (b.direction != BindDirection.input)
                throw new ClientException("execMany doesn't support OUT parameters");
        guarded({
            state = State.busy;
            scope (exit)
                if (state == State.busy)
                    state = State.ready;
            const cacheable = options.statementCacheSize > 0;
            ExecuteRequest r;
            r.options = ExecuteOption.execute | ExecuteOption.bind;
            if (stmt.cursorId && fits(stmt.binds, binds))
                r.cursorId = stmt.cursorId; // parsed already
            else
            {
                if (stmt.cursorId)
                    uncache(stmt);
                r.options |= ExecuteOption.parse;
                r.sql = stmt.sql;
            }
            r.options |= kind == StatementKind.plsql ? ExecuteOption.plsqlBind : ExecuteOption.notPlsql;
            if (batchErrors)
                r.options |= ExecuteOption.batchErrors;
            if (options.autoCommit)
                r.options |= ExecuteOption.commit;
            r.executions = cast(uint) arranged.length;
            r.binds = binds;
            r.rows = arranged;
            r.dmlRowCounts = kind == StatementKind.dml;
            if (r.dmlRowCounts)
                r.flags = ExecuteFlag.dmlRowCounts;
            auto result = new QueryResult(this);
            result.dmlRowCounts = r.dmlRowCounts;
            call(seq => buildExecute(r, seq, negotiatedFieldVersion));
            auto e = readResponse(result);
            batch.rowCounts = result.rowCounts;
            batch.rowCount = e.rowCount;
            if (cacheable && e.cursorId && (e.number == 0 || (e.number == 24_381 && batchErrors)))
            {
                stmt.binds = binds;
                cache(stmt, e.cursorId);
            }
            else if (e.cursorId != stmt.cursorId)
                closeCursorLater(e.cursorId);
            if (e.number == 24_381 && batchErrors)
                batch.errors = e.batchErrors;
            else
                throwIfError(e);
        });
        return batch;
    }

    /++
    Reads DBTIMEZONE: WITH LOCAL TIME ZONE values travel in the database time
    zone, and the client shows them in the session time zone. Read once, when
    a result first has such a column (another cursor may be open meanwhile).
    +/
    private void loadDatabaseZone() @safe
    {
        auto zone = new QueryResult(this);
        ExecuteRequest r;
        r.sql = "SELECT DBTIMEZONE FROM dual";
        r.options = ExecuteOption.parse | ExecuteOption.execute | ExecuteOption.fetch | ExecuteOption.notPlsql;
        r.prefetchRows = 1;
        r.isQuery = true;
        call(seq => buildExecute(r, seq, negotiatedFieldVersion));
        const e = readResponse(zone);
        closeCursorLater(e.cursorId);
        if (e.number != 0 && e.number != noMoreRows)
            throwIfError(e);
        if (zone.batch.length && zone.batch[0].length && zone.batch[0][0]!is null)
            databaseZone = zoneOf(cast(string) zone.batch[0][0]);
        databaseZoneKnown = true;
    }

    /// Fetches the next batch of `result`'s rows.
    package void fetchMore(QueryResult result) @safe
    {
        if (state != State.busy)
            throw new ClientException("The connection is closed");
        guarded({
            if (result.needsExecuteFetch)
            {
                // the first fetch of a child cursor (implicit result, REF cursor)
                ExecuteRequest r;
                r.cursorId = result.cursorId;
                r.options = ExecuteOption.fetch | ExecuteOption.notPlsql;
                r.prefetchRows = options.fetchSize;
                r.executions = options.fetchSize;
                r.isQuery = true;
                call(seq => buildExecute(r, seq, negotiatedFieldVersion));
                result.needsExecuteFetch = false;
            }
            else
                call(seq => buildFetch(result.cursorId, options.fetchSize, seq, negotiatedFieldVersion));
            const e = readResponse(result);
            if (e.number == noMoreRows)
                result.allFetched = true;
            else if (e.number != 0)
            {
                result.allFetched = true;
                throwIfError(e);
            }
        });
    }

    /// A child result that was never fetched is closed: its cursor goes with the next call.
    package void closeChild(uint cursorId) @safe nothrow
    {
        closeCursorLater(cursorId);
    }

    /// A child result (implicit result, REF cursor) starts fetching: it holds the connection.
    package void beginChild() @safe
    {
        checkReady();
        state = State.busy;
    }

    /// Called by a result when it is done: its cursor is kept (cached) or closed with the next call.
    package void release(QueryResult r) @safe nothrow
    {
        if (r.keepCursor && r.statement !is null && r.statement.cursorId == r.cursorId)
            r.statement.inUse = false;
        else
            closeCursorLater(r.cursorId);
        if (state == State.busy)
            state = State.ready;
    }

    private void closeCursorLater(uint cursorId) @safe nothrow
    {
        if (cursorId != 0)
            cursorsToClose ~= cursorId;
    }

    private void bareCall(FunctionCode code) @safe
    {
        checkReady();
        guarded({
            call(seq => buildBareCall(code, seq, negotiatedFieldVersion));
            throwIfError(readResponse(null));
        });
    }

    private ubyte nextSequence() @safe pure nothrow @nogc
    {
        lastSequence = lastSequence == 255 ? 1 : cast(ubyte)(lastSequence + 1);
        return lastSequence;
    }

    /// Sends a call, preceded by the pending close-cursors piggyback.
    private void call(scope ubyte[]delegate(ubyte sequence) @safe build) @safe
    {
        import core.atomic : atomicLoad;

        if (atomicLoad(cancelPending))
            finishCancel(); // a cancel that came after the last call ended
        TtcWriter w;
        if (cursorsToClose.length)
        {
            putCloseCursors(w, cursorsToClose, nextSequence(), negotiatedFieldVersion);
            cursorsToClose = null;
        }
        if (endToEnd.changed)
        {
            putEndToEnd(w, endToEnd, nextSequence(), negotiatedFieldVersion);
            endToEnd.changed = 0;
        }
        w.bytes(build(nextSequence()));
        writeLock.lock();
        scope (exit)
            writeLock.unlock();
        tns.sendData(w.data);
    }

    /++
    After a cancel: the server answers every INTERRUPT with a reset and an
    ORA-01013 error, which may come after the response of the call it
    interrupted. Reads it, unless the response just read was it.
    +/
    private ErrorInfo finishCancel(ErrorInfo response = ErrorInfo.init, bool inResponse = false) @safe
    {
        import core.atomic : atomicStore;

        atomicStore(cancelPending, false);
        if (inResponse && tns.takeBreak())
            return response; // the reset came during the response: it ended with the error
        for (;;)
        {
            const type = reader.u8();
            if (type == MessageType.error)
            {
                auto e = readErrorInfo(reader, serverFieldVersion);
                checkResponseEnd();
                tns.takeBreak();
                return e;
            }
            if (type == MessageType.status)
            {
                ErrorInfo e;
                e.callStatus = reader.ub4();
                reader.ub2(); // end-to-end sequence number
                continue;
            }
            if (type == MessageType.parameter)
                readReturnParameters(reader, false);
            else if (type == MessageType.serverSidePiggyback)
                skipServerPiggyback(reader);
            else if (type == MessageType.warning)
                skipWarning(reader);
            else
                throw new ProtocolException("Unexpected message type " ~ toText(type) ~ " after a cancel");
        }
    }

    /++
    Reads a response up to its end (an ERROR or STATUS message): rows, OUT
    values, implicit results and row counts go to `result` if it is not null.
    +/
    private ErrorInfo readResponse(QueryResult result) @safe
    {
        import core.atomic : atomicLoad;

        immutable(ubyte)[] bitVector;
        for (;;)
        {
            const type = reader.u8();
            switch (type)
            {
            case MessageType.describeInfo:
                if (result is null)
                    throw new ProtocolException("Unexpected column metadata in the server's response");
                result.columnInfo = readDescribeInfo(reader, negotiatedFieldVersion);
                break;
            case MessageType.rowHeader:
                const bits = readRowHeader(reader);
                if (bits.length)
                    bitVector = bits;
                break;
            case MessageType.bitVector:
                if (result is null)
                    throw new ProtocolException("Unexpected bit vector in the server's response");
                bitVector = readBitVector(reader, result.columnInfo.length);
                break;
            case MessageType.rowData:
                if (result is null)
                    throw new ProtocolException("Unexpected row in the server's response");
                if (result.hasOutputs)
                    readOutputs(result);
                else
                    readRow(result, bitVector);
                bitVector = null;
                break;
            case MessageType.ioVector:
                const directions = readIoVector(reader);
                if (result !is null)
                    result.directions = directions;
                break;
            case MessageType.parameter:
                const counts = readReturnParameters(reader, result !is null && result.dmlRowCounts);
                if (result !is null && counts.length)
                    result.rowCounts = counts.dup;
                break;
            case MessageType.implicitResultSet:
                foreach (c; readImplicitResults(reader, negotiatedFieldVersion))
                    if (result !is null)
                        result.implicit ~= childResult(c);
                break;
            case MessageType.flushOutBinds:
                writeLock.lock();
                scope (exit)
                    writeLock.unlock();
                tns.sendData([MessageType.flushOutBinds]);
                break;
            case MessageType.warning:
                skipWarning(reader);
                break;
            case MessageType.serverSidePiggyback:
                skipServerPiggyback(reader);
                break;
            case MessageType.status:
                ErrorInfo e;
                e.callStatus = reader.ub4();
                reader.ub2(); // end-to-end sequence number
                lastCallStatus = e.callStatus;
                checkResponseEnd();
                return atomicLoad(cancelPending) ? finishCancel(e, true) : e;
            case MessageType.error:
                auto e = readErrorInfo(reader, serverFieldVersion);
                lastCallStatus = e.callStatus;
                checkResponseEnd();
                return atomicLoad(cancelPending) ? finishCancel(e, true) : e;
            default:
                throw new ProtocolException("Unexpected message type " ~ toText(type) ~ " in the server's response");
            }
        }
    }

    /// A result for a child cursor (implicit result, REF cursor).
    private QueryResult childResult(ChildCursor c) @safe
    {
        auto r = new QueryResult(this);
        r.columnInfo = c.columns;
        r.cursorId = c.cursorId;
        r.isQuery = true;
        r.child = true;
        r.needsExecuteFetch = true;
        return r;
    }

    /++
    Reads the values of OUT and IN OUT binds (after an IO_VECTOR) and of
    `RETURNING ... INTO` binds (a row count, then the values).
    +/
    private void readOutputs(QueryResult result) @safe
    {
        if (result.outputData.length != result.binds.length)
            result.outputData = new immutable(ubyte)[][][result.binds.length];
        if (result.outputCursors.length != result.binds.length)
            result.outputCursors = new QueryResult[result.binds.length];
        foreach (i, ref b; result.binds)
        {
            const isReturning = result.returning[i];
            if (!isReturning && !(i < result.directions.length && (result.directions[i] & BindDirection.output)))
                continue;
            const count = isReturning ? reader.ub4() : 1;
            if (count > 1_000_000)
                throw new ProtocolException("Invalid RETURNING row count");
            foreach (_; 0 .. count)
            {
                if (b.type == OracleType.cursor)
                {
                    result.outputCursors[i] = childResult(readRefCursor(reader, negotiatedFieldVersion));
                    result.outputData[i] ~= null;
                }
                else
                {
                    const column = bindColumn(b, result.bindNames[i]);
                    result.outputData[i] ~= readColumnValue(reader, column, options.maxValueLength);
                }
                reader.sb(4); // the value's actual length (or an indicator)
            }
        }
    }

    /// After the last message of a response: nothing may follow (a mistake in a message layout shows here).
    private void checkResponseEnd() @safe
    {
        if (reader.reader.buffered != 0 || tns.unread != 0)
            throw new ProtocolException("The server's response continues after its end");
    }

    private void readRow(QueryResult result, scope const(ubyte)[] bitVector) @safe
    {
        const columns = result.columnInfo;
        const previous = result.batch.length ? result.batch[$ - 1] : null;
        auto row = new immutable(ubyte)[][columns.length];
        foreach (i, ref c; columns)
        {
            if (columnSent(bitVector, i))
                row[i] = readColumnValue(reader, c, options.maxValueLength);
            else if (previous !is null)
                row[i] = previous[i];
            else if (result.lastRow !is null)
                row[i] = result.lastRow[i];
            else
                throw new ProtocolException("A repeated column value without a previous row");
        }
        result.batch ~= row;
        result.lastRow = row;
    }

    private void throwIfError(const ErrorInfo e) @safe
    {
        if (e.number != 0)
            throw new ServerException(e.number, e.message, e.position);
    }

    /// The column metadata of an OUT bind, for reading its value.
    package static ColumnInfo bindColumn(const ref Parameter b, string name) @safe pure nothrow
    {
        import oracle.protocol.negotiate : CharsetId;

        ColumnInfo c;
        c.name = name;
        c.type = b.type;
        c.bufferSize = b.bufferSize ? b.bufferSize : 1;
        c.maxSize = b.bufferSize;
        if (b.isText)
        {
            c.charsetId = CharsetId.al32utf8;
            c.charsetForm = CharsetForm.implicit;
        }
        c.precision = 9;
        c.scale = 9;
        c.nullable = true;
        return c;
    }

    /++
    Runs `action`. A `ServerException` leaves the connection usable (the
    response was read to its end); any other exception means the stream is in
    an unknown state, so the connection is closed.
    +/
    package void guarded(scope void delegate() @safe action) @safe
    {
        try
            action();
        catch (ServerException e)
            throw e;
        catch (Exception e)
        {
            state = State.closed;
            if (transport !is null)
                transport.close();
            throw e;
        }
    }

    package void checkReady() const @safe
    {
        if (state == State.closed)
            throw new ClientException("The connection is closed");
        if (state == State.busy)
            throw new ClientException("The connection is busy: read or close the previous query result first");
    }

    private string sessionValue(string key) const @safe pure nothrow
    {
        foreach (kv; sessionValues)
            if (kv.key == key)
                return kv.value;
        return null;
    }

    private uint sessionNumber(string key) const @safe pure
    {
        import std.conv : ConvException, to;

        try
            return sessionValue(key).to!uint;
        catch (ConvException)
            return 0;
    }

    // --- connecting ---

    private void connect() @safe
    {
        backend = backendFor(options.ioMode);
        writeLock = backend.newLock();

        void tryHost(HostPort endpoint) @safe
        {
            connectTo(endpoint);
        }

        connectFirst(orderHosts(options.endpoints, options.hostSelection), &tryHost, "Oracle Database");
    }

    private Transport open(HostPort endpoint) @safe
    {
        auto raw = options.transportFactory !is null ? options.transportFactory(endpoint.host, endpoint.port,
                options.connectTimeout) : backend.connect(endpoint.host, endpoint.port, options.connectTimeout);
        raw.setTimeouts(options.connectTimeout, options.connectTimeout);
        if (!options.secure)
            return raw;
        return new TlsTransport(raw, backend, TlsContext.client(options.tls), endpoint.host, options.tls,
                options.connectTimeout);
    }

    private void connectTo(HostPort endpoint) @safe
    {
        import oracle : oracleClientName;

        state = State.busy;
        scope (failure)
        {
            state = State.closed;
            if (transport !is null)
                transport.close();
        }
        lastSequence = 0;
        cursorsToClose = null;
        statements = null;
        const program = options.program.length ? options.program : programName();
        const machine = options.machine.length ? options.machine : machineName();
        const osUser = options.osUser.length ? options.osUser : userName();
        string connectData = options.connectDescriptor(endpoint, program, machine, osUser);
        ubyte connectFlags;

        // the listener: CONNECT until ACCEPT, following redirects
        foreach (attempt; 0 .. 10)
        {
            transport = open(endpoint);
            tns = new TnsStream(transport);
            tns.writePackets(buildConnect(connectData, options.sdu, TnsVersion.withAcceptFlags, connectFlags));
            auto p = tns.readPacket();
            while (p.type == PacketType.resend)
            {
                tns.writePackets(buildConnect(connectData, options.sdu, TnsVersion.withAcceptFlags, connectFlags));
                p = tns.readPacket();
            }
            if (p.type == PacketType.accept)
            {
                const a = parseAccept(p.bytes);
                if (a.tnsVersion < TnsVersion.minAccepted)
                    throw new ConnectionException("The server's protocol version " ~ toText(
                            a.tnsVersion)
                            ~ " is too old (Oracle Database 12.1 or later is needed)");
                if (a.flags0 & nsiNaRequired)
                    throw new ConnectionException("The server requires Oracle Native Network Encryption, which is"
                            ~ " not supported; use TLS (TCPS) instead");
                tns.largeLengths = true;
                tns.sdu = a.sdu < 512 ? 512 : a.sdu > maxSdu ? maxSdu : a.sdu;
                break;
            }
            if (p.type == PacketType.refuse)
            {
                string text;
                const code = parseRefuse(p.bytes, text);
                throw new ConnectionException(refuseMessage(code, text));
            }
            if (p.type != PacketType.redirect)
                throw new ProtocolException("Unexpected TNS packet type " ~ toText(p.type) ~ " from the listener");
            immutable(ubyte)[] following;
            if (redirectDataFollows(p.bytes))
                following = tns.readPacket().bytes;
            string address, newData;
            parseRedirect(p.bytes, following, address, newData);
            transport.close();
            endpoint = redirectEndpoint(address, endpoint);
            if (newData.length)
                connectData = newData;
            connectFlags = PacketFlags.redirect;
            if (attempt == 9)
                throw new ConnectionException("Too many redirects from the listener");
        }
        reader = TtcReader(new BufferedReader(tns));

        // negotiation
        tns.sendData(buildProtocolMessage(oracleClientName));
        serverInfo = readProtocolResponse(reader);
        serverFieldVersion = serverInfo.compileCaps.length > Cap.fieldVersion ? serverInfo
            .compileCaps[Cap.fieldVersion] : 0;
        negotiatedFieldVersion = serverFieldVersion < clientFieldVersion ? serverFieldVersion : clientFieldVersion;
        if (negotiatedFieldVersion < TtcFieldVersion.v12_1)
            throw new ConnectionException("The server's TTC field version " ~ toText(
                    serverFieldVersion)
                    ~ " is too old (Oracle Database 12.1 or later is needed)");
        tns.sendData(buildDataTypesMessage());
        readDataTypesResponse(reader);
        checkResponseEnd();

        // O5LOGON
        import std.algorithm.searching : all;
        import std.ascii : isAlphaNum;

        if (!options.sessionTimeZone.all!(c => isAlphaNum(c) || c == '+' || c == '-' || c == ':' || c == '/'
                || c == '_'))
            throw new ClientException("Invalid session time zone '" ~ options.sessionTimeZone ~ "'");
        ClientDetails details;
        details.terminal = options.terminal;
        details.program = program;
        details.machine = machine;
        details.pid = toText(processId());
        details.osUser = osUser;
        call(seq => buildPhase1(options.user, details, seq, negotiatedFieldVersion));
        const phase1 = readAuthResponse();
        const keys = deriveKeys(phase1, options.password, (size_t n) @safe => randomBytes(n));
        call(seq => buildPhase2(options.user, keys, oracleClientName, options.sessionTimeZone, seq,
                negotiatedFieldVersion));
        sessionValues = readAuthResponse();
        checkServerResponse(sessionValues, keys);

        transport.setTimeouts(options.receiveTimeout, options.sendTimeout);
        sessionZone = zoneOf(options.sessionTimeZone);
        databaseZone = UTC();
        databaseZoneKnown = false;
        connectedHost = endpoint;
        state = State.ready;
    }

    /// Reads the answer to an authentication phase: key/value pairs, then the call status.
    private KeyValue[] readAuthResponse() @safe
    {
        KeyValue[] values;
        for (;;)
        {
            const type = reader.u8();
            switch (type)
            {
            case MessageType.parameter:
                values ~= readKeyValues(reader);
                break;
            case MessageType.warning:
                skipWarning(reader);
                break;
            case MessageType.serverSidePiggyback:
                skipServerPiggyback(reader);
                break;
            case MessageType.error:
                const e = readErrorInfo(reader, serverFieldVersion);
                checkResponseEnd();
                if (e.number != 0)
                    throw new ServerException(e.number, e.message, e.position);
                return values;
            default:
                throw new ProtocolException("Unexpected message type " ~ toText(type) ~ " in the login response");
            }
        }
    }
}

/// The `std.datetime` zone of a session time zone setting: `+02:00`, `UTC`, `Europe/Lisbon`.
private immutable(TimeZone) zoneOf(string setting) @safe
{
    import core.time : minutes;
    import std.conv : ConvException, to;
    import std.datetime.timezone : SimpleTimeZone, UTC;
    import dbwire.types.timezone : resolveTimeZone;

    if (setting.length == 6 && (setting[0] == '+' || setting[0] == '-') && setting[3] == ':')
    {
        try
        {
            const m = setting[1 .. 3].to!int * 60 + setting[4 .. 6].to!int;
            if (m == 0)
                return UTC();
            return new immutable SimpleTimeZone(minutes(setting[0] == '-' ? -m : m));
        }
        catch (ConvException)
            return UTC();
    }
    return resolveTimeZone(setting);
}

private ubyte[] randomBytes(size_t n) @safe
{
    import dbwire.crypto.random : secureRandom = randomBytes;

    return secureRandom(n);
}

/// A parsed statement kept with its cursor, to run it again without parsing.
package final class CachedStatement
{
    string sql;
    StatementKind kind;
    Placeholders placeholders;
    uint cursorId; // 0: not parsed
    Parameter[] binds; // the bind metadata it was parsed with
    ColumnInfo[] columns; // a query's columns (a re-execution doesn't send them again)
    bool inUse; // a query result still reads its rows
    ulong lastUse;
}

/// The host and port of a REDIRECT address (`(ADDRESS=(PROTOCOL=tcp)(HOST=h)(PORT=p))`).
private HostPort redirectEndpoint(string address, HostPort current) @safe
{
    import std.conv : ConvException, to;
    import oracle.settings : DescriptorNode;

    const node = DescriptorNode.parse(address);
    const a = node.key == "ADDRESS" ? node : node.child("ADDRESS");
    if (a is null)
        throw new ProtocolException("Invalid REDIRECT address '" ~ address ~ "'");
    HostPort h;
    h.host = a.value("HOST", current.host);
    try
        h.port = a.value("PORT").length ? a.value("PORT").to!ushort : current.port;
    catch (ConvException)
        throw new ProtocolException("Invalid REDIRECT address '" ~ address ~ "'");
    return h;
}

/// The message for a listener's REFUSE.
private string refuseMessage(int code, string text) @safe pure
{
    string what;
    switch (code)
    {
    case 12_514:
        what = "the listener does not know the requested service";
        break;
    case 12_505:
        what = "the listener does not know the requested SID";
        break;
    case 12_516:
    case 12_519:
    case 12_520:
        what = "no service handler is available";
        break;
    case 12_526:
    case 12_527:
    case 12_528:
        what = "the instance is restricted or blocks new connections";
        break;
    default:
        what = "the listener refused the connection";
        break;
    }
    return code ? "ORA-" ~ zeroPad(code) ~ ": " ~ what ~ " " ~ text : what ~ " " ~ text;
}

private string zeroPad(int code) @safe pure
{
    import std.format : format;

    return format("%05d", code);
}

private string programName() @safe nothrow
{
    try
    {
        import std.file : thisExePath;
        import std.path : baseName;

        return thisExePath().baseName;
    }
    catch (Exception)
        return "oracle-native";
}

private string machineName() @safe nothrow
{
    try
    {
        import std.socket : Socket;

        return Socket.hostName;
    }
    catch (Exception)
        return "localhost";
}

private string userName() @safe nothrow
{
    try
    {
        import std.process : environment;

        version (Windows)
            return environment.get("USERNAME", "unknown");
        else
            return environment.get("USER", environment.get("LOGNAME", "unknown"));
    }
    catch (Exception)
        return "unknown";
}

private uint processId() @trusted nothrow
{
    import std.process : thisProcessID;

    return cast(uint) thisProcessID; // reads the process id
}

private string toText(T)(T v) @safe pure
{
    import std.conv : to;

    return v.to!string;
}
