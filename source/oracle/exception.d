/++
Exceptions: `ServerException` for errors reported by Oracle (`ORA-nnnnn`), and
dbwire's `ClientException`, `ConnectionException` and `ProtocolException`.

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module oracle.exception;

public import dbwire.exception : ClientException, ConnectionException, DbException, ProtocolException;

/++
An error reported by the server, e.g. `ORA-00942: table or view does not
exist`. The connection stays usable.
+/
class ServerException : DbException
{
    /// The error number (942 for ORA-00942).
    int code;
    /// The position in the SQL text the error refers to, if any (0-based; -1 if none).
    int offset = -1;

    /// Creates the exception from the server's message text (which starts with `ORA-nnnnn:`).
    this(int code, string message, int offset = -1, string file = __FILE__, size_t line = __LINE__) @safe pure nothrow
    {
        import std.string : stripRight;

        super(message.length ? message.stripRight : "ORA-error " ~ codeText(code), file, line);
        this.code = code;
        this.offset = offset;
    }
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
