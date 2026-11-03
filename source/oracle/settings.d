/++
Connection options and the three forms of connection strings:

$(UL
$(LI URL: `oracle://user:password@host[:port][,host[:port]...]/service?param=value&...`;)
$(LI Easy Connect: `[tcp://|tcps://]host[:port][/service][:server][/instance][?param=value&...]`;)
$(LI connect descriptor: `(DESCRIPTION=(ADDRESS=(PROTOCOL=tcp)(HOST=h)(PORT=1521))(CONNECT_DATA=(SERVICE_NAME=s)))`.)
)

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module oracle.settings;

public import dbwire.client.hosts : HostPort, HostSelection;
import core.time : Duration, seconds;
import dbwire.client.dsn : Dsn, parseEnumValue, parseFlag, parseQuery, parseSeconds;
import dbwire.io.backend : IoMode;
import dbwire.io.transport : TransportFactory;
import dbwire.tls.transport : TlsOptions;
import oracle.exception : ClientException;

/// The listener's default port, and the usual TCPS port.
enum ushort defaultPort = 1521;
/// ditto
enum ushort defaultSecurePort = 2484;

/// Options of a connection.
struct ConnectionOptions
{
    /// Server host name or IP address. Ignored when `hosts` is set.
    string host = "localhost";
    /// Listener port; 0 means 1521, or 2484 with `secure`. Ignored when `hosts` is set.
    ushort port;
    /++
    Several listeners (e.g. RAC nodes, a standby). Connecting tries them as
    `hostSelection` says and uses the first one that answers; a server that
    refuses the login is not skipped. When empty, `host` and `port` are used.
    +/
    HostPort[] hosts;
    /// Order in which `hosts` are tried (`LOAD_BALANCE=on` in a descriptor: random).
    HostSelection hostSelection = HostSelection.inOrder;
    /// The database service name (e.g. `FREEPDB1`); takes precedence over `sid`.
    string serviceName;
    /// The instance's SID, for old configurations without service names.
    string sid;
    /// A specific instance of the service (`INSTANCE_NAME`); empty: any.
    string instanceName;
    /// Server process type (`SERVER`): `dedicated`, `shared` or `pooled`; empty: the listener's default.
    string serverType;
    /// User name.
    string user;
    /// Password.
    string password;

    /++
    TLS (TCPS) from the first byte. The server certificate is verified against
    the trusted CAs (`tls.caFile`, or the system's) and the host name (or
    `tls.serverName`). OpenSSL is loaded when the first secure connection is made.
    +/
    bool secure;
    /// More TLS settings: trusted CAs, the name to verify, client certificates (mTLS).
    TlsOptions tls;

    /// Shown in `V$SESSION.PROGRAM`; empty: the executable's name.
    string program;
    /// Shown in `V$SESSION.MACHINE`; empty: this machine's host name.
    string machine;
    /// Shown in `V$SESSION.OSUSER`; empty: the operating system user.
    string osUser;
    /// Shown in `V$SESSION.TERMINAL`.
    string terminal = "unknown";
    /// The session time zone set at login (`ALTER SESSION SET TIME_ZONE`), e.g. `+00:00` or `Europe/Lisbon`.
    string sessionTimeZone = "+00:00";

    /++
    Commit after each successful statement. Off by default: Oracle
    transactions are explicit, end them with `Connection.commit` or
    `Connection.rollback` (DDL statements commit implicitly).
    +/
    bool autoCommit;
    /++
    Fetch CLOB, NCLOB and BLOB columns as locators (`Value.getLob`: read,
    write, trim them piece by piece) instead of their contents. Off by
    default: their contents come with the rows (`getString`, `getBytes`).
    +/
    bool lobLocators;
    /// Rows fetched per round trip (also returned with a query's execution).
    uint fetchSize = 100;
    /++
    Parsed statements kept per connection (with their server cursors), to run
    them again without parsing; 0 turns the cache off. DDL statements are
    never kept.
    +/
    uint statementCacheSize = 20;
    /// Largest value (string, binary) accepted from the server, in bytes.
    size_t maxValueLength = 1024 * 1024 * 1024;

    /// Session data unit: the largest packet the client asks for (512 to 2 MB; the server may lower it).
    uint sdu = 8192;
    /// Maximum time to connect (TCP, TLS, the listener's answer, the login).
    Duration connectTimeout = 20.seconds;
    /// Maximum time a single socket write may block; `Duration.zero`: no limit.
    Duration sendTimeout = 300.seconds;
    /++
    Maximum time to wait for the next data from the server; `Duration.zero`
    (the default): no limit. The server sends nothing while a statement runs,
    so this limits the statement time.
    +/
    Duration receiveTimeout;

    /// I/O backend selection.
    IoMode ioMode = IoMode.auto_;
    /// Custom transport factory; overrides the backend's connect logic when set.
    TransportFactory transportFactory;

    /++
    Parses any of the three connection string forms: a URL (`oracle://`), a
    connect descriptor (starting with an opening parenthesis), or Easy Connect.

    Throws: `ClientException` if the string is malformed.
    +/
    static ConnectionOptions parse(string text) @safe
    {
        import std.string : startsWith, strip;

        const s = text.strip;
        if (s.startsWith("oracle://"))
            return fromDsn(s);
        if (s.startsWith("("))
            return fromDescriptor(s);
        return fromEasyConnect(s);
    }

    /++
    Parses a URL: `oracle://[user[:password]@]host[:port][,host[:port]...][/service][?param=value&...]`.

    User, password and values may be percent-encoded; IPv6 addresses go in
    brackets. Parameters are those of `fromParams`.

    Throws: `ClientException` if the string is malformed or a parameter is unknown or invalid.
    +/
    static ConnectionOptions fromDsn(string dsn) @safe
    {
        const parsed = Dsn.parse(dsn, "oracle");
        string[string] params;
        foreach (key, value; parsed.params)
            params[key] = value;
        auto o = fromParams(params);
        if (parsed.hasUser)
            o.user = parsed.user;
        if (parsed.hasPassword)
            o.password = parsed.password;
        if (parsed.hosts.length)
            o.hosts = parsed.hosts.dup;
        if (parsed.path.length)
            o.serviceName = parsed.path;
        return o;
    }

    /++
    Parses Easy Connect: `[tcp://|tcps://]host[:port][/service][:server][/instance][?param=value&...]`.

    Throws: `ClientException` if the string is malformed or a parameter is unknown or invalid.
    +/
    static ConnectionOptions fromEasyConnect(string text) @safe
    {
        import std.algorithm.searching : findSplit;
        import std.string : indexOf, startsWith, toLower;
        import dbwire.client.hosts : parseHostPort;

        string s = text;
        string[string] params;
        if (auto q = s.findSplit("?"))
        {
            s = q[0];
            params = parseQuery(q[2], "Easy Connect");
        }
        bool tcps;
        if (auto p = s.findSplit("://"))
        {
            const protocol = p[0].toLower;
            if (protocol != "tcp" && protocol != "tcps")
                throw new ClientException("Unsupported protocol '" ~ p[0] ~ "' in '" ~ text ~ "'");
            tcps = protocol == "tcps";
            s = p[2];
        }
        // the address part ends at the first '/' outside brackets
        size_t slash = s.length;
        bool inBrackets;
        foreach (i, c; s)
        {
            if (c == '[')
                inBrackets = true;
            else if (c == ']')
                inBrackets = false;
            else if (c == '/' && !inBrackets)
            {
                slash = i;
                break;
            }
        }
        const address = s[0 .. slash];
        if (address.length == 0)
            throw new ClientException("No host in '" ~ text ~ "'");
        auto o = fromParams(params);
        if (tcps)
            o.secure = true;
        o.hosts = null;
        foreach (part; splitList(address))
            o.hosts ~= parseHostPort(part);
        if (slash < s.length)
        {
            string rest = s[slash + 1 .. $];
            if (auto i = rest.findSplit("/"))
            {
                o.instanceName = i[2];
                rest = i[0];
            }
            if (auto t = rest.findSplit(":"))
            {
                o.serverType = t[2].toLower;
                rest = t[0];
            }
            o.serviceName = rest;
        }
        return o;
    }

    /++
    Parses a connect descriptor, e.g.
    `(DESCRIPTION=(ADDRESS_LIST=(LOAD_BALANCE=on)(ADDRESS=(PROTOCOL=tcp)(HOST=a)(PORT=1521))(ADDRESS=(PROTOCOL=tcp)(HOST=b)(PORT=1521)))(CONNECT_DATA=(SERVICE_NAME=orcl)))`.

    Known: `ADDRESS` (`PROTOCOL` tcp/tcps, `HOST`, `PORT`), `ADDRESS_LIST`,
    `LOAD_BALANCE`, `CONNECT_DATA` (`SERVICE_NAME`, `SID`, `INSTANCE_NAME`,
    `SERVER`), `SECURITY` (`SSL_SERVER_CERT_DN` is not supported yet), `SDU`,
    `CONNECT_TIMEOUT`, `TRANSPORT_CONNECT_TIMEOUT`; other entries are ignored.
    All addresses must use the same protocol.

    Throws: `ClientException` if the descriptor is malformed.
    +/
    static ConnectionOptions fromDescriptor(string text) @safe
    {
        import std.conv : ConvException, to;
        import std.string : toLower;

        const root = DescriptorNode.parse(text);
        const description = root.key == "DESCRIPTION" ? root : root.child("DESCRIPTION");
        if (description is null)
            throw new ClientException("No DESCRIPTION in '" ~ text ~ "'");
        ConnectionOptions o;
        o.hosts = null;
        bool anyTcps, anyTcp;
        void address(const DescriptorNode a)
        {
            const protocol = a.value("PROTOCOL", "tcp").toLower;
            if (protocol != "tcp" && protocol != "tcps")
                throw new ClientException("Unsupported protocol '" ~ protocol ~ "' in the connect descriptor");
            (protocol == "tcps" ? anyTcps : anyTcp) = true;
            HostPort h;
            h.host = a.value("HOST");
            if (h.host.length == 0)
                throw new ClientException("An ADDRESS without a HOST in the connect descriptor");
            const port = a.value("PORT");
            if (port.length)
            {
                try
                    h.port = port.to!ushort;
                catch (ConvException)
                    throw new ClientException("Invalid PORT '" ~ port ~ "' in the connect descriptor");
            }
            o.hosts ~= h;
        }

        bool loadBalance = isOn(description.value("LOAD_BALANCE"));
        foreach (c; description.children)
        {
            if (c.key == "ADDRESS")
                address(c);
            else if (c.key == "ADDRESS_LIST")
            {
                loadBalance = loadBalance || isOn(c.value("LOAD_BALANCE"));
                foreach (a; c.children)
                    if (a.key == "ADDRESS")
                        address(a);
            }
        }
        if (o.hosts.length == 0)
            throw new ClientException("No ADDRESS in the connect descriptor");
        if (anyTcp && anyTcps)
            throw new ClientException("The connect descriptor mixes TCP and TCPS addresses");
        o.secure = anyTcps;
        o.hostSelection = loadBalance ? HostSelection.random : HostSelection.inOrder;
        if (auto cd = description.child("CONNECT_DATA"))
        {
            o.serviceName = cd.value("SERVICE_NAME");
            o.sid = cd.value("SID");
            o.instanceName = cd.value("INSTANCE_NAME");
            o.serverType = cd.value("SERVER").toLower;
        }
        if (auto sec = description.child("SECURITY"))
            if (sec.value("SSL_SERVER_CERT_DN").length)
                throw new ClientException("SSL_SERVER_CERT_DN is not supported yet");
        const sdu = description.value("SDU");
        if (sdu.length)
            o.sdu = parseSdu(sdu);
        const timeout = description.value("TRANSPORT_CONNECT_TIMEOUT", description.value("CONNECT_TIMEOUT"));
        if (timeout.length)
            o.connectTimeout = parseSeconds("CONNECT_TIMEOUT", timeout);
        return o;
    }

    /++
    Builds options from key/value parameters, as in the query part of a URL or
    Easy Connect string.

    Keys: `host`, `port`, `service_name`, `sid`, `instance_name`, `server`,
    `user`, `password`, `secure`/`tcps` (flag), `tls_ca_file`/`ssl_ca`,
    `tls_cert_file`, `tls_key_file`, `tls_server_name`, `tls_skip_verify`,
    `program`, `machine`, `osuser`, `terminal`, `time_zone`, `sdu`,
    `auto_commit` (flag), `fetch_size`, `statement_cache_size`, `lob_locators` (flag),
    `connect_timeout`, `transport_connect_timeout`, `send_timeout`,
    `receive_timeout` (seconds), `host_selection` (`in_order`, `random`,
    `round_robin`), `load_balance` (flag), `io_mode` (`auto_`, `phobos`, `vibe`).
    `pool_*` keys are for the pool (`PoolOptions.fromParams`) and ignored here.

    Throws: `ClientException` for unknown keys or invalid values.
    +/
    static ConnectionOptions fromParams(const string[string] params) @safe
    {
        import std.conv : ConvException, to;
        import std.string : toLower;

        ConnectionOptions o;
        foreach (key, value; params)
        {
            import std.algorithm.searching : startsWith;

            if (key.toLower.startsWith("pool_"))
                continue; // for the pool (PoolOptions.fromParams)
            switch (key.toLower)
            {
            case "host":
                o.host = value;
                break;
            case "port":
                try
                    o.port = value.to!ushort;
                catch (ConvException)
                    throw new ClientException("Invalid port '" ~ value ~ "'");
                break;
            case "service_name":
            case "service":
                o.serviceName = value;
                break;
            case "sid":
                o.sid = value;
                break;
            case "instance_name":
                o.instanceName = value;
                break;
            case "server":
            case "server_type":
                o.serverType = value.toLower;
                break;
            case "user":
                o.user = value;
                break;
            case "password":
                o.password = value;
                break;
            case "secure":
            case "tcps":
                o.secure = parseFlag(key, value);
                break;
            case "tls_ca_file":
            case "ssl_ca":
                o.tls.caFile = value;
                break;
            case "tls_cert_file":
                o.tls.certFile = value;
                break;
            case "tls_key_file":
                o.tls.keyFile = value;
                break;
            case "tls_server_name":
                o.tls.serverName = value;
                break;
            case "tls_skip_verify":
                o.tls.skipVerify = parseFlag(key, value);
                break;
            case "ssl_server_dn_match":
                // DN matching by host name is what certificate verification does; "off" skips only the name check
                if (!parseFlag(key, value))
                    throw new ClientException("ssl_server_dn_match=off is not supported (use tls_server_name)");
                break;
            case "ssl_server_cert_dn":
                throw new ClientException("ssl_server_cert_dn is not supported yet");
            case "program":
                o.program = value;
                break;
            case "machine":
                o.machine = value;
                break;
            case "osuser":
                o.osUser = value;
                break;
            case "terminal":
                o.terminal = value;
                break;
            case "time_zone":
                o.sessionTimeZone = value;
                break;
            case "sdu":
                o.sdu = parseSdu(value);
                break;
            case "lob_locators":
                o.lobLocators = parseFlag(key, value);
                break;
            case "statement_cache_size":
                try
                    o.statementCacheSize = value.to!uint;
                catch (ConvException)
                    throw new ClientException("Invalid statement cache size '" ~ value ~ "'");
                break;
            case "auto_commit":
            case "autocommit":
                o.autoCommit = parseFlag(key, value);
                break;
            case "fetch_size":
            case "arraysize":
                try
                    o.fetchSize = value.to!uint;
                catch (ConvException)
                    throw new ClientException("Invalid fetch size '" ~ value ~ "'");
                if (o.fetchSize == 0)
                    throw new ClientException("The fetch size must be at least 1");
                break;
            case "connect_timeout":
            case "transport_connect_timeout":
                o.connectTimeout = parseSeconds(key, value);
                break;
            case "send_timeout":
                o.sendTimeout = parseSeconds(key, value);
                break;
            case "receive_timeout":
                o.receiveTimeout = parseSeconds(key, value);
                break;
            case "host_selection":
                o.hostSelection = parseEnumValue!HostSelection(key, value);
                break;
            case "load_balance":
                o.hostSelection = parseFlag(key, value) ? HostSelection.random : HostSelection.inOrder;
                break;
            case "io_mode":
                o.ioMode = parseEnumValue!IoMode(key, value);
                break;
            default:
                throw new ClientException("Unknown connection parameter '" ~ key ~ "'");
            }
        }
        return o;
    }

    /// The port to connect to: `port`, or the default for the protocol when 0.
    ushort effectivePort(ushort p) const @safe pure nothrow
    {
        return p ? p : secure ? defaultSecurePort : defaultPort;
    }

    /// The hosts to try, with effective ports.
    HostPort[] endpoints() const @safe
    {
        auto list = hosts.length ? hosts.dup : [HostPort(host, port)];
        foreach (ref h; list)
            h.port = effectivePort(h.port);
        return list;
    }

    /++
    The connect descriptor sent to the listener for `endpoint`, with the
    client identification (`CID`).
    +/
    string connectDescriptor(HostPort endpoint, string clientProgram, string clientHost, string clientUser) const @safe
    {
        import std.conv : to;

        string data = "(CONNECT_DATA=";
        if (serviceName.length)
            data ~= "(SERVICE_NAME=" ~ quoteValue(serviceName) ~ ")";
        else if (sid.length)
            data ~= "(SID=" ~ quoteValue(sid) ~ ")";
        if (instanceName.length)
            data ~= "(INSTANCE_NAME=" ~ quoteValue(instanceName) ~ ")";
        if (serverType.length)
            data ~= "(SERVER=" ~ quoteValue(serverType) ~ ")";
        data ~= "(CID=(PROGRAM=" ~ quoteValue(clientProgram) ~ ")(HOST=" ~ quoteValue(
                clientHost) ~ ")(USER="
            ~ quoteValue(clientUser) ~ ")))";
        return "(DESCRIPTION=(ADDRESS=(PROTOCOL=" ~ (secure ? "tcps" : "tcp") ~ ")(HOST=" ~ quoteValue(
                endpoint.host) ~ ")(PORT=" ~ endpoint.port.to!string ~ "))" ~ data ~ ")";
    }
}

/// One `(KEY=value)` or `(KEY=(...)(...))` entry of a connect descriptor.
final class DescriptorNode
{
    /// The key, upper case.
    string key;
    /// The value of a leaf entry.
    string text;
    /// The entries of a list.
    DescriptorNode[] children;

    /++
    Parses one entry (with its parentheses).

    Throws: `ClientException` if the text is malformed.
    +/
    static DescriptorNode parse(string s) @safe
    {
        size_t pos;
        auto node = parseAt(s, pos);
        skipSpace(s, pos);
        if (pos != s.length)
            throw new ClientException("Unexpected text after the connect descriptor: '" ~ s[pos .. $] ~ "'");
        return node;
    }

    /// The first child with `key`, or null.
    inout(DescriptorNode) child(string key) inout @safe pure nothrow
    {
        foreach (c; children)
            if (c.key == key)
                return c;
        return null;
    }

    /// The text of the first child with `key`, or `default_`.
    string value(string key, string default_ = null) const @safe pure nothrow
    {
        foreach (c; children)
            if (c.key == key && c.children.length == 0)
                return c.text;
        return default_;
    }

    private static void skipSpace(string s, ref size_t pos) @safe pure nothrow
    {
        while (pos < s.length && (s[pos] == ' ' || s[pos] == '\t' || s[pos] == '\r' || s[pos] == '\n'))
            pos++;
    }

    private static DescriptorNode parseAt(string s, ref size_t pos) @safe
    {
        import std.string : strip, toUpper;

        skipSpace(s, pos);
        if (pos >= s.length || s[pos] != '(')
            throw new ClientException("Expected '(' in the connect descriptor at position " ~ toText(pos));
        pos++;
        const keyStart = pos;
        while (pos < s.length && s[pos] != '=' && s[pos] != ')' && s[pos] != '(')
            pos++;
        if (pos >= s.length || s[pos] != '=')
            throw new ClientException("Expected '=' in the connect descriptor at position " ~ toText(pos));
        auto node = new DescriptorNode;
        node.key = s[keyStart .. pos].strip.toUpper;
        pos++;
        skipSpace(s, pos);
        if (pos < s.length && s[pos] == '(')
        {
            while (true)
            {
                skipSpace(s, pos);
                if (pos < s.length && s[pos] == '(')
                    node.children ~= parseAt(s, pos);
                else
                    break;
            }
        }
        else if (pos < s.length && s[pos] == '"')
        {
            const start = ++pos;
            while (pos < s.length && s[pos] != '"')
                pos++;
            if (pos >= s.length)
                throw new ClientException("Unterminated quoted value in the connect descriptor");
            node.text = s[start .. pos++];
            skipSpace(s, pos);
        }
        else
        {
            const start = pos;
            while (pos < s.length && s[pos] != ')' && s[pos] != '(')
                pos++;
            node.text = s[start .. pos].strip;
        }
        if (pos >= s.length || s[pos] != ')')
            throw new ClientException("Expected ')' in the connect descriptor at position " ~ toText(pos));
        pos++;
        return node;
    }
}

private bool isOn(string v) @safe pure
{
    import std.string : toLower;

    const s = v.toLower;
    return s == "on" || s == "yes" || s == "true";
}

private uint parseSdu(string v) @safe
{
    import std.conv : ConvException, to;

    uint n;
    try
        n = v.to!uint;
    catch (ConvException)
        throw new ClientException("Invalid SDU '" ~ v ~ "'");
    if (n < 512 || n > 2_097_152)
        throw new ClientException("SDU " ~ v ~ " is outside 512 .. 2097152");
    return n;
}

/// Splits `a,b,[::1]:5` at commas outside brackets.
private string[] splitList(string s) @safe pure
{
    string[] parts;
    size_t start;
    bool inBrackets;
    foreach (i, c; s)
    {
        if (c == '[')
            inBrackets = true;
        else if (c == ']')
            inBrackets = false;
        else if (c == ',' && !inBrackets)
        {
            parts ~= s[start .. i];
            start = i + 1;
        }
    }
    parts ~= s[start .. $];
    return parts;
}

/// Quotes a descriptor value if it contains characters with a meaning in descriptors.
private string quoteValue(string v) @safe pure
{
    import std.algorithm.searching : any;

    if (v.any!(c => c == '(' || c == ')' || c == '=' || c == '"' || c == ' '))
    {
        import std.array : replace;

        return '"' ~ v.replace("\"", "") ~ '"';
    }
    return v;
}

private string toText(T)(T v) @safe pure
{
    import std.conv : to;

    return v.to!string;
}

///
@safe unittest
{
    auto o = ConnectionOptions.parse("oracle://scott:ti%40ger@db1:1522,db2/ORCLPDB?connect_timeout=5&time_zone=UTC");
    assert(o.user == "scott" && o.password == "ti@ger" && o.serviceName == "ORCLPDB");
    assert(o.endpoints == [HostPort("db1", 1522), HostPort("db2", 1521)]);
    assert(o.connectTimeout == 5.seconds && o.sessionTimeZone == "UTC");

    o = ConnectionOptions.parse("tcps://db.example.com/sales:dedicated/inst2?tls_ca_file=ca.pem");
    assert(o.secure && o.endpoints == [HostPort("db.example.com", 2484)] && o.serviceName == "sales");
    assert(o.serverType == "dedicated" && o.instanceName == "inst2" && o.tls.caFile == "ca.pem");

    o = ConnectionOptions.parse("[::1]:1600/FREEPDB1");
    assert(o.endpoints == [HostPort("::1", 1600)] && o.serviceName == "FREEPDB1");

    o = ConnectionOptions.parse("(DESCRIPTION=(SDU=16384)(ADDRESS_LIST=(LOAD_BALANCE=on)"
            ~ "(ADDRESS=(PROTOCOL=TCP)(HOST=a)(PORT=1521))(ADDRESS=(PROTOCOL=tcp)(HOST=b)))"
            ~ "(CONNECT_DATA=(SID=XE)(SERVER=DEDICATED)))");
    assert(o.endpoints == [HostPort("a", 1521), HostPort("b", 1521)] && o.hostSelection == HostSelection.random);
    assert(o.sid == "XE" && o.serverType == "dedicated" && o.sdu == 16_384 && !o.secure);
    assert(o.connectDescriptor(HostPort("a", 1521), "app", "pc", "me")
            == "(DESCRIPTION=(ADDRESS=(PROTOCOL=tcp)(HOST=a)(PORT=1521))"
            ~ "(CONNECT_DATA=(SID=XE)(SERVER=dedicated)(CID=(PROGRAM=app)(HOST=pc)(USER=me))))");
}

@safe unittest
{
    import std.exception : assertThrown;

    assertThrown!ClientException(ConnectionOptions.parse("oracle://h/s?bogus=1"));
    assertThrown!ClientException(ConnectionOptions.parse("(DESCRIPTION=(ADDRESS=(PROTOCOL=tcp)(HOST=a)"));
    assertThrown!ClientException(ConnectionOptions.parse("(DESCRIPTION=(CONNECT_DATA=(SERVICE_NAME=x)))"));
    assertThrown!ClientException(ConnectionOptions.parse("ipc://x/y"));
    assertThrown!ClientException(ConnectionOptions.parse("h/s?sdu=10"));
}
