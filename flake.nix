{
  description = "ae library integration tests";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};

        # Build MySQL test binary separately
        mysql-test-bin = pkgs.stdenv.mkDerivation {
          name = "ae-mysql-test-bin";
          src = self;

          nativeBuildInputs = [ pkgs.ldc ];

          # Keep debug symbols for meaningful stack traces
          dontStrip = true;

          buildPhase = ''
            echo "Compiling MySQL client tests..."
            mkdir -p "$TMPDIR/ae-parent"
            ln -s "$src" "$TMPDIR/ae-parent/ae"

            # ASOCKETS_DEBUG_IDLE: DO NOT REMOVE - essential for detecting stuck event loops
            ldc2 \
              -i \
              -I"$TMPDIR/ae-parent" \
              -g \
              -d-debug=ae_unittest \
              -d-debug=ASOCKETS_DEBUG_IDLE \
              -d-version=HAVE_MYSQL_SERVER \
              -unittest \
              --main \
              -of=mysql_test \
              net/db/mysql/package.d
          '';

          installPhase = ''
            mkdir -p $out/bin
            cp mysql_test $out/bin/
          '';
        };

        # Build PostgreSQL test binary separately
        psql-test-bin = pkgs.stdenv.mkDerivation {
          name = "ae-psql-test-bin";
          src = self;

          nativeBuildInputs = [ pkgs.ldc ];

          # Keep debug symbols for meaningful stack traces
          dontStrip = true;

          buildPhase = ''
            echo "Compiling PostgreSQL client tests..."
            mkdir -p "$TMPDIR/ae-parent"
            ln -s "$src" "$TMPDIR/ae-parent/ae"

            ldc2 \
              -i \
              -I"$TMPDIR/ae-parent" \
              -g \
              -d-debug=ae_unittest \
              -d-version=HAVE_PSQL_SERVER \
              -unittest \
              --main \
              -of=psql_test \
              net/db/psql/package.d
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
              # Temporarily unset MYSQL_PWD for root connection
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

          psql = pkgs.stdenv.mkDerivation {
            name = "ae-psql-test";
            src = self;

            nativeBuildInputs = [ pkgs.postgresql psql-test-bin ];

            # Localhost TCP connections work within the sandbox

            buildPhase = ''
              export HOME="$TMPDIR"
              export PGDATA="$TMPDIR/pgdata"
              export PGHOST="$TMPDIR"
              export PGUSER="testuser"
              export PGPASSWORD="testpass"
              export PGDATABASE="testdb"

              echo "Initializing PostgreSQL..."
              # Initialize with trust auth for initial setup, then switch to scram-sha-256
              initdb -D "$PGDATA" --auth=trust --username=postgres

              cat >> "$PGDATA/postgresql.conf" <<EOF
              unix_socket_directories = '$TMPDIR'
              listen_addresses = 'localhost'
              port = 5432
              password_encryption = scram-sha-256
              EOF

              # Configure pg_hba.conf to use scram-sha-256 for TCP connections
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
              # Create user with password using postgres superuser (trust auth on local socket)
              psql -h "$TMPDIR" -U postgres -d postgres -c "CREATE USER $PGUSER WITH PASSWORD '$PGPASSWORD';"
              psql -h "$TMPDIR" -U postgres -d postgres -c "CREATE DATABASE $PGDATABASE OWNER $PGUSER;"

              # Set PGHOST to localhost for TCP connections in the D test
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
          buildInputs = [ pkgs.ldc pkgs.postgresql ];
        };
      }
    );
}
