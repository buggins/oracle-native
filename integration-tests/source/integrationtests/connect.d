/// Connecting: connection strings, failover, login errors, packet sizes, timeouts, TLS.
module integrationtests.connect;

import std.array : replicate;
import std.exception : collectException, enforce;
import std.process : environment;

import oracle;
import integrationtests.server;

/// Connects, reads the session information, pings, closes twice.
void testConnect()
{
    import std.conv : to;

    auto conn = connectToServer();
    enforce(conn.isOpen && !conn.isBusy, "open and ready");
    import std.regex : matchFirst;

    const versionMatch = matchFirst(conn.serverVersion, `^(\d+)\.\d+\.\d+\.\d+\.\d+$`);
    enforce(!versionMatch.empty && versionMatch[1].to!int >= 18, "server version: " ~ conn.serverVersion);
    enforce(conn.sessionId.to!string == scalar(conn, "SELECT SYS_CONTEXT('USERENV', 'SID') FROM dual"),
            "session ID");
    enforce(conn.serialNumber != 0, "serial number");
    import std.uni : toUpper;

    enforce(conn.serviceName.toUpper == serviceName().toUpper, "service name: " ~ conn.serviceName);
    enforce(conn.databaseName.toUpper == serviceName().toUpper, "database name: " ~ conn.databaseName);
    enforce(conn.maxIdentifierLength == 128, "identifier length");
    enforce(scalar(conn, "SELECT SESSIONTIMEZONE FROM dual") == "+00:00", "session time zone");
    conn.ping();
    conn.close();
    enforce(!conn.isOpen, "closed");
    conn.close();
}

/// URL, Easy Connect and descriptor strings; client identification and session time zone options.
void testConnectionStrings()
{
    const host = environment.get("ORACLE_HOST");
    auto easy = new Connection(host ~ "/" ~ serviceName(), userName(), password());
    enforce(scalar(easy, "SELECT 1 FROM dual") == "1", "Easy Connect");
    easy.close();

    const hp = ConnectionOptions.fromEasyConnect(host).endpoints[0];
    import std.conv : to;

    const descriptor = "(DESCRIPTION=(ADDRESS=(PROTOCOL=TCP)(HOST=" ~ hp.host ~ ")(PORT=" ~ hp.port
        .to!string
        ~ "))(CONNECT_DATA=(SERVER=DEDICATED)(SERVICE_NAME=" ~ serviceName() ~ ")))";
    auto d = new Connection(descriptor, userName(), password());
    enforce(scalar(d, "SELECT 2 FROM dual") == "2", "descriptor");
    d.close();

    auto conn = connectToServer(
            "program=itest-prog&machine=itest-host&osuser=itest-user&terminal=itest-term"
            ~ "&time_zone=%2B02:00");
    scope (exit)
        conn.close();
    enforce(scalar(conn, "SELECT SYS_CONTEXT('USERENV', 'CLIENT_PROGRAM_NAME') FROM dual") == "itest-prog",
            "program");
    enforce(scalar(conn, "SELECT SYS_CONTEXT('USERENV', 'HOST') FROM dual") == "itest-host", "machine");
    enforce(scalar(conn, "SELECT SYS_CONTEXT('USERENV', 'OS_USER') FROM dual") == "itest-user", "OS user");
    enforce(scalar(conn, "SELECT SYS_CONTEXT('USERENV', 'TERMINAL') FROM dual") == "itest-term", "terminal");
    enforce(scalar(conn, "SELECT SESSIONTIMEZONE FROM dual") == "+02:00", "session time zone");
}

/// A dead first address is skipped, in URLs and descriptors.
void testFailover()
{
    import std.conv : to;

    const real_ = ConnectionOptions.fromEasyConnect(environment.get("ORACLE_HOST")).endpoints[0];
    auto o = serverOptions();
    o.hosts = [HostPort("127.0.0.1", 1), real_];
    auto conn = new Connection(o);
    enforce(conn.host == real_, "the second host");
    conn.close();

    const descriptor = "(DESCRIPTION=(CONNECT_TIMEOUT=5)(ADDRESS_LIST=(ADDRESS=(PROTOCOL=tcp)(HOST=127.0.0.1)(PORT=1))"
        ~ "(ADDRESS=(PROTOCOL=tcp)(HOST=" ~ real_.host ~ ")(PORT=" ~ real_.port.to!string ~ ")))"
        ~ "(CONNECT_DATA=(SERVICE_NAME=" ~ serviceName() ~ ")))";
    conn = new Connection(descriptor, userName(), password());
    enforce(scalar(conn, "SELECT 'ok' FROM dual") == "ok", "descriptor failover");
    conn.close();
}

/// A wrong password is ORA-01017 (and stops failover); an unknown service is the listener's ORA-12514.
void testLoginErrors()
{
    import std.algorithm.searching : canFind;

    auto o = serverOptions();
    o.password = "wrong-password";
    auto e = collectException!ServerException(new Connection(o));
    enforce(e !is null && e.code == 1017, e is null ? "no error" : e.msg);

    o = serverOptions();
    o.serviceName = "NO_SUCH_SERVICE";
    auto c = collectException!ConnectionException(new Connection(o));
    enforce(c !is null && c.msg.canFind("12514"), c is null ? "no error" : c.msg);

    o = serverOptions();
    o.user = "no_such_user_x";
    e = collectException!ServerException(new Connection(o));
    enforce(e !is null && e.code == 1017, e is null ? "no error" : e.msg);
}

/// The smallest SDU: requests and responses span many packets; SQL text longer than a CLR chunk.
void testSdu()
{
    auto conn = connectToServer("sdu=512");
    scope (exit)
        conn.close();
    const value = "x".replicate(4000);
    enforce(scalar(conn, "SELECT '" ~ value ~ "' FROM dual") == value, "a 4000-byte value");
    const comment = "/* " ~ "y".replicate(70_000) ~ " */";
    enforce(scalar(conn, "SELECT " ~ comment ~ " 'long sql' FROM dual") == "long sql", "70 KB of SQL text");
    size_t rows;
    foreach (row; conn.query("SELECT LEVEL, RPAD('z', 300, 'z') FROM dual CONNECT BY LEVEL <= 50"))
        rows += row.getString(1).length == 300;
    enforce(rows == 50, "rows over several packets");
}

/// A statement running longer than the receive timeout fails and closes the connection.
void testReceiveTimeout()
{
    auto conn = connectToServer("receive_timeout=1");
    auto e = collectException!ConnectionException(conn.exec("BEGIN DBMS_SESSION.SLEEP(3); END;"));
    enforce(e !is null, "timed out");
    enforce(!conn.isOpen, "the connection is closed");
}

/++
TCPS: with the test CA, with a wrong host name, without the CA, without
verification. Needs `ORACLE_TLS_HOST` and `ORACLE_TLS_CA`; skipped otherwise.
+/
void testTls()
{
    import std.stdio : writeln;

    const host = environment.get("ORACLE_TLS_HOST", "");
    const ca = environment.get("ORACLE_TLS_CA", "");
    if (host.length == 0 || ca.length == 0)
    {
        writeln("  (ORACLE_TLS_HOST / ORACLE_TLS_CA not set: TLS not tested)");
        return;
    }
    auto o = ConnectionOptions.fromEasyConnect("tcps://" ~ host ~ "/" ~ serviceName());
    o.user = userName();
    o.password = password();
    o.tls.caFile = ca;
    auto conn = new Connection(o);
    enforce(scalar(conn, "SELECT 'secure' FROM dual") == "secure", "query over TLS");
    conn.close();

    auto wrongName = o;
    wrongName.tls.serverName = "wrong.example";
    enforce(collectException!ConnectionException(new Connection(wrongName)) !is null, "wrong name refused");

    auto noCa = o;
    noCa.tls.caFile = null;
    enforce(collectException!ConnectionException(new Connection(noCa)) !is null, "unknown CA refused");

    auto skip = noCa;
    skip.tls.skipVerify = true;
    conn = new Connection(skip);
    enforce(scalar(conn, "SELECT 'unverified' FROM dual") == "unverified", "without verification");
    conn.close();

    import std.conv : to;

    const hp = ConnectionOptions.fromEasyConnect(host).endpoints[0];
    const descriptor = "(DESCRIPTION=(ADDRESS=(PROTOCOL=tcps)(HOST=" ~ hp.host ~ ")(PORT=" ~ hp
        .port.to!string
        ~ "))(CONNECT_DATA=(SERVICE_NAME=" ~ serviceName() ~ ")))";
    auto d = ConnectionOptions.fromDescriptor(descriptor);
    d.user = userName();
    d.password = password();
    d.tls.caFile = ca;
    conn = new Connection(d);
    enforce(scalar(conn, "SELECT 'descriptor' FROM dual") == "descriptor", "TCPS descriptor");
    conn.close();
}

/++
Proxy authentication: the test user logs in to a session of `ITEST_PROXIED`
(created with `ALTER USER itest_proxied GRANT CONNECT THROUGH testuser`);
skipped without that user.
+/
void testProxyAuthentication()
{
    import std.stdio : writeln;
    import std.uni : toUpper;

    {
        auto conn = connectToServer();
        scope (exit)
            conn.close();
        if (conn.queryValue!long("SELECT COUNT(*) FROM all_users WHERE username = 'ITEST_PROXIED'") == 0)
        {
            writeln("  (no user ITEST_PROXIED: proxy authentication not tested)");
            return;
        }
    }
    enum sql = "SELECT SYS_CONTEXT('USERENV', 'SESSION_USER'), SYS_CONTEXT('USERENV', 'PROXY_USER') FROM dual";
    void check(Connection conn, string how)
    {
        scope (exit)
            conn.close();
        auto r = conn.query(sql);
        const row = r.front;
        enforce(row.getString(0) == "ITEST_PROXIED" && row.getString(1) == userName().toUpper,
                how ~ ": session user " ~ row.getString(0) ~ ", proxy " ~ row.getString(1));
        r.close();
    }

    auto o = serverOptions();
    o.proxyClient = "itest_proxied";
    check(new Connection(o), "proxyClient");
    o = serverOptions("proxy_client=itest_proxied");
    check(new Connection(o), "proxy_client parameter");
    o = serverOptions();
    o.user = userName() ~ "[itest_proxied]";
    check(new Connection(o), "user[target]");

    // a user that doesn't allow it: refused like a wrong password (ORA-01017)
    o = serverOptions();
    o.proxyClient = "system";
    auto e = collectException!ServerException(new Connection(o));
    enforce(e !is null && e.code == 1017, "not authorized: " ~ (e is null ? "connected" : e.msg));
}

/// Connect aliases from a `tnsnames.ora` (a descriptor and an Easy Connect entry; `config_dir` and `TNS_ADMIN`).
void testTnsAliases()
{
    import std.conv : to;
    import std.file : mkdirRecurse, rmdirRecurse, tempDir, write;
    import std.path : buildPath;
    import dbwire.client.hosts : parseHostPort;

    const hp = parseHostPort(environment.get("ORACLE_HOST", ""));
    const port = hp.port ? hp.port : 1521;
    const dir = buildPath(tempDir, "oracle-native-itest-tns");
    mkdirRecurse(dir);
    scope (exit)
        rmdirRecurse(dir);
    write(buildPath(dir, "tnsnames.ora"), "# test aliases\nITEST_DESC, itest_desc.example =\n  (DESCRIPTION =\n"
            ~ "    (ADDRESS = (PROTOCOL = TCP)(HOST = " ~ hp.host ~ ")(PORT = " ~ port.to!string ~ "))\n"
            ~ "    (CONNECT_DATA = (SERVICE_NAME = " ~ serviceName() ~ ")))\n"
            ~ "itest_ez = " ~ hp.host ~ ":" ~ port.to!string ~ "/" ~ serviceName() ~ "\n");
    foreach (alias_; ["ITEST_DESC", "itest_desc.example", "itest_ez"])
    {
        auto conn = new Connection(alias_ ~ "?config_dir=" ~ dir, userName(), password());
        scope (exit)
            conn.close();
        enforce(conn.queryValue!long("SELECT 1 FROM dual") == 1, alias_);
    }
    auto e = collectException!ClientException(new Connection("itest_nosuch?config_dir=" ~ dir, userName(), password()));
    enforce(e !is null, "an unknown alias");

    const saved = environment.get("TNS_ADMIN", null);
    environment["TNS_ADMIN"] = dir;
    scope (exit)
    {
        if (saved is null)
            environment.remove("TNS_ADMIN");
        else
            environment["TNS_ADMIN"] = saved;
    }
    auto conn = new Connection("itest_ez", userName(), password());
    scope (exit)
        conn.close();
    enforce(conn.queryValue!long("SELECT 1 FROM dual") == 1, "TNS_ADMIN");
}
