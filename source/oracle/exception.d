/++
Exceptions: `ServerException` for errors reported by Oracle (`ORA-nnnnn`),
`StatementTimeoutException` for calls stopped by the call timeout, and
dbwire's `ClientException`, `ConnectionException` and `ProtocolException`.

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module oracle.exception;

public import dbwire.exception : ClientException, ConnectionException, DbException, ProtocolException;

/++
An error reported by the server, e.g. `ORA-00942: table or view does not
exist`. The connection stays usable, except after errors that end the session
(`sessionLost`, e.g. ORA-00028 "your session has been killed"): the connection
is closed then.
+/
class ServerException : DbException
{
    /// The error number (942 for ORA-00942).
    int code;
    /// The position in the SQL text the error refers to, if any (0-based; -1 if none).
    int offset = -1;

    /++
    Whether the error means the session is gone (killed, logged off, the instance shutting down, the connection
    lost): ORA-00028, 00045, 00603, 01012, 01033, 01034, 01041, 01089, 01092, 02392, 02396, 02399, 03113, 03114,
    03135, 12153, 12537, 12547, 12570, 12583, 27146. The connection is closed after such an error, so a pool doesn't
    hand it out again (#75); every later call would fail (ORA-01012 "not logged on"). Not ORA-00031 ("session marked for
    kill") and ORA-00022: the server sends those to the session that issues the kill, about another session.
    +/
    @property bool sessionLost() const @safe pure nothrow @nogc
    {
        switch (code)
        {
        case 28, 45, 603, 1012, 1033, 1034, 1041, 1089, 1092, 2392, 2396, 2399, 3113, 3114, 3135, 12_153, 12_537,
            12_547, 12_570, 12_583, 27_146:
            return true;
        default:
            return false;
        }
    }

    /// Creates the exception from the server's message text (which starts with `ORA-nnnnn:`).
    this(int code, string message, int offset = -1, string file = __FILE__, size_t line = __LINE__) @safe pure nothrow
    {
        import std.string : stripRight;

        super(message.length ? message.stripRight : "ORA-error " ~ codeText(code), file, line);
        this.code = code;
        this.offset = offset;
    }
}

@safe pure nothrow unittest
{
    assert(new ServerException(28, "ORA-00028: your session has been killed").sessionLost);
    assert(new ServerException(3113, "").sessionLost);
    assert(!new ServerException(60, "ORA-00060: deadlock detected while waiting for resource").sessionLost);
    assert(!new ServerException(942, "").sessionLost);
    assert(!new ServerException(31, "ORA-00031: session marked for kill").sessionLost); // the killer's answer
}

/++
A call ran into `ConnectionOptions.callTimeout`: the client cancelled it, and
the server stopped it with ORA-01013 (`code` 1013). The connection stays
usable, and an open transaction stays open with the work done before the call
(#76).
+/
class StatementTimeoutException : ServerException
{
    /// Creates the exception from the server's ORA-01013 text and the timeout.
    this(string message, string timeout, string file = __FILE__, size_t line = __LINE__) @safe pure nothrow
    {
        import std.string : stripRight;

        super(1013, (message.length ? message.stripRight
                : "ORA-01013") ~ " (the call timeout of " ~ timeout
                ~ " ran out)", -1, file, line);
    }
}

@safe pure nothrow unittest
{
    const e = new StatementTimeoutException("ORA-01013: user requested cancel of current operation\n", "2 secs");
    assert(e.code == 1013 && !e.sessionLost);
    assert(e.msg == "ORA-01013: user requested cancel of current operation (the call timeout of 2 secs ran out)");
}

private string codeText(int code) @safe pure nothrow
{
    import std.conv : to;

    return (code < 0 ? 0 : code).to!string;
}

///
@safe unittest
{
    const e = new ServerException(942, "ORA-00942: table or view \"X\" does not exist\n", 14);
    assert(e.code == 942 && e.offset == 14 && e.msg == "ORA-00942: table or view \"X\" does not exist");
    assert(new ServerException(1, null).msg == "ORA-error 1");
}
