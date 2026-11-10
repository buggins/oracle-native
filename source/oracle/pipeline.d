/++
Pipelines: several statements sent to the server together, with their
results read afterwards (Oracle AI Database 23ai), which saves a round trip
per statement. Older servers run the statements one by one, with the same
results.

---
auto results = conn.pipeline()
    .exec("INSERT INTO notes VALUES (:1, :2)", 1, "first")
    .exec("UPDATE counters SET n = n + 1 WHERE id = :1", 7)
    .query("SELECT id, text FROM notes ORDER BY id")
    .commit()
    .run();
foreach (row; results[2].result)
    writeln(row.getLong(0), " ", row.getString(1));
---

The connection is busy while a pipeline runs. A query's rows are all read
before `run` returns (statements whose rows don't fit in the first batch, or
with LOB, JSON or VECTOR columns, take extra round trips after the pipeline).
By default the first failed statement makes the server skip the later ones
and `run` throws its error; with `continueOnError` every statement runs and
the errors are in the results.

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module oracle.pipeline;

import oracle.connection : Connection;
import oracle.exception : ServerException;
import oracle.params : Parameter, parameters;
import oracle.result : QueryResult;

/// The kinds of pipeline operations.
enum PipelineOpKind
{
    exec, /// a statement (DML, DDL, PL/SQL)
    query, /// a query: all its rows are read
    commit, /// a commit
}

/// One operation of a pipeline.
struct PipelineOp
{
    /// What it does.
    PipelineOpKind kind;
    /// The statement (none for a commit).
    string sql;
    /// Its parameters.
    const(Parameter)[] params;
}

/// The outcome of one pipeline operation.
struct PipelineResult
{
    /// The statement (null for a commit).
    string sql;
    /// Rows changed by a DML statement.
    ulong rowCount;
    /++
    The statement's result: a query's rows (all read: iterate them), the
    OUT values of PL/SQL (`outputs`). Null for a commit and after an error.
    +/
    QueryResult result;
    /// The operation's error when the pipeline continued after it (`run(true)`); null on success.
    ServerException error;

    /// Whether the operation succeeded.
    @property bool ok() const @safe pure nothrow
    {
        return error is null;
    }
}

/// A pipeline being built: add operations, then `run` it (see the module description).
final class Pipeline
{
    private Connection conn;
    private PipelineOp[] ops;

    package this(Connection conn) @safe pure nothrow
    {
        this.conn = conn;
    }

    /// Adds a statement (DML, DDL, PL/SQL) with arguments bound as in `Connection.exec`.
    Pipeline exec(Args...)(string sql, auto ref Args args)
    {
        ops ~= PipelineOp(PipelineOpKind.exec, sql, parameters(args));
        return this;
    }

    /// Adds a query, with arguments bound as in `Connection.query`; all its rows are read.
    Pipeline query(Args...)(string sql, auto ref Args args)
    {
        ops ~= PipelineOp(PipelineOpKind.query, sql, parameters(args));
        return this;
    }

    /// Adds a commit.
    Pipeline commit() @safe pure nothrow
    {
        ops ~= PipelineOp(PipelineOpKind.commit);
        return this;
    }

    /// The operations added so far.
    @property const(PipelineOp)[] operations() const @safe pure nothrow
    {
        return ops;
    }

    /++
    Runs the operations: in one pipeline on 23ai (`Connection.supportsPipelining`),
    one by one otherwise. Returns their results, in order.

    Throws: the first operation's `ServerException` unless `continueOnError`
    (then the later operations don't run); `ClientException` for invalid
    arguments; `ConnectionException` if the connection breaks.
    +/
    PipelineResult[] run(bool continueOnError = false) @safe
    {
        return conn.runPipeline(ops, continueOnError);
    }
}
