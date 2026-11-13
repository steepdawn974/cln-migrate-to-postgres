#!/bin/bash

# MIT License
#
# Copyright (c) 2025 Core Lightning Migration Script
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

# SQLite to PostgreSQL Migration Script for Core Lightning
# Migrates Core Lightning SQLite database to PostgreSQL with pgloader
#
# Tested against Core Lightning v26.06.10 (schema version 284).
# The target schema is created from CLN's own PostgreSQL DDL
# (schema/cln_v26.06.10_schema.sql, dumped from a working lightningd
# postgres wallet) so that tables, sequences, indexes and constraints
# match what lightningd expects; pgloader then copies data only.

set -euo pipefail

# Global variables
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SQLITE_FILE=""
PG_DB_NAME=""
PG_USER=""
PG_SUPERUSER=""
PG_SUPERUSER_PASSWORD=""
PG_HOST=""
PG_PORT=""
USE_SOCKET=false
SOCKET_PATH="/var/run/postgresql"
SCHEMA_FILE="$SCRIPT_DIR/schema/cln_v26.06.10_schema.sql"
SQLITE_WORK_FILE=""
MIGRATION_TMPDIR=""
# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

# Function to display usage information
show_usage() {
    cat << EOF
Usage: $0 <sqlite_file> <pg_database> [options]

Required arguments:
  sqlite_file    Path to the SQLite database file
  pg_database    Name of the target PostgreSQL database

Optional arguments:
  -u, --user USER           PostgreSQL lightning application user (default: lightning)
  -a, --apppass PASS        Password for the application user (will prompt if not provided)
  -s, --superuser USER      PostgreSQL superuser for database creation (default: postgres)
  -S, --superpass PASS      PostgreSQL superuser password (will prompt if not provided)
  -h, --host HOST           PostgreSQL host (default: localhost)
  -P, --port PORT           PostgreSQL port (default: 5432)
  --socket PATH             Use UNIX socket instead of TCP (default: /var/run/postgresql)
  --schema FILE             CLN PostgreSQL schema to create before loading data
                            (default: schema/cln_v26.06.10_schema.sql next to this script)
  --help                    Show this help message

Examples:
  $0 ~/.lightning/lightningd.sqlite3 lightningd
  $0 /path/to/db.sqlite3 lightningd -u lightning_user -s postgres -S super_pass
  $0 db.sqlite3 lightningd --superuser admin --superpass admin123
  $0 db.sqlite3 lightningd --socket /var/run/postgresql -a app_pass

EOF
}

# Function to parse command line arguments
parse_arguments() {
    if [[ $# -lt 2 ]]; then
        log_error "Insufficient arguments"
        show_usage
        exit 1
    fi

    if [[ "$1" == "--help" ]] || [[ "$1" == "-h" ]]; then
        show_usage
        exit 0
    fi

    SQLITE_FILE="$1"
    PG_DB_NAME="$2"
    shift 2

    # Set defaults
    PG_USER="lightning"
    PG_SUPERUSER="postgres"
    PG_HOST="localhost"
    PG_PORT="5432"
    LIGHTNING_PASSWORD=""

    # Parse optional arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            -u|--user)
                PG_USER="$2"
                shift 2
                ;;
            -a|--apppass)
                LIGHTNING_PASSWORD="$2"
                shift 2
                ;;
            -s|--superuser)
                PG_SUPERUSER="$2"
                shift 2
                ;;
            -S|--superpass)
                PG_SUPERUSER_PASSWORD="$2"
                shift 2
                ;;
            -h|--host)
                PG_HOST="$2"
                shift 2
                ;;
            -P|--port)
                PG_PORT="$2"
                shift 2
                ;;
            --socket)
                USE_SOCKET=true
                SOCKET_PATH="$2"
                shift 2
                ;;
            --schema)
                SCHEMA_FILE="$2"
                shift 2
                ;;
            *)
                log_error "Unknown option: $1"
                show_usage
                exit 1
                ;;
        esac
    done

    # Validate required arguments
    if [[ -z "$SQLITE_FILE" ]]; then
        log_error "SQLite file path is required"
        exit 1
    fi

    if [[ -z "$PG_DB_NAME" ]]; then
        log_error "PostgreSQL database name is required"
        exit 1
    fi

    # Check if SQLite file exists
    if [[ ! -f "$SQLITE_FILE" ]]; then
        log_error "SQLite file not found: $SQLITE_FILE"
        exit 1
    fi

    # Normalize to an absolute path so the pgloader sqlite:// URI is valid
    SQLITE_FILE="$(readlink -f "$SQLITE_FILE")"

    # Check if the CLN PostgreSQL schema file exists
    if [[ ! -f "$SCHEMA_FILE" ]]; then
        log_error "PostgreSQL schema file not found: $SCHEMA_FILE"
        log_error "Provide one with --schema, or regenerate it from a running"
        log_error "lightningd postgres wallet: pg_dump --schema-only --no-owner --no-privileges"
        exit 1
    fi

    # Prompt for superuser password if not provided
    if [[ "$USE_SOCKET" == false && -z "$PG_SUPERUSER_PASSWORD" ]]; then
        read -s -p "Enter PostgreSQL password for superuser '$PG_SUPERUSER': " PG_SUPERUSER_PASSWORD
        echo
    fi

    log_info "Configuration:"
    log_info "  SQLite file: $SQLITE_FILE"
    log_info "  Schema file: $SCHEMA_FILE"
    log_info "  PostgreSQL database: $PG_DB_NAME"
    log_info "  Application user: $PG_USER"
    log_info "  Superuser: $PG_SUPERUSER"
    if [[ "$USE_SOCKET" == true ]]; then
        log_info "  Using UNIX socket: $SOCKET_PATH"
    else
        log_info "  PostgreSQL host: $PG_HOST:$PG_PORT"
    fi
}

# Function to set up PostgreSQL connection parameters
setup_connection_params() {
    local pg_host="$1"
    local pg_port="$2"
    local use_socket="$3"
    local socket_path="$4"
    
    local conn_params=""
    if [[ "$use_socket" == true ]]; then
        conn_params="-h $socket_path"
    else
        conn_params="-h $pg_host -p $pg_port"
    fi
    
    echo "$conn_params"
}

# Function to set up PostgreSQL password environment variable for superuser
setup_password_env() {
    if [[ -n "$PG_SUPERUSER_PASSWORD" ]]; then
        export PGPASSWORD="$PG_SUPERUSER_PASSWORD"
    fi
}

# Function to prompt for application user password interactively
prompt_lightning_password() {
    local password1=""
    local password2=""

    # Skip the prompt when a password was already provided via --apppass
    if [[ -n "$LIGHTNING_PASSWORD" ]]; then
        return 0
    fi

    echo
    log_info "Application user '$PG_USER' will be created/used for the database."
    log_info "Please set a password for this user:"

    while true; do
        read -s -p "Enter password for application user '$PG_USER': " password1
        echo
        read -s -p "Confirm password: " password2
        echo
        
        if [[ -z "$password1" ]]; then
            log_error "Password cannot be empty. Please try again."
            continue
        fi
        
        if [[ "$password1" != "$password2" ]]; then
            log_error "Passwords do not match. Please try again."
            continue
        fi
        
        break
    done
    
    LIGHTNING_PASSWORD="$password1"
    log_success "Application user password set"
}

# Function to check if psql client is installed
check_psql_client() {
    log_info "Checking for psql client installation..."
    
    # Check if psql is available
    if command -v psql >/dev/null 2>&1; then
        local psql_version
        psql_version=$(psql --version 2>/dev/null | head -n1 || echo "unknown")
        log_success "psql client is available: $psql_version"
        return 0
    fi
    
    log_error "psql client is not installed"
    log_error "psql client is required for this migration script"
    log_error ""
    log_error "Please install psql client manually:"
    log_error "  Ubuntu/Debian: sudo apt-get install postgresql-client"
    log_error "  CentOS/RHEL: sudo yum install postgresql"
    log_error "  Arch Linux: sudo pacman -S postgresql"
    log_error "  macOS: brew install postgresql"
    log_error ""
    log_error "Note: psql client must be installed on the script host machine,"
    log_error "      even if PostgreSQL server is running on a different host."
    return 1
}

# Function to validate SQLite database and check schema version
validate_sqlite_database() {
    local sqlite_file="$1"
    local schema_version
    
    log_info "Validating SQLite database: $sqlite_file"
    
    # Check if file is readable
    if [[ ! -r "$sqlite_file" ]]; then
        log_error "SQLite file is not readable: $sqlite_file"
        return 1
    fi
    
    # Check if it's a valid SQLite database
    if ! sqlite3 "$sqlite_file" "SELECT 1;" >/dev/null 2>&1; then
        log_error "Invalid SQLite database file: $sqlite_file"
        return 1
    fi
    
    # Get schema version (for informational purposes only)
    schema_version=$(sqlite3 "$sqlite_file" "SELECT version FROM version;" 2>/dev/null || echo "")
    
    if [[ -z "$schema_version" ]]; then
        log_error "Could not determine schema version from SQLite database"
        return 1
    fi
    
    log_info "Current schema version: $schema_version"
    log_info "Note: The bundled PostgreSQL schema matches CLN v26.06.10 (db version 284)."
    log_info "      For other versions, dump a fresh schema with --schema (see --help)."
    
    # Get list of tables for verification later
    log_info "Enumerating tables in SQLite database..."
    sqlite3 "$sqlite_file" ".tables" | while read -r table; do
        if [[ -n "$table" ]]; then
            log_info "  Found table: $table"
        fi
    done
    
    log_success "SQLite database validation completed"
    return 0
}

# Function to check PostgreSQL server connectivity
check_postgresql_server() {
    local pg_host="$1"
    local pg_port="$2"
    local pg_user="$3"
    local use_socket="$4"
    local socket_path="$5"
    
    log_info "Checking PostgreSQL server connectivity..."
    
    # Set connection parameters using helper function
    local conn_params
    conn_params=$(setup_connection_params "$pg_host" "$pg_port" "$use_socket" "$socket_path")
    
    if [[ "$use_socket" == true ]]; then
        log_info "  Using UNIX socket: $socket_path"
    else
        log_info "  Using TCP connection: $pg_host:$pg_port"
    fi
    
    # Set password environment variable
    setup_password_env
    
    # Test basic connectivity with superuser
    if ! psql $conn_params -U "$PG_SUPERUSER" -d postgres -c "SELECT 1;" >/dev/null 2>&1; then
        log_error "Cannot connect to PostgreSQL server as superuser '$PG_SUPERUSER'"
        log_error "  Please ensure PostgreSQL is running and accessible"
        log_error "  Connection details: Superuser: $PG_SUPERUSER, $conn_params"
        return 1
    fi
    
    # Get PostgreSQL version
    local pg_version
    pg_version=$(psql $conn_params -U "$PG_SUPERUSER" -d postgres -t -c "SELECT version();" 2>/dev/null | xargs)
    log_info "PostgreSQL version: $pg_version"
    
    # Check if superuser has necessary privileges
    if ! psql $conn_params -U "$PG_SUPERUSER" -d postgres -c "SELECT 1;" >/dev/null 2>&1; then
        log_error "Superuser '$PG_SUPERUSER' does not have sufficient privileges"
        return 1
    fi
    
    # Check if superuser can create databases
    local can_create_db
    can_create_db=$(psql $conn_params -U "$PG_SUPERUSER" -d postgres -t -c "SELECT 1 FROM pg_roles WHERE rolname = '$PG_SUPERUSER' AND rolcreatedb;" 2>/dev/null | xargs)
    
    if [[ -z "$can_create_db" ]]; then
        log_error "Superuser '$PG_SUPERUSER' does not have database creation privileges"
        log_error "  Migration requires a superuser with CREATEDB privileges"
        return 1
    fi
    
    log_success "PostgreSQL server is accessible with superuser '$PG_SUPERUSER'"
    return 0
}

# Function to build pgloader from source
build_pgloader_from_source() {
    log_info "Building pgloader from source in /tmp..."
    
    local build_dir="/tmp/pgloader_build"
    
    # Clean up any previous build
    rm -rf "$build_dir"
    
    # Clone the repository
    if ! git clone https://github.com/darold/pgloader.git "$build_dir"; then
        log_error "Failed to clone pgloader repository"
        return 1
    fi
    
    cd "$build_dir"
    
    # Check if required dependencies are available
    if ! command -v sbcl >/dev/null 2>&1; then
        log_error "SBCL is required to build pgloader from source"
        log_error "Install it with: sudo pacman -S sbcl"
        return 1
    fi
    
    # Install additional build dependencies for Arch/Manjaro
    log_info "Installing build dependencies..."
    if ! sudo pacman -S --needed --noconfirm make curl gawk freetds sqlite; then
        log_warn "Some dependencies may already be installed, continuing..."
    fi
    
    # Build pgloader using modern build system
    log_info "Building pgloader with 'make save' (this may take a while)..."
    if make save; then
        log_info "Installing pgloader to /usr/local/bin..."
        if sudo cp build/bin/pgloader /usr/local/bin/ && sudo chmod +x /usr/local/bin/pgloader; then
            log_success "pgloader installed successfully from source"
            log_info "Testing installation..."
            if /usr/local/bin/pgloader --version >/dev/null 2>&1; then
                log_success "pgloader is working correctly"
            else
                log_warn "pgloader installed but may not be working properly"
            fi
            cd - >/dev/null
            rm -rf "$build_dir"
            return 0
        else
            log_error "Failed to install pgloader to /usr/local/bin"
            return 1
        fi
    else
        log_error "Failed to build pgloader from source"
        log_info "You can also try the legacy build system: make pgloader"
        return 1
    fi
}

# Function to install pgloader if not present
install_pgloader() {
    log_info "Checking for pgloader installation..."
    
    # Check if pgloader is already installed
    if command -v pgloader >/dev/null 2>&1; then
        local pgloader_version
        pgloader_version=$(pgloader --version 2>/dev/null | head -n1 || echo "unknown")
        log_success "pgloader is already installed: $pgloader_version"
        return 0
    fi
    
    log_warn "pgloader is not installed. Attempting to install..."
    
    # Detect package manager and install pgloader
    if command -v apt >/dev/null 2>&1; then
        log_info "Using apt package manager..."
        if sudo apt update && sudo apt install -y pgloader; then
            log_success "pgloader installed successfully via apt"
            return 0
        else
            log_error "Failed to install pgloader via apt"
            return 1
        fi
    elif command -v yum >/dev/null 2>&1; then
        log_info "Using yum package manager..."
        if sudo yum install -y epel-release && sudo yum install -y pgloader; then
            log_success "pgloader installed successfully via yum"
            return 0
        else
            log_error "Failed to install pgloader via yum"
            return 1
        fi
    elif command -v dnf >/dev/null 2>&1; then
        log_info "Using dnf package manager..."
        if sudo dnf install -y pgloader; then
            log_success "pgloader installed successfully via dnf"
            return 0
        else
            log_error "Failed to install pgloader via dnf"
            return 1
        fi
    elif command -v brew >/dev/null 2>&1; then
        log_info "Using Homebrew package manager..."
        if brew install pgloader; then
            log_success "pgloader installed successfully via Homebrew"
            return 0
        else
            log_error "Failed to install pgloader via Homebrew"
            return 1
        fi
    else
        log_error "No supported package manager found"
        log_info "Attempting to build pgloader from source..."
        if build_pgloader_from_source; then
            log_success "pgloader built and installed successfully from source"
            return 0
        else
            log_error "Please install pgloader manually:"
            log_error "  Ubuntu/Debian: sudo apt-get install pgloader"
            log_error "  CentOS/RHEL: Use yum.postgresql.org repository"
            log_error "  Arch Linux: yay -S pgloader (AUR)"
            log_error "  macOS: brew install pgloader"
            log_error "  Build from source: https://pgloader.readthedocs.io/en/latest/install.html"
            return 1
        fi
    fi
}

# Function to create or replace PostgreSQL database
setup_postgresql_database() {
    local pg_host="$1"
    local pg_port="$2"
    local pg_user="$3"
    local pg_db_name="$4"
    local use_socket="$5"
    local socket_path="$6"
    
    log_info "Setting up PostgreSQL database: $pg_db_name"
    
    # Set connection parameters using helper function
    local conn_params
    conn_params=$(setup_connection_params "$pg_host" "$pg_port" "$use_socket" "$socket_path")
    
    # Check if database already exists
    local db_exists
    db_exists=$(psql $conn_params -U "$PG_SUPERUSER" -d postgres -t -c "SELECT 1 FROM pg_database WHERE datname = '$pg_db_name';" 2>/dev/null | xargs)
    
    if [[ -n "$db_exists" ]]; then
        log_warn "Database '$pg_db_name' already exists"
        read -p "Do you want to drop and recreate it? This will delete all data. (y/N): " confirm || confirm=""
        if [[ "$confirm" =~ ^[yY]$ ]]; then
            log_info "Dropping existing database..."
            if ! psql $conn_params -U "$PG_SUPERUSER" -d postgres -c "DROP DATABASE IF EXISTS \"$pg_db_name\";"; then
                log_error "Failed to drop existing database"
                return 1
            fi
        else
            log_info "Using existing database '$pg_db_name'"
            return 0
        fi
    fi

    # Create database with superuser
    log_info "Creating database '$pg_db_name' with superuser '$PG_SUPERUSER'..."
    if ! psql $conn_params -U "$PG_SUPERUSER" -d postgres -c "CREATE DATABASE \"$pg_db_name\";"; then
        log_error "Failed to create database"
        return 1
    fi
    
    log_success "PostgreSQL database setup completed"
    return 0
}

# Function to create application user and transfer ownership at the end
create_application_user() {
    local pg_host="$1"
    local pg_port="$2"
    local pg_user="$3"
    local pg_db_name="$4"
    local use_socket="$5"
    local socket_path="$6"
    
    log_info "Creating application user and transferring ownership..."
    
    # Set connection parameters using helper function
    local conn_params
    conn_params=$(setup_connection_params "$pg_host" "$pg_port" "$use_socket" "$socket_path")
    
    # Check if user already exists
    local user_exists
    user_exists=$(psql $conn_params -U "$PG_SUPERUSER" -d postgres -t -c "SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = '$pg_user';" 2>/dev/null | xargs)
    
    if [[ -z "$user_exists" ]]; then
        # User doesn't exist, prompt for password and create
        prompt_lightning_password
        
        if ! psql $conn_params -U "$PG_SUPERUSER" -d postgres -c "CREATE ROLE $pg_user LOGIN PASSWORD '$LIGHTNING_PASSWORD';"; then
            log_error "Failed to create application user"
            return 1
        fi
        log_success "Application user '$pg_user' created successfully"
    else
        log_info "Application user '$pg_user' already exists"
        
        # Prompt for password to update it if needed
        prompt_lightning_password
        
        # Update the user's password
        if ! psql $conn_params -U "$PG_SUPERUSER" -d postgres -c "ALTER USER $pg_user PASSWORD '$LIGHTNING_PASSWORD';" >/dev/null 2>&1; then
            log_warn "Could not update application user password (continuing)"
        fi
    fi
    
    log_info "Granting database '$pg_db_name' ownership to application user '$pg_user'..."
    if ! psql $conn_params -U "$PG_SUPERUSER" -d postgres -c "ALTER DATABASE \"$pg_db_name\" OWNER TO \"$pg_user\";" >/dev/null 2>&1; then
        log_error "Failed to grant database ownership"
        return 1
    fi
    
    log_info "Granting schema 'public' permissions to application user '$pg_user'..."
    if ! psql $conn_params -U "$PG_SUPERUSER" -d "$pg_db_name" -c "GRANT ALL ON SCHEMA public TO $pg_user;" >/dev/null 2>&1; then
        log_error "Failed to grant schema permissions"
        return 1
    fi
    
    log_info "Granting table permissions to application user '$pg_user'..."
    if ! psql $conn_params -U "$PG_SUPERUSER" -d "$pg_db_name" -c "GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO $pg_user;" >/dev/null 2>&1; then
        log_error "Failed to grant table permissions"
        return 1
    fi

    log_info "Granting sequence permissions to application user '$pg_user'..."
    if ! psql $conn_params -U "$PG_SUPERUSER" -d "$pg_db_name" -c "GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO $pg_user;" >/dev/null 2>&1; then
        log_error "Failed to grant sequence permissions"
        return 1
    fi

    # Grant permissions on all future tables and sequences
    if ! psql $conn_params -U "$PG_SUPERUSER" -d "$pg_db_name" -c "ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO $pg_user; ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO $pg_user;" >/dev/null 2>&1; then
        log_warn "Could not set default privileges (continuing)"
    fi
    
    log_success "Application user setup completed"
    return 0
}

# Function to verify database exists (schema creation handled by pgloader)
verify_database_exists() {
    local pg_host="$1"
    local pg_port="$2"
    local pg_user="$3"
    local pg_db_name="$4"
    local use_socket="$5"
    local socket_path="$6"
    
    log_info "Verifying database exists for pgloader migration..."
    
    # Set connection parameters using helper function
    local conn_params
    conn_params=$(setup_connection_params "$pg_host" "$pg_port" "$use_socket" "$socket_path")
    
    # Check if database exists
    local db_exists
    db_exists=$(psql $conn_params -U "$PG_SUPERUSER" -d postgres -t -c "SELECT 1 FROM pg_database WHERE datname = '$pg_db_name';" 2>/dev/null | xargs)
    
    if [[ -z "$db_exists" ]]; then
        log_error "Database '$pg_db_name' does not exist. Run setup first."
        return 1
    fi
    
    log_success "Database '$pg_db_name' is ready for pgloader migration"
    return 0
}

# Function to create the CLN schema from the bundled PostgreSQL DDL dump
apply_cln_schema() {
    local pg_host="$1"
    local pg_port="$2"
    local pg_db_name="$3"
    local use_socket="$4"
    local socket_path="$5"

    log_info "Creating CLN schema from $SCHEMA_FILE ..."

    local conn_params
    conn_params=$(setup_connection_params "$pg_host" "$pg_port" "$use_socket" "$socket_path")

    if ! psql $conn_params -U "$PG_SUPERUSER" -d "$pg_db_name" -v ON_ERROR_STOP=1 -f "$SCHEMA_FILE"; then
        log_error "Failed to apply CLN schema"
        return 1
    fi

    log_success "CLN schema created"
    return 0
}

# Function to reset all column-owned sequences to MAX(col)+1 after data load.
# pgloader's 'reset sequences' option does not fire in data-only mode, so
# this step is required for subsequent inserts (channel/invoice/payment ids).
reset_sequences() {
    local pg_host="$1"
    local pg_port="$2"
    local pg_db_name="$3"
    local use_socket="$4"
    local socket_path="$5"

    log_info "Resetting sequences to match migrated data..."

    local conn_params
    conn_params=$(setup_connection_params "$pg_host" "$pg_port" "$use_socket" "$socket_path")

    psql $conn_params -U "$PG_SUPERUSER" -d "$pg_db_name" -v ON_ERROR_STOP=1 <<'EOSQL'
DO $$
DECLARE r RECORD;
BEGIN
    FOR r IN
        SELECT s.relname AS seq, t.relname AS tbl, a.attname AS col
        FROM pg_class s
        JOIN pg_depend d ON d.objid = s.oid AND d.deptype = 'a'
        JOIN pg_class t ON t.oid = d.refobjid
        JOIN pg_attribute a ON a.attrelid = t.oid AND a.attnum = d.refobjsubid
        JOIN pg_namespace n ON n.oid = s.relnamespace
        WHERE s.relkind = 'S' AND n.nspname = 'public'
    LOOP
        EXECUTE format(
            'SELECT setval(%L, COALESCE((SELECT MAX(%I) FROM public.%I), 0) + 1, false)',
            r.seq, r.col, r.tbl);
    END LOOP;
END $$;
EOSQL

    log_success "Sequences reset"
    return 0
}

# Function to create a working copy of the SQLite file with out-of-fixnum
# integer values rewritten as TEXT.
#
# CLN stores unsigned 64-bit values (scid aliases, group ids) as signed
# int64 in SQLite INTEGER columns. Values beyond SBCL's fixnum range
# (+-2^62) crash pgloader's integer-string transform and the whole row —
# in practice the whole table — is lost. Cells cannot simply be UPDATEd
# to text because INTEGER column affinity converts them straight back,
# so affected tables are rebuilt with those columns declared TEXT. The
# stored values then arrive at pgloader as strings; its transform parses
# them as bignums and emits decimal strings that PostgreSQL bigint
# accepts with identical signed values.
# Helper: check whether the bundled pg schema defines column $2 on table $1
pg_schema_has_column() {
    awk -v start="CREATE TABLE public.$1 (" -v col="$2" '
        index($0, start) == 1 {inside=1; next}
        inside && /^\);/ {inside=0}
        inside && ($1 == col || $1 == "\"" col "\"") {found=1; exit}
        END {exit !found}' "$SCHEMA_FILE"
}

prepare_sqlite_workfile() {
    local sqlite_file="$1"
    local work_dir="$2"

    local fixnum_max=4611686018427387903
    local fixnum_min=-4611686018427387904

    # VACUUM INTO produces a consistent copy without writing to the source
    # and also repairs freelist/index inconsistencies typically found in
    # backups copied from a live node (writes into a corrupted freelist
    # would fail with "database disk image is malformed").
    if ! sqlite3 "$sqlite_file" "VACUUM INTO '$work_dir/source.sqlite3';"; then
        log_warn "VACUUM INTO failed (read-only source?), copying then vacuuming..."
        cp --reflink=auto -- "$sqlite_file" "$work_dir/source.sqlite3"
        sqlite3 "$work_dir/source.sqlite3" "VACUUM;"
    fi
    SQLITE_WORK_FILE="$work_dir/source.sqlite3"

    local tables
    tables=$(sqlite3 "$SQLITE_WORK_FILE" \
        "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%';")

    local table col ctype affected needs_rowid count def select_list colspec
    local rebuild_tables=()
    while IFS= read -r table; do
        [[ -z "$table" ]] && continue
        def=""
        select_list=""
        affected=false
        needs_rowid=false
        # Tables where the implicit SQLite rowid must be materialized because
        # the postgres schema carries an explicit "rowid" column (forwards).
        if ! sqlite3 "$SQLITE_WORK_FILE" \
            "SELECT 1 FROM pragma_table_info(\"$table\") WHERE name='rowid' LIMIT 1;" | grep -q 1 \
            && pg_schema_has_column "$table" rowid; then
            needs_rowid=true
        fi
        while IFS='|' read -r col ctype; do
            [[ -z "$col" ]] && continue
            count=0
            if [[ "${ctype^^}" == *INT* ]]; then
                count=$(sqlite3 "$SQLITE_WORK_FILE" \
                    "SELECT COUNT(*) FROM \"$table\" WHERE \"$col\" > $fixnum_max OR \"$col\" < $fixnum_min;")
            fi
            if [[ "$count" -gt 0 ]]; then
                affected=true
                log_warn "Rebuilding '$table' with $col as TEXT ($count out-of-range value(s), pgloader bignum workaround)"
                def+="\"$col\" TEXT, "
                select_list+="CAST(\"$col\" AS TEXT) AS \"$col\", "
            else
                def+="\"$col\"${ctype:+ $ctype}, "
                select_list+="\"$col\", "
            fi
        done < <(sqlite3 "$SQLITE_WORK_FILE" \
            "SELECT name, type FROM pragma_table_info(\"$table\") ORDER BY cid;")
        if [[ "$needs_rowid" == true ]]; then
            log_warn "Rebuilding '$table' materializing implicit rowid (pgloader workaround)"
            def+="\"rowid\" INTEGER, "
            select_list+="rowid AS \"rowid\", "
        fi
        if [[ "$affected" == true || "$needs_rowid" == true ]]; then
            rebuild_tables+=("$table")
            sqlite3 "$SQLITE_WORK_FILE" "
                CREATE TABLE \"${table}__clnmig\" (${def%, });
                INSERT INTO \"${table}__clnmig\" SELECT ${select_list%, } FROM \"$table\";
                DROP TABLE \"$table\";
                ALTER TABLE \"${table}__clnmig\" RENAME TO \"$table\";
            "
        fi
    done <<< "$tables"

    if [[ ${#rebuild_tables[@]} -gt 0 ]]; then
        log_info "Prepared working copy (rebuilt tables: ${rebuild_tables[*]}): $SQLITE_WORK_FILE"
    fi
    return 0
}

# Function to migrate data using pgloader (data-only)
migrate_data() {
    local sqlite_file="$1"
    local pg_host="$2"
    local pg_port="$3"
    local pg_user="$4"
    local pg_db_name="$5"
    local use_socket="$6"
    local socket_path="$7"
    
    log_info "Starting data migration from SQLite to PostgreSQL..."
    
    # Build connection string using superuser credentials.
    # pgloader unix-socket URIs use unix:/socket/dir:port/dbname syntax.
    local pg_conn_string
    if [[ "$use_socket" == true ]]; then
        if [[ -n "$PG_SUPERUSER_PASSWORD" ]]; then
            pg_conn_string="postgresql://$PG_SUPERUSER:$PG_SUPERUSER_PASSWORD@unix:$socket_path:$pg_port/$pg_db_name"
        else
            pg_conn_string="postgresql://$PG_SUPERUSER@unix:$socket_path:$pg_port/$pg_db_name"
        fi
    else
        if [[ -n "$PG_SUPERUSER_PASSWORD" ]]; then
            pg_conn_string="postgresql://$PG_SUPERUSER:$PG_SUPERUSER_PASSWORD@$pg_host:$pg_port/$pg_db_name"
        else
            pg_conn_string="postgresql://$PG_SUPERUSER@$pg_host:$pg_port/$pg_db_name"
        fi
    fi

    log_info "Running pgloader locally for direct SQLite to PostgreSQL migration..."

    # Create pgloader configuration file for data migration.
    # 'data only' — tables/sequences/indexes already exist (created from the
    # CLN-native schema); 'disable triggers' disables FK triggers while data
    # is copied so table load order cannot violate foreign keys.
    local config_file="/tmp/pgloader_config_$$.load"

    cat > "$config_file" << EOF
LOAD DATABASE
    FROM sqlite://$sqlite_file
    INTO $pg_conn_string
WITH
    data only, disable triggers,
    batch rows = 20000, prefetch rows = 20000,
    workers = 4, concurrency = 2
;
EOF
    
    log_info "Running pgloader with configuration file..."
    
    # Run pgloader with configuration file
    if pgloader "$config_file" 2>&1 | tee "/tmp/pgloader_output_$$.log"; then
        log_success "Data migration completed successfully"
        rm -f "$config_file"
        return 0
    else
       log_error "Data migration failed. Check log file: /tmp/pgloader_output_$$.log"
        rm -f "$config_file"
        return 1
    fi
}

# Main execution function
main() {
    log_info "Starting SQLite to PostgreSQL migration for Core Lightning"
    
    # Parse arguments
    parse_arguments "$@"
    
    # Check if psql client is available
    if ! check_psql_client; then
        log_error "Migration script aborted due to missing psql client"
        exit 1
    fi
    
    # Validate SQLite database
    if ! validate_sqlite_database "$SQLITE_FILE"; then
        log_error "SQLite database validation failed"
        exit 1
    fi
    
    # Check PostgreSQL server connectivity
    if ! check_postgresql_server "$PG_HOST" "$PG_PORT" "$PG_USER" "$USE_SOCKET" "$SOCKET_PATH"; then
        log_error "PostgreSQL server connectivity check failed"
        exit 1
    fi
    
    # Install pgloader if needed
    if ! install_pgloader; then
        log_error "pgloader installation failed"
        exit 1
    fi
    
    # Setup PostgreSQL database
    if ! setup_postgresql_database "$PG_HOST" "$PG_PORT" "$PG_USER" "$PG_DB_NAME" "$USE_SOCKET" "$SOCKET_PATH"; then
        log_error "PostgreSQL database setup failed"
        exit 1
    fi
    
    # Verify database exists for pgloader (schema is applied separately)
    if ! verify_database_exists "$PG_HOST" "$PG_PORT" "$PG_USER" "$PG_DB_NAME" "$USE_SOCKET" "$SOCKET_PATH"; then
        log_error "Database verification failed"
        exit 1
    fi

    # Create the CLN schema (tables, sequences, indexes, constraints)
    if ! apply_cln_schema "$PG_HOST" "$PG_PORT" "$PG_DB_NAME" "$USE_SOCKET" "$SOCKET_PATH"; then
        log_error "Schema creation failed"
        exit 1
    fi

    # Prepare a working copy of the SQLite file (pgloader bignum workaround)
    MIGRATION_TMPDIR=$(mktemp -d "${TMPDIR:-/tmp}/cln-migration.XXXXXX")
    trap 'rm -rf "$MIGRATION_TMPDIR"' EXIT
    if ! prepare_sqlite_workfile "$SQLITE_FILE" "$MIGRATION_TMPDIR"; then
        log_error "Failed to prepare SQLite working copy"
        exit 1
    fi

    # Migrate data
    if ! migrate_data "$SQLITE_WORK_FILE" "$PG_HOST" "$PG_PORT" "$PG_USER" "$PG_DB_NAME" "$USE_SOCKET" "$SOCKET_PATH"; then
        log_error "Data migration failed"
        exit 1
    fi

    # Reset serial sequences so new rows get fresh ids
    if ! reset_sequences "$PG_HOST" "$PG_PORT" "$PG_DB_NAME" "$USE_SOCKET" "$SOCKET_PATH"; then
        log_error "Sequence reset failed"
        exit 1
    fi
    
    # Create application user and transfer ownership
    if ! create_application_user "$PG_HOST" "$PG_PORT" "$PG_USER" "$PG_DB_NAME" "$USE_SOCKET" "$SOCKET_PATH"; then
        log_error "Application user setup failed"
        exit 1
    fi
    
    # Success message
    log_success "Migration completed successfully!"
    echo
    echo "=== MIGRATION SUMMARY ==="
    echo "Source SQLite file: $SQLITE_FILE"
    echo "Target PostgreSQL database: $PG_DB_NAME"
    echo "PostgreSQL user: $PG_USER"
    if [[ "$USE_SOCKET" == true ]]; then
        echo "Connection: UNIX socket ($SOCKET_PATH)"
    else
        echo "Connection: TCP ($PG_HOST:$PG_PORT)"
    fi
    echo
    echo "IMPORTANT: Update your lightning.conf configuration:"
    echo "  Set: wallet=postgres://$PG_USER:your_password@$PG_HOST:$PG_PORT/$PG_DB_NAME"
    if [[ "$USE_SOCKET" == true ]]; then
        echo "  Or: wallet=postgres://$PG_USER@/$PG_DB_NAME?host=$SOCKET_PATH"
    fi
    echo "  Remove or comment out any sqlite3 configuration"
    echo
    echo "Restart lightningd to use the new PostgreSQL database."
    echo "=========================="
}

# Run main function with all arguments
main "$@"
