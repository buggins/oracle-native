/++
Statement classification: the client tells the server how to run a statement
(parse and fetch for queries, one execution for DML and PL/SQL), so it looks
at the statement's first keyword.

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module oracle.statement;

/// Kinds of statements.
enum StatementKind
{
    query, /// SELECT, WITH: returns rows
    dml, /// INSERT, UPDATE, DELETE, MERGE
    plsql, /// BEGIN, DECLARE, CALL: a PL/SQL block
    ddl, /// CREATE, ALTER, DROP, ... and everything else
}

/// The kind of `sql`, from its first keyword (after comments, white space and opening parentheses).
StatementKind classify(scope const(char)[] sql) @safe pure
{
    import std.ascii : isAlpha, toUpper;

    size_t i;
    for (;;)
    {
        while (i < sql.length && (sql[i] == ' ' || sql[i] == '\t' || sql[i] == '\r' || sql[i] == '\n' || sql[i] == '('))
            i++;
        if (i + 1 < sql.length && sql[i] == '-' && sql[i + 1] == '-')
        {
            while (i < sql.length && sql[i] != '\n')
                i++;
        }
        else if (i + 1 < sql.length && sql[i] == '/' && sql[i + 1] == '*')
        {
            i += 2;
            while (i + 1 < sql.length && !(sql[i] == '*' && sql[i + 1] == '/'))
                i++;
            i += 2;
        }
        else
            break;
    }
    char[12] word;
    size_t n;
    while (i < sql.length && isAlpha(sql[i]) && n < word.length)
        word[n++] = toUpper(sql[i++]);
    switch (word[0 .. n])
    {
    case "SELECT":
    case "WITH":
        return StatementKind.query;
    case "INSERT":
    case "UPDATE":
    case "DELETE":
    case "MERGE":
        return StatementKind.dml;
    case "BEGIN":
    case "DECLARE":
    case "CALL":
        return StatementKind.plsql;
    default:
        return StatementKind.ddl;
    }
}

///
@safe unittest
{
    assert(classify("select 1 from dual") == StatementKind.query);
    assert(classify("  -- note\n /* x */ (SELECT 1 FROM dual)") == StatementKind.query);
    assert(classify("with t as (select 1 a from dual) select a from t") == StatementKind.query);
    assert(classify("insert into t values (1)") == StatementKind.dml);
    assert(classify("BEGIN NULL; END;") == StatementKind.plsql);
    assert(classify("create table t (a number)") == StatementKind.ddl);
    assert(classify("") == StatementKind.ddl);
}
