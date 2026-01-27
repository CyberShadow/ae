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

            # Localhost TCP connections work within the sandbox

            buildPhase = ''
              export HOME="$TMPDIR"
              export PGDATA="$TMPDIR/pgdata"
              export PGHOST="$TMPDIR"
              export PGUSER="testuser"
              export PGPASSWORD="testpass"
              export PGDATABASE="testdb"

              echo "Initializing PostgreSQL..."
              initdb -D "$PGDATA" --auth=trust -U "$PGUSER"

              cat >> "$PGDATA/postgresql.conf" <<EOF
              unix_socket_directories = '$TMPDIR'
              listen_addresses = 'localhost'
              port = 5432
              EOF

              echo "Starting PostgreSQL..."
              pg_ctl -D "$PGDATA" -l "$PGDATA/logfile" start -w

              echo "Creating test database..."
              createdb -h "$TMPDIR" -U "$PGUSER" "$PGDATABASE"

              # Set PGHOST to localhost for TCP connections in the D test
              export PGHOST="localhost"

              echo "Compiling and running PostgreSQL client tests..."
              mkdir -p "$TMPDIR/ae-parent"
              ln -s "$src" "$TMPDIR/ae-parent/ae"

              ldc2 \
                -i \
                -I"$TMPDIR/ae-parent" \
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
