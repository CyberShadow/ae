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

      in {
        packages = {
          inherit mysql-test-bin psql-test-bin;
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
