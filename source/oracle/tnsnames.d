/++
`tnsnames.ora`: connect aliases (net service names) and the connect
descriptors or Easy Connect strings they stand for.

The file is looked for in the configuration directory given (option
`config_dir`), else in `$TNS_ADMIN`, else in `$ORACLE_HOME/network/admin`.
Entries are `NAME = value`; several names may share an entry
(`SALES, SALES.EXAMPLE.COM = (DESCRIPTION=...)`), names are case-insensitive,
a value continues over several lines while its parentheses are open, and `#`
starts a comment. `IFILE = path` includes another file (relative to the
including one). Lines the format doesn't allow are skipped, as Oracle's own
clients do.

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module oracle.tnsnames;

import oracle.exception : ClientException;

/// The entries of a `tnsnames.ora` file and the files it includes.
struct TnsNames
{
    /// The file read (the first one, without its includes).
    string file;
    /// The connect strings by upper-case name.
    string[string] entries;

    /++
    The connect string of `name` (case-insensitive).

    Throws: `ClientException` if the file has no such entry.
    +/
    string lookup(string name) const @safe pure
    {
        import std.uni : toUpper;

        if (auto p = name.toUpper in entries)
            return *p;
        throw new ClientException("No entry '" ~ name ~ "' in " ~ file);
    }
}

/++
The directory with the `tnsnames.ora` file to use: `configDir` if given, else
`$TNS_ADMIN`, else `$ORACLE_HOME/network/admin`; null if none of them has the file.
+/
string findConfigDir(string configDir = null) @safe
{
    import std.file : exists;
    import std.path : buildPath;
    import std.process : environment;

    string[] candidates;
    if (configDir.length)
        candidates = [configDir];
    else
    {
        const tnsAdmin = environment.get("TNS_ADMIN", null);
        if (tnsAdmin.length)
            candidates ~= tnsAdmin;
        const home = environment.get("ORACLE_HOME", null);
        if (home.length)
            candidates ~= buildPath(home, "network", "admin");
    }
    foreach (dir; candidates)
        if (exists(buildPath(dir, "tnsnames.ora")))
            return dir;
    return null;
}

/++
Reads `tnsnames.ora` in `dir`, with the files it includes.

Throws: `ClientException` if a file can't be read or includes itself.
+/
TnsNames readTnsNames(string dir) @safe
{
    import std.path : buildPath;

    TnsNames t;
    t.file = buildPath(dir, "tnsnames.ora");
    string[] reading;
    readInto(t, t.file, reading);
    return t;
}

private void readInto(ref TnsNames t, string file, ref string[] reading) @safe
{
    import std.algorithm.searching : canFind;
    import std.file : FileException, readText;
    import std.path : absolutePath, buildNormalizedPath, buildPath, dirName, isAbsolute;
    import std.utf : UTFException;
    import std.string : split, splitLines, strip;
    import std.uni : toUpper;

    // `sub/../tnsnames.ora` is `tnsnames.ora`: compare normalized absolute paths
    const normalized = buildNormalizedPath(absolutePath(file));
    if (reading.canFind(normalized))
        throw new ClientException("The file " ~ file ~ " includes itself (IFILE)");
    if (reading.length >= 16)
        throw new ClientException("The files included by " ~ reading[0] ~ " are nested too deeply (IFILE)");
    reading ~= normalized;
    scope (exit)
        reading = reading[0 .. $ - 1];
    string text;
    try
        text = readText(file);
    catch (FileException e)
        throw new ClientException("Cannot read " ~ file ~ ": " ~ e.msg);
    catch (UTFException e)
        throw new ClientException("Cannot read " ~ file ~ ": " ~ e.msg);
    foreach (entry; parseTnsNames(text))
    {
        if (entry[0] == "IFILE")
        {
            string included = entry[1];
            if (included.length >= 2 && included[0] == '"' && included[$ - 1] == '"')
                included = included[1 .. $ - 1];
            if (!isAbsolute(included))
                included = buildPath(dirName(file), included);
            readInto(t, included, reading);
            continue;
        }
        foreach (name; entry[0].split(","))
        {
            const lines = name.strip.splitLines;
            if (lines.length && lines[$ - 1].strip.length)
                t.entries[lines[$ - 1].strip.toUpper] = entry[1];
        }
    }
}

/++
The entries of a `tnsnames.ora` text: pairs of the key (upper case; may list
several names, separated by commas) and the value, in order.
+/
string[2][] parseTnsNames(string text) @safe pure
{
    import std.string : strip;
    import std.uni : toUpper;

    string[2][] result;
    size_t pos;

    bool lineBreak(char c)
    {
        return c == '\n' || c == '\r';
    }

    void skipLine()
    {
        while (pos < text.length && !lineBreak(text[pos]))
            pos++;
    }

    void skipSpace()
    {
        while (pos < text.length && (text[pos] == ' ' || text[pos] == '\t' || lineBreak(text[pos])))
            pos++;
    }

    while (pos < text.length)
    {
        // the key: up to '='; a line with '(', ')' or '#' before it is skipped
        skipSpace();
        const keyStart = pos;
        bool skipped;
        while (pos < text.length && text[pos] != '=')
        {
            const c = text[pos];
            if (c == '(' || c == ')' || c == '#')
            {
                skipLine();
                skipped = true;
                break;
            }
            pos++;
        }
        if (skipped || pos >= text.length)
            continue;
        const key = text[keyStart .. pos].strip;
        pos++; // '='
        // the value: parts (each to a comment, or to the end of its line once its parentheses are closed)
        // until the parentheses are balanced
        string value;
        int depth;
        while (pos < text.length)
        {
            skipSpace();
            if (pos >= text.length)
                break;
            if (text[pos] == '#')
            {
                skipLine();
                continue;
            }
            const start = pos;
            while (pos < text.length && text[pos] != '#' && !(depth == 0 && pos > start && lineBreak(text[pos])))
            {
                if (text[pos] == '(')
                    depth++;
                else if (text[pos] == ')' && depth > 0)
                    depth--;
                pos++;
            }
            const part = text[start .. pos].strip;
            if (part.length)
                value ~= (value.length ? "\n" : "") ~ part;
            if (pos < text.length && text[pos] == '#')
                skipLine();
            if (depth == 0)
                break;
        }
        if (key.length && value.length)
            result ~= [key.toUpper, value];
    }
    return result;
}

/++
Whether `text` can be a connect alias rather than an Easy Connect string or a
descriptor: a name without `/`, `:`, `@`, parentheses or spaces.
+/
bool isAliasName(string text) @safe pure nothrow @nogc
{
    import std.ascii : isAlphaNum;

    if (text.length == 0)
        return false;
    foreach (c; text)
        if (!isAlphaNum(c) && c != '_' && c != '.' && c != '-' && c != '$' && c != '#')
            return false;
    return true;
}

///
@safe unittest
{
    const text = `
# a comment
SALES, SALES.EXAMPLE.COM =
  (DESCRIPTION =
    (ADDRESS = (PROTOCOL = TCP)(HOST = db1)(PORT = 1521))  # the primary
    (CONNECT_DATA = (SERVICE_NAME = sales)))

hr = db2:1522/hr   # Easy Connect
(broken line) = x
IFILE = "more.ora"
`;
    const e = parseTnsNames(text);
    assert(e.length == 3);
    assert(e[0][0] == "SALES, SALES.EXAMPLE.COM");
    import std.string : endsWith, startsWith;

    assert(e[0][1].startsWith("(DESCRIPTION =") && e[0][1].endsWith("(CONNECT_DATA = (SERVICE_NAME = sales)))"));
    assert(e[1] == ["HR", "db2:1522/hr"]);
    assert(e[2] == ["IFILE", `"more.ora"`]);
    assert(isAliasName("SALES.EXAMPLE.COM") && !isAliasName("db:1521/x") && !isAliasName("(DESCRIPTION=)"));
}

@safe unittest
{
    import std.file : mkdirRecurse, rmdirRecurse, tempDir, write;
    import std.path : buildPath;
    import std.exception : assertThrown, collectException;
    import std.string : indexOf;

    const dir = buildPath(tempDir, "oracle-native-tnsnames-test");
    mkdirRecurse(buildPath(dir, "sub"));
    write(buildPath(dir, "tnsnames.ora"), "main = (DESCRIPTION=(CONNECT_DATA=(SERVICE_NAME=m)))\nIFILE=sub/x.ora\n");
    write(buildPath(dir, "sub", "x.ora"), "Other, o2 = h:1/o\n");
    scope (exit)
        rmdirRecurse(dir);
    const t = readTnsNames(dir);
    assert(t.lookup("main") == "(DESCRIPTION=(CONNECT_DATA=(SERVICE_NAME=m)))");
    assert(t.lookup("OTHER") == "h:1/o" && t.lookup("o2") == "h:1/o");
    assertThrown!ClientException(t.lookup("missing"));
    assert(findConfigDir(dir) == dir && findConfigDir(buildPath(dir, "sub")) is null);
    write(buildPath(dir, "sub", "x.ora"), "IFILE=../tnsnames.ora\n");
    auto e = collectException!ClientException(readTnsNames(dir)); // includes itself, through a relative path
    assert(e !is null && e.msg.indexOf("includes itself") >= 0, e.msg);
}
