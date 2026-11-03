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
    /++
    User name. `proxy[target]` logs in as `proxy` (with `proxy`'s password)
    to a session of user `target` (proxy authentication, see `proxyClient`).
    +/
    string user;
    /// Password.
    string password;
    /++
    Proxy authentication: the user the session runs as (`PROXY_CLIENT_NAME`).
    `user` and `password` are then those of the proxy user, which the target
    user must allow: `ALTER USER target GRANT CONNECT THROUGH proxy`. Also
    written `proxy[target]` in `user`.
    +/
    string proxyClient;

    /++
    The user that logs in and the proxy client: `user` split at `[...]`, or
    `user` and `proxyClient`.

    Throws: `ClientException` if both name a different proxy client.
    +/
    void loginUsers(out string login, out string client) const @safe pure
    {
        import std.string : indexOf;

        login = user;
        client = proxyClient;
        const open = user.indexOf('[');
        if (open < 0 || user.length < 2 || user[$ - 1] != ']')
            return;
        login = user[0 .. open];
        const named = user[open + 1 .. $ - 1];
        if (client.length && client != named)
            throw new ClientException("Two proxy clients given: '" ~ named ~ "' and '" ~ client ~ "'");
        client = named;
    }

    /++
    TLS (TCPS) from the first byte. The server certificate is verified against
    the trusted CAs (`tls.caFile`, or the system's) and the host name (or
    `tls.serverName`). OpenSSL is loaded when the first secure connection is made.
    +/
    bool secure;
    /// More TLS settings: trusted CAs, the name to verify, client certificates (mTLS).
    TlsOptions tls;
    /++
    The directory of an Oracle wallet in PEM form (`ewallet.pem`, as `orapki
    wallet pem_asn1` writes it): its certificates are the trusted CAs (unless
    `tls.caFile` is set), and if it has a private key, its certificate is the
    client certificate (mutual TLS) unless `tls.certFile` is set. `SYSTEM`:
    no wallet (the system's CAs).
    +/
    string walletLocation;
    /// The password of the wallet's private key (when it is encrypted).
    string walletPassword;
    /++
    The subject the server certificate must have (`SSL_SERVER_CERT_DN`),
    e.g. `CN=db.example.com,O=Example,C=US`; checked instead of the host name
    (the attributes in any order). The certificate chain is still verified.
    +/
    string serverCertDn;

    /++
    The TLS options of a connection: `tls` with the wallet applied, and with
    the host-name check left to the DN check when `serverCertDn` is set.

    Throws: `ClientException` if the wallet directory has no `ewallet.pem`.
    +/
    TlsOptions effectiveTls() const @safe
    {
        import std.file : exists, readText;
        import std.path : buildPath;
        import std.string : indexOf;
        import std.uni : toUpper;

        // a copy (the cast drops const from this struct value; its one array is duplicated)
        TlsOptions t = (() @trusted => cast() tls)();
        t.alpn = tls.alpn.dup;
        if (serverCertDn.length)
            t.skipNameCheck = true;
        if (walletLocation.length == 0 || walletLocation.toUpper == "SYSTEM")
            return t;
        const pem = buildPath(walletLocation, "ewallet.pem");
        if (!(()@trusted => exists(pem))())
            throw new ClientException("No wallet file " ~ pem ~ " (a PEM wallet is needed: orapki wallet pem_asn1)");
        if (t.caFile.length == 0)
            t.caFile = pem;
        string text;
        try
            text = (() @trusted => readText(pem))();
        catch (Exception e)
            throw new ClientException("Cannot read the wallet " ~ pem ~ ": " ~ e.msg);
        if (t.certFile.length == 0 && text.indexOf("PRIVATE KEY-----") >= 0)
        {
            t.certFile = pem;
            t.keyFile = null;
            t.keyPassword = walletPassword;
        }
        return t;
    }

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

    /++
    The directory with `tnsnames.ora`, for connect aliases (`parse("SALES")`);
    empty: `$TNS_ADMIN`, else `$ORACLE_HOME/network/admin`.
    +/
    string configDir;

    /// I/O backend selection.
    IoMode ioMode = IoMode.auto_;
    /// Custom transport factory; overrides the backend's connect logic when set.
    TransportFactory transportFactory;

    /++
    Parses any of the connection string forms: a URL (`oracle://`), a
    connect descriptor (starting with an opening parenthesis), a connect
    alias from `tnsnames.ora` (a name such as `SALES`, optionally followed by
    parameters: `SALES?config_dir=/etc/oracle&fetch_size=500`; see
    `oracle.tnsnames` for where the file is looked for), or Easy Connect. A
    name is taken as a host name when no `tnsnames.ora` is found.

    Throws: `ClientException` if the string is malformed, or if a
    `tnsnames.ora` is found without the alias.
    +/
    static ConnectionOptions parse(string text) @safe
    {
        import std.algorithm.searching : findSplit;
        import std.string : strip;
        import oracle.tnsnames : findConfigDir, isAliasName, readTnsNames;

        const s = text.strip;
        auto q = s.findSplit("?");
        if (isAliasName(q[0]))
        {
            const params = q[1].length ? parseQuery(q[2], "connect alias") : null;
            const dir = findConfigDir(params.get("config_dir", null));
            if (dir !is null)
            {
                auto o = parseDirect(readTnsNames(dir).lookup(q[0]));
                o.applyParams(params);
                o.configDir = dir;
                return o;
            }
        }
        return parseDirect(s);
    }

    /// `parse` without aliases.
    private static ConnectionOptions parseDirect(string s) @safe
    {
        import std.string : startsWith, strip;

        s = s.strip;
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
    `SERVER`), `SECURITY` (`SSL_SERVER_CERT_DN`, `SSL_SERVER_DN_MATCH`,
    `MY_WALLET_DIRECTORY` / `WALLET_LOCATION`), `SDU`,
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
        {
            o.serverCertDn = sec.value("SSL_SERVER_CERT_DN");
            const wallet = sec.value("MY_WALLET_DIRECTORY", sec.value("WALLET_LOCATION"));
            if (wallet.length)
                o.walletLocation = wallet;
            const dnMatch = sec.value("SSL_SERVER_DN_MATCH");
            if (dnMatch.length && !parseOnOff("SSL_SERVER_DN_MATCH", dnMatch))
                o.tls.skipNameCheck = true;
        }
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
    `user`, `password`, `proxy_client`, `secure`/`tcps` (flag), `tls_ca_file`/`ssl_ca`,
    `tls_cert_file`, `tls_key_file`, `tls_server_name`, `tls_skip_verify`,
    `wallet_location` (`my_wallet_directory`), `wallet_password`,
    `ssl_server_cert_dn`, `ssl_server_dn_match` (flag),
    `program`, `machine`, `osuser`, `terminal`, `time_zone`, `sdu`,
    `auto_commit` (flag), `fetch_size`, `statement_cache_size`, `lob_locators` (flag),
    `connect_timeout`, `transport_connect_timeout`, `send_timeout`,
    `receive_timeout` (seconds), `host_selection` (`in_order`, `random`,
    `round_robin`), `load_balance` (flag), `io_mode` (`auto_`, `phobos`, `vibe`),
    `config_dir` (where `tnsnames.ora` is).
    `pool_*` keys are for the pool (`PoolOptions.fromParams`) and ignored here.

    Throws: `ClientException` for unknown keys or invalid values.
    +/
    static ConnectionOptions fromParams(const string[string] params) @safe
    {
        ConnectionOptions o;
        o.applyParams(params);
        return o;
    }

    /// Sets the options named in `params` (as `fromParams` reads them), keeping the others.
    void applyParams(const string[string] params) @safe
    {
        import std.conv : ConvException, to;
        import std.string : toLower;

        alias o = this;
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
            case "proxy_client":
            case "proxy_client_name":
                o.proxyClient = value;
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
                // on: the host name (or ssl_server_cert_dn) is checked; off: only the certificate chain
                o.tls.skipNameCheck = !parseOnOff(key, value);
                break;
            case "ssl_server_cert_dn":
                o.serverCertDn = value;
                break;
            case "wallet_location":
            case "my_wallet_directory":
                o.walletLocation = value;
                break;
            case "wallet_password":
                o.walletPassword = value;
                break;
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
            case "config_dir":
                o.configDir = value;
                break;
            default:
                throw new ClientException("Unknown connection parameter '" ~ key ~ "'");
            }
        }
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

/// Proxy authentication: `proxy[target]` in the user name, or `proxy_client`.
@safe unittest
{
    import std.exception : assertThrown;

    string login, client;
    auto o = ConnectionOptions.parse("oracle://app%5Bjane%5D:secret@db/SALES");
    o.loginUsers(login, client);
    assert(login == "app" && client == "jane" && o.password == "secret");
    o = ConnectionOptions.parse("oracle://app:secret@db/SALES?proxy_client=jane");
    o.loginUsers(login, client);
    assert(login == "app" && client == "jane");
    o.user = "app[jane]";
    o.loginUsers(login, client); // the same client twice is fine
    assert(login == "app" && client == "jane");
    o.proxyClient = "john";
    assertThrown!ClientException(o.loginUsers(login, client));
    o = ConnectionOptions.parse("oracle://plain:pw@db/SALES");
    o.loginUsers(login, client);
    assert(login == "plain" && client is null);
}

/// Connect aliases from `tnsnames.ora`.
@safe unittest
{
    import std.exception : assertThrown;
    import std.file : mkdirRecurse, rmdirRecurse, tempDir, write;
    import std.path : buildPath;

    const dir = buildPath(tempDir, "oracle-native-alias-test");
    (() @trusted {
        mkdirRecurse(dir);
        write(buildPath(dir, "tnsnames.ora"), "sales = (DESCRIPTION=(ADDRESS=(PROTOCOL=tcp)(HOST=db1)(PORT=1522))"
            ~ "(CONNECT_DATA=(SERVICE_NAME=SALES)))\nhr = db2/HR?fetch_size=50\n");
    })();
    scope (exit)
        (() @trusted => rmdirRecurse(dir))();
    auto o = ConnectionOptions.parse("SALES?config_dir=" ~ dir ~ "&fetch_size=7");
    assert(o.hosts == [HostPort("db1", 1522)] && o.serviceName == "SALES" && o.fetchSize == 7 && o.configDir == dir);
    o = ConnectionOptions.parse("hr?config_dir=" ~ dir);
    assert(o.hosts == [HostPort("db2", 0)] && o.serviceName == "HR" && o.fetchSize == 50);
    assertThrown!ClientException(ConnectionOptions.parse("nosuch?config_dir=" ~ dir));
    // without a tnsnames.ora, a name is a host
    o = ConnectionOptions.parse("dbhost?config_dir=" ~ buildPath(dir, "none"));
    assert(o.hosts == [HostPort("dbhost", 0)]);
}

/// An Oracle switch: `on`/`yes`/`true`/`1` or `off`/`no`/`false`/`0`.
private bool parseOnOff(string key, string value) @safe
{
    import std.uni : toLower;

    switch (value.toLower)
    {
    case "on":
    case "yes":
    case "true":
    case "1":
        return true;
    case "off":
    case "no":
    case "false":
    case "0":
        return false;
    default:
        throw new ClientException("Invalid value '" ~ value ~ "' for '" ~ key ~ "' (on or off expected)");
    }
}

/++
Whether two distinguished names are the same: the same attribute/value pairs
in any order, attribute names without regard to case (`CN=db, O=Example` and
`o=Example,cn=db` are). Values may be quoted or have backslash escapes.
+/
bool sameDistinguishedName(string a, string b) @safe pure
{
    import std.algorithm.sorting : sort;

    auto x = dnPairs(a);
    auto y = dnPairs(b);
    sort(x);
    sort(y);
    return x == y;
}

/// The attribute/value pairs of a distinguished name (`CN=a,O=b`; `+` joins attributes of one RDN too).
private string[2][] dnPairs(string dn) @safe pure
{
    import std.string : strip;
    import std.uni : toUpper;

    string[2][] result;
    string part;
    bool quoted, escaped;
    void finish()
    {
        const s = part.strip;
        part = null;
        if (s.length == 0)
            return;
        size_t eq = s.length;
        foreach (i, c; s)
            if (c == '=')
            {
                eq = i;
                break;
            }
        if (eq == s.length)
        {
            result ~= [s.toUpper, ""];
            return;
        }
        string value = s[eq + 1 .. $].strip;
        if (value.length >= 2 && value[0] == '"' && value[$ - 1] == '"')
            value = value[1 .. $ - 1];
        string unescaped;
        bool backslash;
        foreach (c; value)
        {
            if (!backslash && c == '\\')
            {
                backslash = true;
                continue;
            }
            backslash = false;
            unescaped ~= c;
        }
        result ~= [s[0 .. eq].strip.toUpper, unescaped];
    }

    foreach (c; dn)
    {
        if (escaped)
        {
            part ~= c;
            escaped = false;
            continue;
        }
        if (c == '\\')
        {
            part ~= c;
            escaped = true;
            continue;
        }
        if (c == '"')
            quoted = !quoted;
        if (!quoted && (c == ',' || c == '+' || c == ';'))
        {
            finish();
            continue;
        }
        part ~= c;
    }
    finish();
    return result;
}

///
@safe unittest
{
    assert(sameDistinguishedName("CN=db.example.com,O=Example,C=US", "c=US, o=Example, cn=db.example.com"));
    assert(sameDistinguishedName(`CN=a\,b,O="x, y"`, `O=x\, y,CN="a,b"`));
    assert(!sameDistinguishedName("CN=db,O=Example", "CN=db"));
    assert(!sameDistinguishedName("CN=db,O=Example", "CN=db,O=example")); // values are compared exactly
}

/// Wallets and SSL_SERVER_CERT_DN.
@safe unittest
{
    import std.exception : assertThrown;
    import std.file : mkdirRecurse, rmdirRecurse, tempDir, write;
    import std.path : buildPath;

    auto o = ConnectionOptions.parse("(DESCRIPTION=(ADDRESS=(PROTOCOL=tcps)(HOST=db)(PORT=2484))"
            ~ "(SECURITY=(SSL_SERVER_CERT_DN=\"CN=db,O=Example\")(MY_WALLET_DIRECTORY=/w))"
            ~ "(CONNECT_DATA=(SERVICE_NAME=S)))");
    assert(o.secure && o.serverCertDn == "CN=db,O=Example" && o.walletLocation == "/w");
    o = ConnectionOptions.parse("oracle://db/S?secure=true&ssl_server_dn_match=off&wallet_location=SYSTEM");
    assert(o.tls.skipNameCheck && o.effectiveTls().caFile is null);

    const dir = buildPath(tempDir, "oracle-native-wallet-test");
    (() @trusted {
        mkdirRecurse(dir);
        write(buildPath(dir, "ewallet.pem"), "-----BEGIN CERTIFICATE-----\nAA==\n-----END CERTIFICATE-----\n");
    })();
    scope (exit)
        (() @trusted => rmdirRecurse(dir))();
    o = ConnectionOptions.parse("oracle://db/S?secure=true&wallet_location=" ~ dir ~ "&ssl_server_cert_dn=CN%3Ddb");
    auto t = o.effectiveTls();
    assert(t.caFile == buildPath(dir, "ewallet.pem") && t.certFile is null && t.skipNameCheck);
    (() @trusted => write(buildPath(dir, "ewallet.pem"),
            "-----BEGIN ENCRYPTED PRIVATE KEY-----\nAA==\n-----END ENCRYPTED PRIVATE KEY-----\n"))();
    o.walletPassword = "pw";
    t = o.effectiveTls();
    assert(t.certFile == buildPath(dir, "ewallet.pem") && t.keyPassword == "pw");
    o.walletLocation = buildPath(dir, "none");
    assertThrown!ClientException(o.effectiveTls());
}
