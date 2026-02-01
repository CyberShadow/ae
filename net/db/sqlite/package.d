/**
 * Async SQLite database client.
 *
 * Wraps the synchronous SQLite bindings from ae.sys.sqlite3 with
 * an asynchronous Promise-based API that matches ae.net.db.mysql
 * and ae.net.db.psql. SQLite operations are executed in a dedicated
 * worker thread via AsyncQueue, preventing blocking of the main
 * event loop.
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

/// Exception type for SQLite errors (async wrapper).
class SqliteException : Exception
{
    /// SQLite error code.
    int code;

    this(string msg, string file = __FILE__, size_t line = __LINE__)
    {
        this.code = 0;
        super(msg, file, line);
    }

    this(string msg, int code, string file = __FILE__, size_t line = __LINE__)
    {
        this.code = code;
        super(msg, file, line);
    }

    this(SQLiteException e, string file = __FILE__, size_t line = __LINE__)
    {
        this.code = e.code;
        super(e.msg, file, line);
    }
}

/// Async SQLite connection.
/// Operations are executed in a dedicated worker thread.
final class SqliteConnection
{
    /// Open database file (or ":memory:" for in-memory database).
    this(string path, bool readOnly = false)
    {
        this.path = path;
        this.readOnly = readOnly;

        queue = new WorkerQueue;
        readyPromise = new Promise!void;

        // Initialize connection in worker thread
        queue.put({
            workerDb = new SQLite(path, readOnly);
            return WorkerResult.init;
        }).then((_) {
            readyPromise.fulfill();
        }).except((Exception e) {
            readyPromise.reject(new SqliteException(e.msg));
        });
    }

    /// Promise that fulfills when the connection is ready for queries.
    @property Promise!void ready()
    {
        return readyPromise;
    }

    /// Create a lazy query result.
    /// The query is not executed until .array(), .map(), or foreach is called.
    Result query(const(char)[] sql)
    {
        return new Result(sql, this);
    }

    /// Prepare a statement for execution with parameters.
    /// Use ? as parameter placeholder.
    Promise!PreparedStatement prepare(const(char)[] sql)
    {
        auto promise = new Promise!PreparedStatement;
        auto sqlCopy = sql.idup;

        queue.put({
            auto syncStmt = workerDb.prepare(sqlCopy);
            auto id = nextStmtId++;
            workerStatements[id] = syncStmt;
            return WorkerResult(WorkerResultType.prepare, null, null, null, id);
        }).then((result) {
            auto stmt = new PreparedStatement(result.statementId, this);
            promise.fulfill(stmt);
        }).except((Exception e) {
            promise.reject(wrapException(e));
        });

        return promise;
    }

    /// Get the last insert rowid.
    Promise!long lastInsertRowId()
    {
        auto promise = new Promise!long;

        queue.put({
            return WorkerResult(WorkerResultType.lastInsertRowId,
                null, null, null, 0, workerDb.lastInsertRowID);
        }).then((result) {
            promise.fulfill(result.lastInsertRowId);
        }).except((Exception e) {
            promise.reject(wrapException(e));
        });

        return promise;
    }

    /// Get the number of rows changed by the last statement.
    Promise!int changes()
    {
        auto promise = new Promise!int;

        queue.put({
            return WorkerResult(WorkerResultType.changes,
                null, null, null, 0, 0, workerDb.changes);
        }).then((result) {
            promise.fulfill(result.changes);
        }).except((Exception e) {
            promise.reject(wrapException(e));
        });

        return promise;
    }

    /// Close the connection and free resources.
    void close()
    {
        if (queue !is null)
        {
            queue.put({
                // Clean up all prepared statements
                foreach (stmt; workerStatements)
                    destroy(stmt);
                workerStatements = null;

                // Close database
                destroy(workerDb);
                workerDb = null;

                return WorkerResult.init;
            }).then((_) {});

            queue.close();
            queue = null;
        }
    }

private:
    string path;
    bool readOnly;
    WorkerQueue queue;
    Promise!void readyPromise;

    // Worker thread state (only accessed from worker thread)
    static SQLite workerDb;
    static SQLite.PreparedStatement[uint] workerStatements;
    static uint nextStmtId;

    alias WorkerQueue = AsyncQueue!WorkerResult;

    enum WorkerResultType
    {
        empty,
        query,
        prepare,
        lastInsertRowId,
        changes,
    }

    struct WorkerResult
    {
        WorkerResultType type;
        RowData[] rows;
        string[] columnNames;
        bool[] nullFlags;
        uint statementId;
        long lastInsertRowId;
        int changes;
    }

    struct RowData
    {
        string[] values;
        bool[] nulls;
    }

    static SqliteException wrapException(Exception e)
    {
        if (auto se = cast(SQLiteException)e)
            return new SqliteException(se);
        if (auto se = cast(SqliteException)e)
            return se;
        return new SqliteException(e.msg);
    }

    void executeQuery(Result result)
    {
        auto sqlCopy = result.sql.idup;
        auto stmtId = result.preparedStatement !is null ? result.preparedStatement.statementId : uint.max;
        auto argsCopy = result.queryArgs.dup;
        auto nullsCopy = result.queryArgNulls.dup;

        queue.put({
            RowData[] rows;
            string[] columnNames;

            if (stmtId != uint.max)
            {
                // Prepared statement execution
                auto stmt = workerStatements[stmtId];

                // Bind parameters
                foreach (i, arg; argsCopy)
                {
                    if (nullsCopy[i])
                        stmt.bind(cast(int)(i + 1), cast(void*)null);
                    else
                        stmt.bind(cast(int)(i + 1), arg);
                }

                // Get column names
                auto colCount = stmt.columnCount();
                columnNames = new string[colCount];
                foreach (c; 0 .. colCount)
                    columnNames[c] = stmt.columnName(c);

                // Execute and collect rows
                while (stmt.step())
                {
                    auto values = new string[colCount];
                    auto nulls = new bool[colCount];
                    foreach (c; 0 .. colCount)
                    {
                        auto val = stmt.column!(Nullable!string)(c);
                        if (val.isNull)
                            nulls[c] = true;
                        else
                            values[c] = val.get;
                    }
                    rows ~= RowData(values, nulls);
                }
            }
            else
            {
                // Simple query execution
                bool firstRow = true;
                foreach (cells, columns; workerDb.query(sqlCopy))
                {
                    if (firstRow)
                    {
                        columnNames = new string[columns.length];
                        foreach (i, col; columns)
                            columnNames[i] = col.idup;
                        firstRow = false;
                    }

                    auto values = new string[cells.length];
                    auto nulls = new bool[cells.length];
                    foreach (i, cell; cells)
                    {
                        if (cell is null)
                            nulls[i] = true;
                        else
                            values[i] = cell.idup;
                    }
                    rows ~= RowData(values, nulls);
                }
            }

            return WorkerResult(WorkerResultType.query, rows, columnNames);
        }).then((workerResult) {
            result.onQueryComplete(workerResult.rows, workerResult.columnNames);
        }).except((Exception e) {
            result.onError(wrapException(e));
        });
    }

    void closeStatement(PreparedStatement stmt)
    {
        auto id = stmt.statementId;
        queue.put({
            if (auto syncStmt = id in workerStatements)
            {
                destroy(*syncStmt);
                workerStatements.remove(id);
            }
            return WorkerResult.init;
        }).then((_) {});
    }
}

/// A single row from a query result.
struct Row
{
    private string[] columnNames;
    private string[] values;
    private bool[] nulls;

    /// Get column value by index with type conversion.
    T column(T)(size_t idx) const
    {
        enforce!SqliteException(idx < values.length, "Column index out of range");
        static if (is(T == Nullable!U, U))
        {
            if (nulls[idx])
                return T.init;
            return T(column!U(idx));
        }
        else
        {
            enforce!SqliteException(!nulls[idx], "NULL value for non-nullable column");
            return convertValue!T(values[idx]);
        }
    }

    /// Get column value by name with type conversion.
    T column(T)(const(char)[] name) const
    {
        return column!T(fieldIndex(name));
    }

    /// Check if a column is NULL.
    bool isNull(size_t idx) const
    {
        enforce!SqliteException(idx < nulls.length, "Column index out of range");
        return nulls[idx];
    }

    /// Check if a column is NULL by name.
    bool isNull(const(char)[] name) const
    {
        return isNull(fieldIndex(name));
    }

    /// Get the number of columns.
    size_t length() const
    {
        return values.length;
    }

    private size_t fieldIndex(const(char)[] name) const
    {
        foreach (i, colName; columnNames)
            if (colName == name)
                return i;
        throw new SqliteException("Unknown column: " ~ name.idup);
    }
}

/// Convert string value to D type.
private T convertValue(T)(const(char)[] textValue)
{
    static if (is(T == string))
        return textValue.idup;
    else static if (is(T == int))
        return textValue.to!int;
    else static if (is(T == long))
        return textValue.to!long;
    else static if (is(T == double))
        return textValue.to!double;
    else static if (is(T == bool))
        return textValue == "1" || textValue == "true";
    else static if (is(T == ubyte[]))
        return cast(ubyte[])textValue.idup.dup;
    else
        static assert(false, "Unsupported type: " ~ T.stringof);
}

/// Lazy query result handle.
/// The query is not executed until a consumption method is called.
final class Result
{
    private const(char)[] sql;
    private SqliteConnection conn;
    private PreparedStatement preparedStatement;
    private string[] queryArgs;
    private bool[] queryArgNulls;
    private bool consumed;
    private bool completed;
    private SqliteConnection.RowData[] rowData;
    private string[] columnNames;
    private SqliteException error;

    // For array() mode
    private Promise!(Row[]) arrayPromise;

    // For lazy iteration (opApply)
    private bool iterating;
    private PromiseQueue!(Nullable!Row) iterQueue;

    private this(const(char)[] sql, SqliteConnection conn)
    {
        this.sql = sql;
        this.conn = conn;
    }

    /// Collect all rows and return as array.
    Promise!(Row[]) array()
    {
        enforce!SqliteException(!consumed, "Result has already been consumed");
        consumed = true;

        if (error)
        {
            auto p = new Promise!(Row[]);
            p.reject(error);
            return p;
        }

        arrayPromise = new Promise!(Row[]);
        conn.executeQuery(this);
        return arrayPromise;
    }

    /// Map a function over rows, returning collected results.
    Promise!(T[]) map(T)(T delegate(Row) fn)
    {
        enforce!SqliteException(!consumed, "Result has already been consumed");
        consumed = true;

        auto resultPromise = new Promise!(T[]);

        if (error)
        {
            resultPromise.reject(error);
            return resultPromise;
        }

        arrayPromise = new Promise!(Row[]);
        arrayPromise.then((Row[] rows) {
            T[] results;
            foreach (row; rows)
                results ~= fn(row);
            resultPromise.fulfill(results);
        }).except((Exception e) {
            resultPromise.reject(e);
        });

        conn.executeQuery(this);
        return resultPromise;
    }

    /// Fiber-based foreach iteration (requires fiber context).
    int opApply(scope int delegate(Row) dg)
    {
        import ae.utils.promise.await : await;

        enforce!SqliteException(!consumed, "Result has already been consumed");
        consumed = true;

        if (error)
            throw error;

        // For SQLite, we execute the full query and then iterate
        // (SQLite doesn't support streaming results over a network)
        iterating = true;
        iterQueue = PromiseQueue!(Nullable!Row).init;
        scope(exit)
        {
            iterating = false;
            iterQueue = PromiseQueue!(Nullable!Row).init;
        }

        conn.executeQuery(this);

        while (true)
        {
            auto item = iterQueue.waitOne().await;

            if (error)
                throw error;

            if (item.isNull)
                break;

            if (auto r = dg(item.get))
                return r;
        }

        return 0;
    }

    private void onQueryComplete(SqliteConnection.RowData[] data, string[] colNames)
    {
        rowData = data;
        columnNames = colNames;
        completed = true;

        // Convert to Row objects
        Row[] rows;
        foreach (rd; rowData)
            rows ~= Row(columnNames, rd.values, rd.nulls);

        if (iterating)
        {
            foreach (row; rows)
                iterQueue.fulfillOne(Nullable!Row(row));
            iterQueue.fulfillOne(Nullable!Row.init);  // End marker
        }
        else if (arrayPromise)
        {
            arrayPromise.fulfill(rows);
        }
    }

    private void onError(SqliteException e)
    {
        error = e;
        completed = true;

        if (arrayPromise)
            arrayPromise.reject(e);
        if (iterating)
            iterQueue.fulfillOne(Nullable!Row.init);
    }
}

/// Prepared statement handle.
final class PreparedStatement
{
    private uint statementId;
    private SqliteConnection conn;
    private bool closed;

    private this(uint id, SqliteConnection conn)
    {
        this.statementId = id;
        this.conn = conn;
    }

    /// Execute the prepared statement with the given parameters.
    Result query(Args...)(Args args)
    {
        import std.format : format;

        enforce!SqliteException(!closed, "PreparedStatement has been closed");
        auto result = new Result(null, conn);
        result.preparedStatement = this;

        // Build argument arrays
        result.queryArgs = new string[Args.length];
        result.queryArgNulls = new bool[Args.length];

        foreach (i, arg; args)
        {
            static if (is(typeof(arg) == typeof(null)))
            {
                result.queryArgNulls[i] = true;
            }
            else static if (is(typeof(arg) == Nullable!U, U))
            {
                if (arg.isNull)
                    result.queryArgNulls[i] = true;
                else
                    result.queryArgs[i] = format!"%s"(arg.get);
            }
            else static if (is(typeof(arg) : const(char)[]))
            {
                result.queryArgs[i] = arg.idup;
            }
            else static if (is(typeof(arg) == bool))
            {
                result.queryArgs[i] = arg ? "1" : "0";
            }
            else
            {
                result.queryArgs[i] = format!"%s"(arg);
            }
        }

        return result;
    }

    /// Close the prepared statement, freeing resources.
    void close()
    {
        enforce!SqliteException(!closed, "PreparedStatement already closed");
        closed = true;
        conn.closeStatement(this);
    }
}

// Unit tests
debug(ae_unittest) unittest
{
    import ae.net.asockets : socketManager;
    import ae.utils.promise.await : async, await, awaitSync;

    // Test: Basic connection and query
    async({
        auto db = new SqliteConnection(":memory:");
        await(db.ready);
        scope(exit) db.close();

        // Create table
        db.query("CREATE TABLE test (id INTEGER PRIMARY KEY, name TEXT, value REAL)").array.await;

        // Insert data
        db.query("INSERT INTO test (id, name, value) VALUES (1, 'hello', 3.14)").array.await;
        db.query("INSERT INTO test (id, name, value) VALUES (2, 'world', 2.71)").array.await;

        // Select and verify
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
    import ae.net.asockets : socketManager;
    import ae.utils.promise.await : async, await, awaitSync;
    import std.math : isClose;

    // Test: Type conversions and NULL handling
    async({
        auto db = new SqliteConnection(":memory:");
        await(db.ready);
        scope(exit) db.close();

        db.query("CREATE TABLE types (i INTEGER, r REAL, t TEXT, n INTEGER)").array.await;
        db.query("INSERT INTO types VALUES (42, 3.14159, 'test', NULL)").array.await;

        auto rows = db.query("SELECT * FROM types").array.await;
        assert(rows.length == 1);

        // Integer
        assert(rows[0].column!int("i") == 42);
        assert(rows[0].column!long("i") == 42L);

        // Real
        assert(isClose(rows[0].column!double("r"), 3.14159));

        // Text
        assert(rows[0].column!string("t") == "test");

        // NULL handling
        assert(rows[0].isNull("n"));
        assert(rows[0].column!(Nullable!int)("n").isNull);

        // Non-null Nullable
        assert(!rows[0].column!(Nullable!int)("i").isNull);
        assert(rows[0].column!(Nullable!int)("i").get == 42);
    }).awaitSync();
}

debug(ae_unittest) unittest
{
    import ae.net.asockets : socketManager;
    import ae.utils.promise.await : async, await, awaitSync;

    // Test: map() function
    async({
        auto db = new SqliteConnection(":memory:");
        await(db.ready);
        scope(exit) db.close();

        db.query("CREATE TABLE nums (n INTEGER)").array.await;
        db.query("INSERT INTO nums VALUES (1), (2), (3), (4), (5)").array.await;

        auto doubled = db.query("SELECT n FROM nums ORDER BY n").map((row) {
            return row.column!int("n") * 2;
        }).await;

        assert(doubled == [2, 4, 6, 8, 10]);
    }).awaitSync();
}

debug(ae_unittest) unittest
{
    import ae.net.asockets : socketManager;
    import ae.utils.promise.await : async, await, awaitSync;

    // Test: foreach iteration
    async({
        auto db = new SqliteConnection(":memory:");
        await(db.ready);
        scope(exit) db.close();

        db.query("CREATE TABLE items (id INTEGER)").array.await;
        db.query("INSERT INTO items VALUES (10), (20), (30)").array.await;

        int sum = 0;
        int count = 0;
        foreach (row; db.query("SELECT id FROM items"))
        {
            sum += row.column!int("id");
            count++;
        }

        assert(count == 3);
        assert(sum == 60);
    }).awaitSync();
}

debug(ae_unittest) unittest
{
    import ae.net.asockets : socketManager;
    import ae.utils.promise.await : async, await, awaitSync;

    // Test: Error handling
    async({
        auto db = new SqliteConnection(":memory:");
        await(db.ready);
        scope(exit) db.close();

        bool gotError = false;
        try
        {
            db.query("SELECT * FROM nonexistent_table").array.await;
        }
        catch (SqliteException e)
        {
            gotError = true;
            assert(e.msg.length > 0);
        }
        assert(gotError, "Expected error for nonexistent table");
    }).awaitSync();
}

debug(ae_unittest) unittest
{
    import ae.net.asockets : socketManager;
    import ae.utils.promise.await : async, await, awaitSync;

    // Test: Empty result set
    async({
        auto db = new SqliteConnection(":memory:");
        await(db.ready);
        scope(exit) db.close();

        db.query("CREATE TABLE empty_test (id INTEGER)").array.await;

        auto rows = db.query("SELECT * FROM empty_test").array.await;
        assert(rows.length == 0);
    }).awaitSync();
}

debug(ae_unittest) unittest
{
    import ae.net.asockets : socketManager;
    import ae.utils.promise.await : async, await, awaitSync;

    // Test: Prepared statements
    async({
        auto db = new SqliteConnection(":memory:");
        await(db.ready);
        scope(exit) db.close();

        db.query("CREATE TABLE prep_test (id INTEGER, name TEXT)").array.await;
        db.query("INSERT INTO prep_test VALUES (1, 'one'), (2, 'two'), (3, 'three')").array.await;

        // Prepare and execute with parameters
        auto stmt = db.prepare("SELECT * FROM prep_test WHERE id = ?").await;
        scope(exit) stmt.close();

        auto rows = stmt.query(2).array.await;
        assert(rows.length == 1);
        assert(rows[0].column!int("id") == 2);
        assert(rows[0].column!string("name") == "two");

        // Execute again with different parameter
        rows = stmt.query(1).array.await;
        assert(rows.length == 1);
        assert(rows[0].column!int("id") == 1);
        assert(rows[0].column!string("name") == "one");
    }).awaitSync();
}

debug(ae_unittest) unittest
{
    import ae.net.asockets : socketManager;
    import ae.utils.promise.await : async, await, awaitSync;

    // Test: Prepared statement with multiple parameters
    async({
        auto db = new SqliteConnection(":memory:");
        await(db.ready);
        scope(exit) db.close();

        db.query("CREATE TABLE multi_param (a INTEGER, b INTEGER, c TEXT)").array.await;
        db.query("INSERT INTO multi_param VALUES (1, 10, 'x'), (2, 20, 'y'), (3, 30, 'z')").array.await;

        auto stmt = db.prepare("SELECT * FROM multi_param WHERE a > ? AND b < ?").await;
        scope(exit) stmt.close();

        auto rows = stmt.query(1, 25).array.await;
        assert(rows.length == 1);
        assert(rows[0].column!int("a") == 2);
    }).awaitSync();
}
