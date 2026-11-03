/++
The test server: `ORACLE_HOST` (`host` or `host:port`), `ORACLE_SERVICE`
(default `FREEPDB1`), `ORACLE_USER` (default `testuser`), `ORACLE_PASSWORD`.

TLS tests need a TCPS endpoint: `ORACLE_TLS_HOST` (`host:port`) and
`ORACLE_TLS_CA` (the CA certificate file); they are skipped without them.
+/
module integrationtests.server;

import std.process : environment;
import std.uri : encodeComponent;

import oracle;

/// Whether a server is configured.
bool serverConfigured()
{
    return environment.get("ORACLE_HOST", "").length > 0;
}

/// The service name of the test database.
string serviceName()
{
    return environment.get("ORACLE_SERVICE", "FREEPDB1");
}

/// The test user and password.
string userName()
{
    return environment.get("ORACLE_USER", "testuser");
}

/// ditto
string password()
{
    return environment.get("ORACLE_PASSWORD", "");
}

/// The URL for the test server, with extra `params` (`key=value&...`).
string serverDsn(string params = null)
{
    return "oracle://" ~ encodeComponent(userName()) ~ ":" ~ encodeComponent(
            password()) ~ "@"
        ~ environment.get("ORACLE_HOST", "") ~ "/" ~ serviceName() ~ (params.length ? "?" ~ params : "");
}

/// Options for the test server.
ConnectionOptions serverOptions(string params = null)
{
    return ConnectionOptions.fromDsn(serverDsn(params));
}

/// Connects to the test server.
Connection connectToServer(string params = null)
{
    return new Connection(serverOptions(params));
}

/// The first value of the first row of `sql` as text.
string scalar(Connection conn, string sql)
{
    auto r = conn.query(sql);
    scope (exit)
        r.close();
    if (r.empty)
        return null;
    return r.front.getString(0);
}

/// Drops a table if it exists.
void dropTable(Connection conn, string name)
{
    try
        conn.exec("DROP TABLE " ~ name ~ " PURGE");
    catch (ServerException e)
        if (e.code != 942)
            throw e;
}
