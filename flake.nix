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
      in {
        checks = {
          psql = pkgs.stdenv.mkDerivation {
            name = "ae-psql-test";
            src = self;

            nativeBuildInputs = [ pkgs.postgresql pkgs.ldc ];

            # Keep debug symbols for meaningful stack traces
            dontStrip = true;

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

              echo "Compiling and running PostgreSQL client tests..."
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
                -of="$TMPDIR/psql_test" \
                net/db/psql/package.d

              "$TMPDIR/psql_test"

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
