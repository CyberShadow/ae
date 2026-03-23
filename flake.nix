{
  description = "ae library tests";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};

        # Common dub test function
        dubTest = { name, subpackage ? null, extraDeps ? [], extraFlags ? [] }:
          pkgs.stdenv.mkDerivation {
            name = "ae-${name}-test";

            nativeBuildInputs = [ pkgs.dub pkgs.ldc pkgs.git ] ++ extraDeps;
            dontStrip = true;

            # Don't use src = self; we need to set up the directory structure manually
            unpackPhase = ''
              cp -a ${self} ae
              chmod -R u+w ae
              cd ae
            '';

            buildPhase = ''
              export HOME="$TMPDIR"

              echo "Running ${name} tests..."
              dub test \
                --compiler=ldc2 \
                --debug=ae_unittest \
                ${if subpackage != null then ":${subpackage}" else ""} \
                ${builtins.concatStringsSep " " extraFlags}
              echo "${name} tests passed!"
            '';

            installPhase = ''
              touch $out
            '';
          };

        # ===========================================
        # Test Binaries (for integration tests that need server setup)
        # These use ldc2 directly because they need special version flags
        # ===========================================

        # MySQL test binary - needs HAVE_MYSQL_SERVER version flag
        mysql-test-bin = pkgs.stdenv.mkDerivation {
          name = "ae-mysql-test-bin";

          nativeBuildInputs = [ pkgs.ldc ];
          dontStrip = true;

          unpackPhase = ''
            cp -a ${self} ae
          '';

          buildPhase = ''
            echo "Compiling MySQL client tests..."

            # ASOCKETS_DEBUG_IDLE: DO NOT REMOVE - essential for detecting stuck event loops
            ldc2 \
              -i \
              -I. \
              -g \
              -d-debug=ae_unittest \
              -d-debug=ASOCKETS_DEBUG_IDLE \
              -d-version=HAVE_MYSQL_SERVER \
              -unittest \
              --main \
              -of=mysql_test \
              ae/net/db/mysql/package.d
          '';

          installPhase = ''
            mkdir -p $out/bin
            cp mysql_test $out/bin/
          '';
        };

        # PostgreSQL test binary - needs HAVE_PSQL_SERVER version flag
        psql-test-bin = pkgs.stdenv.mkDerivation {
          name = "ae-psql-test-bin";

          nativeBuildInputs = [ pkgs.ldc ];
          dontStrip = true;

          unpackPhase = ''
            cp -a ${self} ae
          '';

          buildPhase = ''
            echo "Compiling PostgreSQL client tests..."

            # ASOCKETS_DEBUG_IDLE: DO NOT REMOVE - essential for detecting stuck event loops
            ldc2 \
              -i \
              -I. \
              -g \
              -d-debug=ae_unittest \
              -d-debug=ASOCKETS_DEBUG_IDLE \
              -d-version=HAVE_PSQL_SERVER \
              -unittest \
              --main \
              -of=psql_test \
              ae/net/db/psql/package.d
          '';

          installPhase = ''
            mkdir -p $out/bin
            cp psql_test $out/bin/
          '';
        };

        # WebSocket test binary - needs HAVE_WS_PEER version flag and zlib
        websocket-test-bin = pkgs.stdenv.mkDerivation {
          name = "ae-websocket-test-bin";

          nativeBuildInputs = [ pkgs.ldc pkgs.zlib ];
          dontStrip = true;

          unpackPhase = ''
            cp -a ${self} ae
          '';

          buildPhase = ''
            echo "Compiling WebSocket tests..."

            # ASOCKETS_DEBUG_IDLE: DO NOT REMOVE - essential for detecting stuck event loops
            ldc2 \
              -i \
              -I. \
              -g \
              -d-debug=ae_unittest \
              -d-debug=ASOCKETS_DEBUG_IDLE \
              -d-version=HAVE_WS_PEER \
              -unittest \
              --main \
              -of=ws_test \
              -L=-lz \
              ae/net/http/websocket.d
          '';

          installPhase = ''
            mkdir -p $out/bin
            cp ws_test $out/bin/
          '';
        };

        # JSON-RPC integration test binary - needs HAVE_JSONRPC_PEER version flag
        jsonrpc-test-bin = pkgs.stdenv.mkDerivation {
          name = "ae-jsonrpc-test-bin";

          nativeBuildInputs = [ pkgs.ldc ];
          dontStrip = true;

          unpackPhase = ''
            cp -a ${self} ae
          '';

          buildPhase = ''
            echo "Compiling JSON-RPC integration tests..."

            # ASOCKETS_DEBUG_IDLE: DO NOT REMOVE - essential for detecting stuck event loops
            ldc2 \
              -i \
              -I. \
              -g \
              -d-debug=ae_unittest \
              -d-debug=ASOCKETS_DEBUG_IDLE \
              -d-version=HAVE_JSONRPC_PEER \
              -unittest \
              --main \
              -of=jsonrpc_test \
              ae/net/jsonrpc/binding.d
          '';

          installPhase = ''
            mkdir -p $out/bin
            cp jsonrpc_test $out/bin/
          '';
        };

        # Content-Length framing integration test binary - needs HAVE_CONTENTLENGTH_PEER version flag
        contentlength-test-bin = pkgs.stdenv.mkDerivation {
          name = "ae-contentlength-test-bin";

          nativeBuildInputs = [ pkgs.ldc ];
          dontStrip = true;

          unpackPhase = ''
            cp -a ${self} ae
          '';

          buildPhase = ''
            echo "Compiling Content-Length framing integration tests..."

            # ASOCKETS_DEBUG_IDLE: DO NOT REMOVE - essential for detecting stuck event loops
            ldc2 \
              -i \
              -I. \
              -g \
              -d-debug=ae_unittest \
              -d-debug=ASOCKETS_DEBUG_IDLE \
              -d-version=HAVE_CONTENTLENGTH_PEER \
              -unittest \
              --main \
              -of=contentlength_test \
              ae/net/jsonrpc/contentlength.d
          '';

          installPhase = ''
            mkdir -p $out/bin
            cp contentlength_test $out/bin/
          '';
        };

      in {
        packages = {
          inherit mysql-test-bin psql-test-bin websocket-test-bin jsonrpc-test-bin contentlength-test-bin;
        };

        checks = {
          # ===========================================
          # Unit Tests (using dub test)
          # ===========================================

          # Main library unit tests
          main = dubTest {
            name = "main";
          };

          # SQLite subpackage unit tests
          sqlite = dubTest {
            name = "sqlite";
            subpackage = "sqlite";
            extraDeps = [ pkgs.sqlite ];
          };

          # zlib subpackage unit tests
          zlib = dubTest {
            name = "zlib";
            subpackage = "zlib";
            extraDeps = [ pkgs.zlib ];
          };

          # ===========================================
          # Integration Tests (with database servers)
          # ===========================================

          # MySQL/MariaDB integration tests
          mysql = pkgs.stdenv.mkDerivation {
            name = "ae-mysql-test";
            src = self;

            nativeBuildInputs = [ pkgs.mariadb mysql-test-bin ];

            buildPhase = ''
              export HOME="$TMPDIR"
              export MYSQL_HOME="$TMPDIR"
              export MYSQL_DATADIR="$TMPDIR/mysql"
              export MYSQL_UNIX_PORT="$TMPDIR/mysql.sock"
              export MYSQL_HOST="127.0.0.1"
              export MYSQL_TCP_PORT="3306"
              export MYSQL_USER="testuser"
              export MYSQL_PWD="testpass"
              export MYSQL_DATABASE="testdb"

              echo "Initializing MariaDB..."
              mysql_install_db --datadir="$MYSQL_DATADIR" --auth-root-authentication-method=normal

              echo "Starting MariaDB..."
              mysqld --datadir="$MYSQL_DATADIR" --socket="$MYSQL_UNIX_PORT" --port="$MYSQL_TCP_PORT" --skip-networking=0 --bind-address=127.0.0.1 &
              MYSQL_PID=$!

              # Wait for server to start
              for i in $(seq 1 30); do
                if mysqladmin --socket="$MYSQL_UNIX_PORT" ping >/dev/null 2>&1; then
                  break
                fi
                sleep 1
              done

              echo "Creating test user and database..."
              MYSQL_PWD= mysql --socket="$MYSQL_UNIX_PORT" -u root <<EOF
              CREATE USER '$MYSQL_USER'@'localhost' IDENTIFIED BY '$MYSQL_PWD';
              CREATE USER '$MYSQL_USER'@'127.0.0.1' IDENTIFIED BY '$MYSQL_PWD';
              CREATE DATABASE $MYSQL_DATABASE;
              GRANT ALL ON $MYSQL_DATABASE.* TO '$MYSQL_USER'@'localhost';
              GRANT ALL ON $MYSQL_DATABASE.* TO '$MYSQL_USER'@'127.0.0.1';
              FLUSH PRIVILEGES;
              EOF

              echo "Testing TCP connectivity to MariaDB..."
              mysql -h 127.0.0.1 -P 3306 -u "$MYSQL_USER" -p"$MYSQL_PWD" -e "SELECT 1" "$MYSQL_DATABASE"

              echo "Running MySQL client tests..."
              mysql_test

              echo "Stopping MariaDB..."
              kill $MYSQL_PID || true
              wait $MYSQL_PID || true

              echo "MySQL tests passed!"
            '';

            installPhase = ''
              touch $out
            '';
          };

          # PostgreSQL integration tests
          psql = pkgs.stdenv.mkDerivation {
            name = "ae-psql-test";
            src = self;

            nativeBuildInputs = [ pkgs.postgresql psql-test-bin ];

            buildPhase = ''
              export HOME="$TMPDIR"
              export PGDATA="$TMPDIR/pgdata"
              export PGHOST="$TMPDIR"
              export PGUSER="testuser"
              export PGPASSWORD="testpass"
              export PGDATABASE="testdb"

              echo "Initializing PostgreSQL..."
              initdb -D "$PGDATA" --auth=trust --username=postgres

              cat >> "$PGDATA/postgresql.conf" <<EOF
              unix_socket_directories = '$TMPDIR'
              listen_addresses = 'localhost'
              port = 5432
              password_encryption = scram-sha-256
              EOF

              cat > "$PGDATA/pg_hba.conf" <<EOF
              # TYPE  DATABASE        USER            ADDRESS                 METHOD
              local   all             postgres                                trust
              local   all             all                                     scram-sha-256
              host    all             all             127.0.0.1/32            scram-sha-256
              host    all             all             ::1/128                 scram-sha-256
              EOF

              echo "Starting PostgreSQL..."
              pg_ctl -D "$PGDATA" -l "$PGDATA/logfile" start -w

              echo "Creating test user and database with SCRAM-SHA-256..."
              psql -h "$TMPDIR" -U postgres -d postgres -c "CREATE USER $PGUSER WITH PASSWORD '$PGPASSWORD';"
              psql -h "$TMPDIR" -U postgres -d postgres -c "CREATE DATABASE $PGDATABASE OWNER $PGUSER;"

              export PGHOST="localhost"

              echo "Running PostgreSQL client tests..."
              psql_test

              echo "Stopping PostgreSQL..."
              pg_ctl -D "$PGDATA" stop -m fast

              echo "PostgreSQL tests passed!"
            '';

            installPhase = ''
              touch $out
            '';
          };

          # WebSocket integration tests (with Python websockets peer)
          websocket = pkgs.stdenv.mkDerivation {
            name = "ae-websocket-test";
            src = self;

            nativeBuildInputs = [
              websocket-test-bin
              (pkgs.python3.withPackages (ps: [ ps.websockets ]))
            ];

            buildPhase = ''
              export HOME="$TMPDIR"

              echo "=== Phase 1: D client with Python server ==="

              # Start Python WebSocket echo server (permessage-deflate enabled by default)
              export WS_READY_FILE="$TMPDIR/py_ws1_ready"
              python3 << 'PYEOF' &
import asyncio, websockets, pathlib, os
async def echo(ws):
    async for msg in ws:
        await ws.send(msg)
async def main():
    async with websockets.serve(echo, "127.0.0.1", 18765):
        pathlib.Path(os.environ["WS_READY_FILE"]).write_text("ready")
        await asyncio.Future()
asyncio.run(main())
PYEOF
              PY_PID=$!

              for i in $(seq 1 30); do
                if [ -f "$WS_READY_FILE" ]; then break; fi
                sleep 0.5
              done

              echo "Python server ready, running D client test..."
              WS_TEST_MODE=client WS_SERVER_PORT=18765 ws_test
              echo "D client test passed!"

              if ! kill $PY_PID 2>/dev/null; then
                wait $PY_PID
                echo "FAIL: Python WebSocket server (phase 1) exited prematurely (exit code: $?)"
                exit 1
              fi
              wait $PY_PID 2>/dev/null || true

              echo "=== Phase 2: D server with Python client ==="

              # Start D WebSocket echo server
              WS_TEST_MODE=server WS_PORT=18766 WS_READY_FILE="$TMPDIR/ws_ready" ws_test &
              D_PID=$!

              # Wait for D server to be ready
              for i in $(seq 1 30); do
                if [ -f "$TMPDIR/ws_ready" ]; then
                  break
                fi
                sleep 0.5
              done

              echo "D server ready, running Python client test..."
              python3 << 'PYEOF'
import asyncio, websockets
async def main():
    async with websockets.connect("ws://127.0.0.1:18766") as ws:
        # Verify permessage-deflate was negotiated
        ext_names = [e.name for e in ws.protocol.extensions]
        assert "permessage-deflate" in ext_names, f"Expected permessage-deflate, got: {ext_names}"
        await ws.send("Hello from Python client")
        response = await ws.recv()
        assert response == b"Hello from Python client", f"Expected echo, got: {response!r}"
        print("Python client: echo verified with compression!")
asyncio.run(main())
PYEOF
              echo "Python client test passed!"

              # Wait for D server to exit (closes after client disconnects)
              wait $D_PID

              echo "=== Phase 3: D client with Python server (no_context_takeover) ==="

              # Start Python echo server with no_context_takeover
              export WS_READY_FILE="$TMPDIR/py_ws3_ready"
              python3 << 'PYEOF' &
import asyncio, websockets, pathlib, os
from websockets.extensions.permessage_deflate import ServerPerMessageDeflateFactory
async def echo(ws):
    async for msg in ws:
        await ws.send(msg)
async def main():
    async with websockets.serve(
        echo, "127.0.0.1", 18768,
        extensions=[ServerPerMessageDeflateFactory(
            server_no_context_takeover=True,
            client_no_context_takeover=True,
        )],
    ):
        pathlib.Path(os.environ["WS_READY_FILE"]).write_text("ready")
        await asyncio.Future()
asyncio.run(main())
PYEOF
              PY_PID=$!

              for i in $(seq 1 30); do
                if [ -f "$WS_READY_FILE" ]; then break; fi
                sleep 0.5
              done

              echo "Python server (no_context_takeover) ready, running D client test..."
              WS_TEST_MODE=client_nctx WS_SERVER_PORT=18768 ws_test
              echo "D client no_context_takeover test passed!"

              if ! kill $PY_PID 2>/dev/null; then
                wait $PY_PID
                echo "FAIL: Python WebSocket server (phase 3) exited prematurely (exit code: $?)"
                exit 1
              fi
              wait $PY_PID 2>/dev/null || true

              echo "=== Phase 4: D server with Python client (no_context_takeover) ==="

              WS_TEST_MODE=server_nctx WS_PORT=18767 WS_READY_FILE="$TMPDIR/ws_ready_nctx" ws_test &
              D_PID=$!

              for i in $(seq 1 30); do
                if [ -f "$TMPDIR/ws_ready_nctx" ]; then
                  break
                fi
                sleep 0.5
              done

              echo "D server ready, running Python client (no_context_takeover) test..."
              python3 << 'PYEOF'
import asyncio, websockets
from websockets.extensions.permessage_deflate import ClientPerMessageDeflateFactory
async def main():
    async with websockets.connect(
        "ws://127.0.0.1:18767",
        extensions=[ClientPerMessageDeflateFactory(
            server_no_context_takeover=True,
            client_no_context_takeover=True,
        )],
    ) as ws:
        ext_names = [e.name for e in ws.protocol.extensions]
        assert "permessage-deflate" in ext_names, f"Expected permessage-deflate, got: {ext_names}"
        messages = ["Message one", "Message two", "Message three"]
        for msg in messages:
            await ws.send(msg)
            response = await ws.recv()
            assert response == msg.encode(), f"Expected {msg!r}, got: {response!r}"
        print("Python client: no_context_takeover echo verified!")
asyncio.run(main())
PYEOF
              echo "Python client no_context_takeover test passed!"

              wait $D_PID
              echo "All WebSocket integration tests passed!"
            '';

            installPhase = ''
              touch $out
            '';
          };

          # JSON-RPC integration tests (with Python jsonrpclib-pelix peer)
          jsonrpc = pkgs.stdenv.mkDerivation {
            name = "ae-jsonrpc-test";
            src = self;

            nativeBuildInputs = [
              jsonrpc-test-bin
              (pkgs.python3.withPackages (ps: [ ps.jsonrpclib-pelix ]))
            ];

            buildPhase = ''
              export HOME="$TMPDIR"

              echo "=== Phase 1: D server with Python client ==="

              # Start D JSON-RPC server; it writes port to ready file when listening
              JSONRPC_TEST_MODE=server JSONRPC_READY_FILE="$TMPDIR/jsonrpc_ready" jsonrpc_test &
              D_PID=$!

              # Wait for D server to signal readiness (port written to file)
              for i in $(seq 1 30); do
                [ -f "$TMPDIR/jsonrpc_ready" ] && break; sleep 0.5
              done

              PORT=$(cat "$TMPDIR/jsonrpc_ready")

              python3 << PYEOF
import jsonrpclib
proxy = jsonrpclib.Server("http://127.0.0.1:$PORT")
result = proxy.add(2, 3)
assert result == 5, "positional add(2,3) failed: " + str(result)
result = proxy.add(a=10, b=7)
assert result == 17, "named add(a=10,b=7) failed: " + str(result)
result = proxy.addVec(x=3, y=4)
assert result == 7, "addVec(x=3,y=4) failed: " + str(result)
print("Phase 1: all assertions passed!")
PYEOF

              kill $D_PID || true
              wait $D_PID 2>/dev/null || true

              echo "=== Phase 2: Python server with D client ==="

              # Start Python JSON-RPC server; capture its port from stdout
              python3 << 'PYEOF' > "$TMPDIR/py_server_port" &
from jsonrpclib.SimpleJSONRPCServer import SimpleJSONRPCServer
server = SimpleJSONRPCServer(("127.0.0.1", 0), logRequests=False)
server.register_function(lambda a, b: a + b, "add")
print(server.server_address[1], flush=True)
server.serve_forever()
PYEOF
              PY_PID=$!

              # Wait for Python server to print its port
              for i in $(seq 1 30); do
                [ -s "$TMPDIR/py_server_port" ] && break; sleep 0.5
              done

              PY_PORT=$(cat "$TMPDIR/py_server_port")

              JSONRPC_TEST_MODE=client JSONRPC_SERVER_PORT="$PY_PORT" jsonrpc_test

              kill $PY_PID || true
              wait $PY_PID 2>/dev/null || true

              echo "All JSON-RPC integration tests passed!"
            '';

            installPhase = ''
              touch $out
            '';
          };

          # Content-Length framing integration tests (with Python python-lsp-jsonrpc peer)
          contentlength = pkgs.stdenv.mkDerivation {
            name = "ae-contentlength-test";
            src = self;

            nativeBuildInputs = [
              contentlength-test-bin
              (pkgs.python3.withPackages (ps: [ ps.python-lsp-jsonrpc ]))
            ];

            buildPhase = ''
              export HOME="$TMPDIR"

              echo "=== Phase 1: D server with Python client ==="

              # Start D JSON-RPC server with Content-Length framing over TCP
              CL_TEST_MODE=server CL_READY_FILE="$TMPDIR/cl_ready" contentlength_test &
              D_PID=$!

              # Wait for D server to signal readiness (port written to file)
              for i in $(seq 1 30); do
                [ -f "$TMPDIR/cl_ready" ] && break; sleep 0.5
              done

              PORT=$(cat "$TMPDIR/cl_ready")

              python3 << PYEOF
import socket, threading
from pylsp_jsonrpc.streams import JsonRpcStreamReader, JsonRpcStreamWriter
from pylsp_jsonrpc.endpoint import Endpoint

sock = socket.socket()
sock.connect(("127.0.0.1", $PORT))
rfile = sock.makefile("rb")
wfile = sock.makefile("wb")

writer = JsonRpcStreamWriter(wfile)
endpoint = Endpoint({}, writer.write)

reader = JsonRpcStreamReader(rfile)
t = threading.Thread(target=reader.listen, args=(endpoint.consume,), daemon=True)
t.start()

f1 = endpoint.request("add", [2, 3])
assert f1.result(timeout=5) == 5, f"Expected 5, got {f1.result()}"

f2 = endpoint.request("add", [10, 7])
assert f2.result(timeout=5) == 17, f"Expected 17, got {f2.result()}"

print("Phase 1: all assertions passed!")
sock.close()
PYEOF

              kill $D_PID || true
              wait $D_PID 2>/dev/null || true

              echo "=== Phase 2: Python server with D client ==="

              # Start Python JSON-RPC server with Content-Length framing over TCP
              python3 << 'PYEOF' > "$TMPDIR/py_server_port" &
import socket, threading
from pylsp_jsonrpc.streams import JsonRpcStreamReader, JsonRpcStreamWriter
from pylsp_jsonrpc.endpoint import Endpoint

sock = socket.socket()
sock.bind(("127.0.0.1", 0))
sock.listen(1)
print(sock.getsockname()[1], flush=True)

conn, _ = sock.accept()
rfile = conn.makefile("rb")
wfile = conn.makefile("wb")

writer = JsonRpcStreamWriter(wfile)

def add_handler(params):
    return params[0] + params[1]

endpoint = Endpoint({"add": add_handler}, writer.write)

reader = JsonRpcStreamReader(rfile)
reader.listen(endpoint.consume)
PYEOF
              PY_PID=$!

              # Wait for Python server to print its port
              for i in $(seq 1 30); do
                [ -s "$TMPDIR/py_server_port" ] && break; sleep 0.5
              done

              PY_PORT=$(cat "$TMPDIR/py_server_port")

              CL_TEST_MODE=client CL_SERVER_PORT="$PY_PORT" contentlength_test

              kill $PY_PID || true
              wait $PY_PID 2>/dev/null || true

              echo "All Content-Length framing integration tests passed!"
            '';

            installPhase = ''
              touch $out
            '';
          };
        };

        devShells.default = pkgs.mkShell {
          buildInputs = [
            pkgs.dub
            pkgs.ldc
            pkgs.git
            pkgs.postgresql
            pkgs.mariadb
            pkgs.sqlite
            pkgs.zlib
          ];
        };
      }
    );
}
