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
import oracle.result : QueryResult;
import oracle.settings : ConnectionOptions, HostPort;
import oracle.statement : StatementKind, classify;
import oracle.types.typeinfo : ColumnInfo;

/++
One connection to Oracle Database.

One call at a time: a `QueryResult` keeps the connection busy until all its
rows are read or it is closed. The connection is not thread-safe. Call
`close` when done; the garbage collector does not close it.

Transactions are explicit: changes are committed by `commit` (or by DDL
statements), unless `ConnectionOptions.autoCommit` is set.
+/
final class Connection
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
    private uint lastCallStatus;

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
    Runs a statement that returns no rows (DML, DDL, a PL/SQL block) and
    returns the number of rows it changed.

    Throws: `ServerException` if the statement fails; the connection stays usable.
    +/
    ulong exec(string sql) @safe
    {
        const kind = classify(sql);
        if (kind == StatementKind.query)
        {
            query(sql).close();
            return 0;
        }
        checkReady();
        ulong rows;
        guarded({
            state = State.busy;
            scope (exit)
                if (state == State.busy)
                    state = State.ready;
            ExecuteRequest r;
            r.sql = sql;
            r.options = ExecuteOption.parse | ExecuteOption.execute;
            if (kind != StatementKind.plsql)
                r.options |= ExecuteOption.notPlsql;
            if (options.autoCommit)
                r.options |= ExecuteOption.commit;
            r.executions = 1;
            call(seq => buildExecute(r, seq, negotiatedFieldVersion));
            const e = readResponse(null);
            closeCursorLater(e.cursorId);
            throwIfError(e);
            rows = e.rowCount;
        });
        return rows;
    }

    /++
    Runs a query and returns its rows. The connection stays busy until all
    rows are read or the result is closed.

    Throws: `ServerException` if the statement fails; the connection stays usable.
    +/
    QueryResult query(string sql) @safe
    {
        checkReady();
        QueryResult result;
        guarded({
            state = State.busy;
            scope (failure)
                if (state == State.busy)
                    state = State.ready;
            const kind = classify(sql);
            result = new QueryResult(this);
            ExecuteRequest r;
            r.sql = sql;
            r.options = ExecuteOption.parse | ExecuteOption.execute;
            if (kind != StatementKind.plsql)
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
                if (options.autoCommit)
                    r.options |= ExecuteOption.commit;
            }
            call(seq => buildExecute(r, seq, negotiatedFieldVersion));
            const e = readResponse(result);
            result.cursorId = e.cursorId;
            if (e.number != 0 && e.number != noMoreRows)
            {
                closeCursorLater(e.cursorId);
                throwIfError(e);
            }
            result.allFetched = e.number == noMoreRows || kind != StatementKind.query;
        });
        return result;
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

    /// Fetches the next batch of `result`'s rows.
    package void fetchMore(QueryResult result) @safe
    {
        if (state != State.busy)
            throw new ClientException("The connection is closed");
        guarded({
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

    /// Called by a result when it is done: its cursor is closed with the next call.
    package void release(uint cursorId) @safe nothrow
    {
        closeCursorLater(cursorId);
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
        TtcWriter w;
        if (cursorsToClose.length)
        {
            putCloseCursors(w, cursorsToClose, nextSequence(), negotiatedFieldVersion);
            cursorsToClose = null;
        }
        w.bytes(build(nextSequence()));
        tns.sendData(w.data);
    }

    /++
    Reads a response up to its end (an ERROR or STATUS message), adding the
    rows to `result` if it is not null.
    +/
    private ErrorInfo readResponse(QueryResult result) @safe
    {
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
                readRow(result, bitVector);
                bitVector = null;
                break;
            case MessageType.parameter:
                skipReturnParameters(reader);
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
                lastCallStatus = e.callStatus;
                checkResponseEnd();
                return e;
            case MessageType.error:
                const e = readErrorInfo(reader, serverFieldVersion);
                lastCallStatus = e.callStatus;
                checkResponseEnd();
                return e;
            default:
                throw new ProtocolException("Unexpected message type " ~ toText(type) ~ " in the server's response");
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

private ubyte[] randomBytes(size_t n) @safe
{
    import dbwire.crypto.random : secureRandom = randomBytes;

    return secureRandom(n);
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
