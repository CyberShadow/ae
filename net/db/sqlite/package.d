/**
 * Async SQLite database client.
 *
 * Wraps the synchronous SQLite bindings from ae.sys.sqlite3 with the
 * asynchronous, promise-based API of ae.net.db.psql and ae.net.db.mysql.
 * Each connection's statements are executed in a worker thread of its own
 * (see `AsyncQueue`), in order, so that they do not block the event loop.
 *
 * ---
 * auto db = connect("data.db").await;
 * scope(exit) db.close().await;
 * foreach (row; db.query("SELECT id, name FROM users WHERE id = ?", 42))
 *     writeln(row.column!string("name"));
 * ---
 *
 * License:
 *   This Source Code Form is subject to the terms of
 *   the Mozilla Public License, v. 2.0. If a copy of
 *   the MPL was not distributed with this file, You
 *   can obtain one at http://mozilla.org/MPL/2.0/.
 *
 * Authors:
 *   Vladimir Panteleev <ae@cy.md>
 */

module ae.net.db.sqlite;

import std.conv : to;
import std.exception : enforce;
import std.typecons : Nullable;

import ae.sys.sqlite3 : SQLite, SQLiteException;
import ae.utils.promise;
import ae.utils.promise.concurrency : AsyncQueue;

public import ae.net.db.common : DbException, Param, toParams;
static import ae.net.db.common;

// https://issues.dlang.org/show_bug.cgi?id=7016
static import ae.utils.promise.await;

/// Open the database file `path` (created if it does not exist, unless
/// `readOnly`; ":memory:": a new in-memory database); the promise is
/// fulfilled with the connection once it is open.
Promise!SqliteConnection connect(string path, bool readOnly = false)
{
    auto conn = new SqliteConnection;
    auto worker = conn.worker;
    return conn.queue.put({
        worker.db = new SQLite(path, readOnly);
        return WorkerResult.init;
    }).then((WorkerResult _) {
        return conn;
    }, delegate SqliteConnection(Exception e) {
        conn.queue.close();  // (Let the event loop exit)
        conn.queue = null;
        throw wrapException(e);
    });
}

/// An SQLite error (`code`: the SQLite result code, 0 if none).
class SqliteException : DbException
{
    /// SQLite result code.
    int code;

    this(string msg, string file = __FILE__, size_t line = __LINE__)
    {
        super(msg, file, line);
    }

    this(string msg, int code, string file = __FILE__, size_t line = __LINE__)
    {
        this.code = code;
        super(msg, file, line);
    }
}

/// A row of a query's result (see `ae.net.db.common.Row`): its values in
/// text format, as SQLite converts them.
alias Row = ae.net.db.common.Row!();

/// The lazy result of a query (see `ae.net.db.common.Result`). Its
/// `affectedRows` are those its (last) INSERT, UPDATE or DELETE statement
/// changed (`sqlite3_changes`), and its `lastInsertId` the row ID of the row
/// it inserted (`sqlite3_last_insert_rowid`, if the query changed it).
alias Result = ae.net.db.common.Result!Row;

/// A statement prepared on a connection (see `SqliteConnection.prepare`).
final class PreparedStatement
{
    /// Execute the statement with the parameters `args` (see `Param.of`),
    /// or `params` (see `SqliteConnection.query`).
    Result query(Args...)(Args args)
    {
        return query(toParams(args));
    }

    /// ditto
    Result query(const(Param)[] params)
    {
        enforce!SqliteException(!closed, "PreparedStatement has been closed");
        auto id = statementId;
        return conn.run((Worker w) {
            auto stmt = enforce!SqliteException(id in w.statements, "Unknown statement");
            return w.execute(*stmt, params);
        });
    }

    /// Close (finalize) the statement.
    Promise!void close()
    {
        enforce!SqliteException(!closed, "PreparedStatement already closed");
        closed = true;
        auto id = statementId;
        return conn.call((Worker w) {
            if (auto stmt = id in w.statements)
            {
                destroy(*stmt);
                w.statements.remove(id);
            }
            return WorkerResult.init;
        }).then((WorkerResult _) {});
    }

private:
    SqliteConnection conn;
    uint statementId;
    bool closed;

    this(SqliteConnection conn, uint id)
    {
        this.conn = conn;
        this.statementId = id;
    }
}

/// A connection to an SQLite database (see `connect`). Its statements are
/// executed in its worker thread, in the order their results are
/// consumed.
final class SqliteConnection
{
    /// A query of the SQL `sql`: one or several statements (`sqlite3_exec`),
    /// without parameters. (Of several statements, the result has the rows
    /// of all of them.)
    Result query(const(char)[] sql)
    {
        auto text = sql.idup;
        return run((Worker w) => w.exec(text));
    }

    /// A query of the statement `sql` with the parameters `args` (see
    /// `Param.of`), or `params`: prepared, executed with the parameters
    /// (bound natively: a boolean as the integer 0 or 1, an integer as a
    /// 64-bit integer, a floating-point number as a REAL, an exact number as
    /// an integer if it is one, else as a REAL, a string as TEXT, a byte
    /// array as a BLOB) and finalized. Arrays are not supported.
    Result query(Args...)(const(char)[] sql, Args args)
    {
        return query(sql, toParams(args));
    }

    /// ditto
    Result query(const(char)[] sql, const(Param)[] params)
    {
        auto text = sql.idup;
        return run((Worker w) {
            auto stmt = w.db.prepare(text);
            scope(exit) destroy(stmt);  // (finalized)
            return w.execute(stmt, params);
        });
    }

    /// Prepare the statement `sql` (with `?` or `?NNN` parameters, see
    /// `PreparedStatement.query`).
    Promise!PreparedStatement prepare(const(char)[] sql)
    {
        auto text = sql.idup;
        auto id = nextStatementId++;
        return call((Worker w) {
            w.statements[id] = w.db.prepare(text);
            return WorkerResult.init;
        }).then((WorkerResult _) => new PreparedStatement(this, id));
    }

    /// Close the connection (finalizing its prepared statements), once its
    /// pending statements have been executed, and end its worker thread.
    Promise!void close()
    {
        if (closing)
            return closing;
        enforce!SqliteException(queue !is null, "Connection is not open");
        auto q = queue;
        auto worker = this.worker;
        closing = q.put({
            worker.close();
            return WorkerResult.init;
        }).then((WorkerResult _) {
            q.close();
        }, (Exception e) {
            q.close();
            throw wrapException(e);
        });
        queue = null;
        return closing;
    }

private:
    WorkerQueue queue;
    Worker worker;
    uint nextStatementId;
    Promise!void closing;

    this()
    {
        queue = new WorkerQueue;
        worker = new Worker;
    }

    /// Run `task` in the worker thread.
    Promise!WorkerResult call(WorkerResult delegate(Worker) task)
    {
        if (queue is null)
        {
            auto p = new Promise!WorkerResult;
            p.reject(new SqliteException("Connection is closed"));
            return p;
        }
        auto worker = this.worker;
        return queue.put(() => task(worker)).except(delegate WorkerResult(Exception e) {
            throw wrapException(e);
        });
    }

    /// A result whose query `task` executes in the worker thread (when it
    /// is consumed).
    Result run(WorkerResult delegate(Worker) task)
    {
        return new Result((Result result) {
            call(task).then((WorkerResult r) {
                result.onColumns(r.columns);
                foreach (i, values; r.rows)
                    result.onRow(values, r.nulls[i]);
                result.onAffected(r.affectedRows, r.lastInsertId);
                result.onComplete();
            }, (Exception e) {
                result.onError(e);
            });
        });
    }
}

private:

alias WorkerQueue = AsyncQueue!WorkerResult;

/// The outcome of a task of the worker thread: of a query, its columns,
/// rows, and changes.
struct WorkerResult
{
    string[] columns;
    string[][] rows;
    bool[][] nulls;
    ulong affectedRows, lastInsertId;
}

/// The state of a connection, used in its worker thread only.
final class Worker
{
    SQLite db;
    SQLite.PreparedStatement[uint] statements;

    /// Execute the SQL `sql` (one or several statements).
    WorkerResult exec(string sql)
    {
        return changes((ref WorkerResult r) {
            foreach (cells, columns; db.query(sql))
            {
                if (!r.columns.length)
                    foreach (column; columns)
                        r.columns ~= column.idup;
                auto values = new string[cells.length];
                auto nulls = new bool[cells.length];
                foreach (i, cell; cells)
                {
                    nulls[i] = cell is null;
                    values[i] = cell.idup;
                }
                r.rows ~= values;
                r.nulls ~= nulls;
            }
        });
    }

    /// Execute the statement `stmt` with the parameters `params`.
    WorkerResult execute(SQLite.PreparedStatement stmt, const(Param)[] params)
    {
        enforce!SqliteException(stmt.parameterCount == params.length,
            "Expected " ~ stmt.parameterCount.to!string ~ " parameters, got " ~ params.length.to!string);
        foreach (i, param; params)
            bind(stmt, cast(int) i + 1, param);
        return changes((ref WorkerResult r) {
            auto count = stmt.columnCount();
            foreach (c; 0 .. count)
                r.columns ~= stmt.columnName(c);
            while (stmt.step())
            {
                auto values = new string[count];
                auto nulls = new bool[count];
                foreach (c; 0 .. count)
                {
                    auto value = stmt.column!(Nullable!string)(c);
                    nulls[c] = value.isNull;
                    if (!value.isNull)
                        values[c] = value.get;
                }
                r.rows ~= values;
                r.nulls ~= nulls;
            }
        });
    }

    /// Run `fun`, then record the rows it changed and the row it inserted.
    WorkerResult changes(scope void delegate(ref WorkerResult) fun)
    {
        import etc.c.sqlite3 : sqlite3_changes, sqlite3_last_insert_rowid, sqlite3_total_changes;
        auto totalChanges = sqlite3_total_changes(db.db);
        auto lastInsertId = sqlite3_last_insert_rowid(db.db);
        WorkerResult r;
        fun(r);
        if (sqlite3_total_changes(db.db) != totalChanges)
            r.affectedRows = sqlite3_changes(db.db);
        auto insertId = sqlite3_last_insert_rowid(db.db);
        if (insertId != lastInsertId)
            r.lastInsertId = insertId;
        return r;
    }

    void close()
    {
        foreach (stmt; statements)
            destroy(stmt);
        statements = null;
        destroy(db);
        db = null;
    }
}

/// Bind the parameter `param` as the parameter `index` of `stmt`.
void bind(SQLite.PreparedStatement stmt, int index, const Param param)
{
    static immutable ubyte[1] nonNull;  // (of empty values, which a null pointer would make NULL)
    final switch (param.type)
    {
        case Param.Type.null_: stmt.bind(index, cast(void*) null); break;
        case Param.Type.boolean: stmt.bind(index, param.boolean ? 1L : 0L); break;
        case Param.Type.integer: stmt.bind(index, param.integer); break;
        case Param.Type.floating: stmt.bind(index, param.floating); break;
        case Param.Type.numeric:
            try
                stmt.bind(index, param.text.to!long);
            catch (Exception)
                stmt.bind(index, param.text.to!double);
            break;
        case Param.Type.text:
            stmt.bind(index, param.text.length ? param.text : cast(string) nonNull[0 .. 0]);
            break;
        case Param.Type.bytes:
            stmt.bind(index, param.bytes.length ? cast(const(void)[]) param.bytes : nonNull[0 .. 0]);
            break;
        case Param.Type.array:
            throw new SqliteException("SQLite has no array parameters");
    }
}

SqliteException wrapException(Exception e)
{
    if (auto se = cast(SqliteException) e)
        return se;
    if (auto se = cast(SQLiteException) e)
        return new SqliteException(se.msg, se.code);
    return new SqliteException(e.msg);
}

// Unit tests

debug(ae_unittest) unittest
{
    import ae.utils.promise.await : async, await, awaitSync;

    // Test: Basic connection and query
    async({
        auto db = connect(":memory:").await;
        scope(exit) db.close().await;

        db.query("CREATE TABLE test (id INTEGER PRIMARY KEY, name TEXT, value REAL)").array.await;
        db.query("INSERT INTO test (id, name, value) VALUES (1, 'hello', 3.14)").array.await;
        db.query("INSERT INTO test (id, name, value) VALUES (2, 'world', 2.71)").array.await;

        auto rows = db.query("SELECT * FROM test ORDER BY id").array.await;
        assert(rows.length == 2, "Expected 2 rows");
        assert(rows[0].column!int("id") == 1);
        assert(rows[0].column!string("name") == "hello");
        assert(rows[0].column!int(0) == 1);
        assert(rows[1].column!int("id") == 2);
        assert(rows[1].column!string("name") == "world");
    }).awaitSync();
}

debug(ae_unittest) unittest
{
    import ae.utils.promise.await : async, await, awaitSync;
    import std.math : isClose;
    import std.typecons : Nullable;

    // Test: Type conversions and NULL handling
    async({
        auto db = connect(":memory:").await;
        scope(exit) db.close().await;

        db.query("CREATE TABLE types (i INTEGER, r REAL, t TEXT, n INTEGER)").array.await;
        db.query("INSERT INTO types VALUES (42, 3.14159, 'test', NULL)").array.await;

        auto rows = db.query("SELECT * FROM types").array.await;
        assert(rows.length == 1);
        assert(rows[0].column!int("i") == 42);
        assert(rows[0].column!long("i") == 42L);
        assert(isClose(rows[0].column!double("r"), 3.14159));
        assert(rows[0].column!string("t") == "test");
        assert(rows[0].isNull("n"));
        assert(rows[0].column!(Nullable!int)("n").isNull);
        assert(!rows[0].column!(Nullable!int)("i").isNull);
        assert(rows[0].column!(Nullable!int)("i").get == 42);
    }).awaitSync();
}

debug(ae_unittest) unittest
{
    import ae.utils.promise.await : async, await, awaitSync;

    // Test: map() and foreach; several statements in one query
    async({
        auto db = connect(":memory:").await;
        scope(exit) db.close().await;

        db.query("CREATE TABLE nums (n INTEGER); INSERT INTO nums VALUES (1), (2), (3), (4), (5)").array.await;

        auto doubled = db.query("SELECT n FROM nums ORDER BY n").map((Row row) {
            return row.column!int("n") * 2;
        }).await;
        assert(doubled == [2, 4, 6, 8, 10]);

        int sum, count;
        foreach (row; db.query("SELECT n FROM nums"))
        {
            sum += row.column!int("n");
            count++;
        }
        assert(count == 5 && sum == 15);
    }).awaitSync();
}

debug(ae_unittest) unittest
{
    import ae.utils.promise.await : async, await, awaitSync;

    // Test: Errors (of a query, of parameters), empty results
    async({
        auto db = connect(":memory:").await;
        scope(exit) db.close().await;

        int errors;
        foreach (result; [db.query("SELECT * FROM nonexistent_table"), db.query("SELECT ?", 1, 2),
                db.query("SELECT ?", [Param.array([Param.of(1)])])])
            try
                result.array.await;
            catch (SqliteException e)
            {
                assert(e.msg.length > 0);
                errors++;
            }
        assert(errors == 3, "Expected errors");

        db.query("CREATE TABLE empty_test (id INTEGER)").array.await;
        assert(db.query("SELECT * FROM empty_test").array.await.length == 0);
    }).awaitSync();
}

debug(ae_unittest) unittest
{
    import ae.utils.promise.await : async, await, awaitSync;

    // Test: Prepared statements
    async({
        auto db = connect(":memory:").await;
        scope(exit) db.close().await;

        db.query("CREATE TABLE prep_test (id INTEGER, name TEXT)").array.await;
        db.query("INSERT INTO prep_test VALUES (1, 'one'), (2, 'two'), (3, 'three')").array.await;

        auto stmt = db.prepare("SELECT * FROM prep_test WHERE id = ?").await;
        scope(exit) stmt.close().await;

        auto rows = stmt.query(2).array.await;
        assert(rows.length == 1);
        assert(rows[0].column!int("id") == 2);
        assert(rows[0].column!string("name") == "two");

        rows = stmt.query([Param.of(1)]).array.await;
        assert(rows.length == 1);
        assert(rows[0].column!string("name") == "one");

        auto stmt2 = db.prepare("SELECT * FROM prep_test WHERE id > ? AND id < ?").await;
        rows = stmt2.query(1, 3).array.await;
        stmt2.close().await;
        assert(rows.length == 1 && rows[0].column!int("id") == 2);
    }).awaitSync();
}

debug(ae_unittest) unittest
{
    import ae.utils.promise.await : async, await, awaitSync;

    // Test: Typed parameters; affected rows and inserted row IDs
    async({
        auto db = connect(":memory:").await;
        scope(exit) db.close().await;

        auto rows = db.query("SELECT typeof(?) AS i, typeof(?) AS r, typeof(?) AS t, typeof(?) AS n, "
            ~ "typeof(?) AS b, typeof(?) AS x, ? * 2 AS d, typeof(?) AS e, ? = '' AS empty",
            42, 1.5, "s", null, true, cast(ubyte[]) [1, 2], Param.numeric("1.25"), Param.numeric("7"), "").array.await;
        assert(rows[0].column!string("i") == "integer" && rows[0].column!string("r") == "real");
        assert(rows[0].column!string("t") == "text" && rows[0].column!string("n") == "null");
        assert(rows[0].column!string("b") == "integer" && rows[0].column!string("x") == "blob");
        assert(rows[0].column!double("d") == 2.5 && rows[0].column!string("e") == "integer");
        assert(rows[0].column!bool("empty"));

        db.query("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)").array.await;
        auto inserted = db.query("INSERT INTO t (name) VALUES (?), (?)", "a", "b");
        inserted.array.await;
        assert(inserted.affectedRows == 2 && inserted.lastInsertId == 2);
        auto selected = db.query("SELECT * FROM t");
        assert(selected.array.await.length == 2);
        assert(selected.affectedRows == 0 && selected.lastInsertId == 0);
        auto updated = db.query("UPDATE t SET name = ? WHERE id >= ?", "c", 1);
        updated.array.await;
        assert(updated.affectedRows == 2 && updated.lastInsertId == 0);
    }).awaitSync();
}

debug(ae_unittest) unittest
{
    import ae.utils.promise.await : async, await, awaitSync;

    // Test: Opening a database that does not exist read-only rejects the
    // connection's promise (and lets the event loop exit)
    bool failed;
    async({
        try
            connect("/nonexistent/ae-sqlite-test.db", true).await;
        catch (SqliteException e)
            failed = true;
    }).awaitSync();
    assert(failed);
}
