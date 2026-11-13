# cln-migrate-to-postgres 🚀
 
 Migrate Core Lightning SQLite database to PostgreSQL using `pgloader`.
 
 [![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
 
 **Links:**
 - **Migration script:** `migrate_sqlite_to_postgres.sh`
 - **Schema docs:** `docs/database_schema_documentation.md`

 ## Features 📈

- Exact CLN PostgreSQL schema applied first (pgloader loads **data only** — no schema drift)
- Versioned schema dumps in `schema/` (currently: CLN `v26.06.10`, db version `284`)
- Complete data migration including u64 scid aliases / group ids that pgloader normally skips
- Materializes sqlite implicit `rowid` columns required by the postgres schema (`forwards.rowid`)
- Creates PostgreSQL database and application user, resets sequences, grants ownership/permissions
- TCP and UNIX socket connections
- Works on a `VACUUM INTO` copy — the source SQLite file is never modified

 ## Prerequisites 📝

- PostgreSQL Server (v12+)
- psql client
- sqlite3
- pgloader

 ## Installation 📦

```bash
wget https://raw.githubusercontent.com/your-username/cln-migrate-to-postgres/main/migrate_sqlite_to_postgres.sh
chmod +x migrate_sqlite_to_postgres.sh
```

 ## Usage 🤔

```bash
./migrate_sqlite_to_postgres.sh --help
```

**Examples:**
```bash
# Basic
./migrate_sqlite_to_postgres.sh ~/.lightning/lightningd.sqlite3 lightningd

# Custom settings
./migrate_sqlite_to_postgres.sh lightningd.sqlite3 cln_db -u lightning_user -s postgres -S pass

# UNIX socket
./migrate_sqlite_to_postgres.sh lightningd.sqlite3 cln_db --socket /var/run/postgresql

# Custom schema dump (for a different CLN version)
./migrate_sqlite_to_postgres.sh lightningd.sqlite3 cln_db --schema schema/my_schema.sql
```

**Schema files:** the script applies an exact CLN PostgreSQL schema before loading
data. The bundled `schema/cln_v26.06.10_schema.sql` matches CLN `v26.06.10`
(db version `284`). For other versions, dump a fresh schema from a running
postgres-backed lightningd and pass it via `--schema`:

```bash
pg_dump --schema-only --no-owner --no-privileges -d lightning > schema/my_schema.sql
```

 ## Pre-Migration 🚨

**Backup and shutdown:**
```bash
# Stop lightningd
sudo systemctl stop lightningd

# Backup SQLite database
cp ~/.lightning/lightningd.sqlite3 ~/.lightning/lightningd.sqlite3.backup
```

**Source consistency:** the SQLite file must be a quiesced copy — take it while
`lightningd` is stopped (or via a consistent snapshot/backup mechanism). A file
copied while `lightningd` is running can contain index corruption and silently
miss rows. The script builds a `VACUUM INTO` working copy which repairs
freelist/index damage and leaves the source untouched, but the only fully safe
source is one taken while the daemon is down.

 ## Post-Migration 🔄

**Update lightning.conf:**
```ini
# With username/password
wallet=postgres://lightning_user:password@host:5432/cln_db
# Or with UNIX socket:
wallet=postgres://lightning_user@/cln_db?host=/var/run/postgresql
```

**Restart lightningd:**
```bash
sudo systemctl restart lightningd
```

 ## Verification 📊

```bash
# PostgreSQL
psql -U user -d database -c "SELECT COUNT(*) FROM version;"

# Core Lightning
lightning-cli getinfo
lightning-cli listpeers
```

 ## How it works 🔧

1. Validates the source database and reports the CLN schema `version`.
2. Creates the target database and applies the schema file (`--schema`).
3. Builds a temporary working copy via `VACUUM INTO`. Inside the copy it:
   - rebuilds tables whose `INTEGER` columns hold values outside pgloader's
     SBCL fixnum range (e.g. `channels.alias_local/alias_remote`,
     `channel_htlcs.groupid`, `payments.groupid`,
     `channel_moves.payment_group_id`), storing them as `TEXT` so pgloader
     parses them as bignums — otherwise those rows are **silently skipped**;
   - adds a real `rowid` column from sqlite's implicit rowid where the
     postgres schema expects one (`forwards`).
4. Runs pgloader in data-only mode (unix socket connections use the
   `postgresql://user@unix:/socket/path:port/db` URI form).
5. Resets sequences, recreates foreign keys, sets up the application role
   and ownership/grants.
6. Removes all temporary files. The source file is never modified.

 ## Troubleshooting 🤷‍♂️

**pgloader issues:**
See https://github.com/darold/pgloader.git for usage instructions

**`The value ... is not of type (OR STRING NULL FIXNUM)`:**
old script versions let pgloader skip rows with out-of-fixnum integers. Update
to the current script — it rewrites those columns in a temp copy so no rows
are lost.

**Source database is corrupt / row counts differ:**
`VACUUM INTO` in the work-file step recovers rows unreachable through corrupt
indexes. If counts still differ, check `PRAGMA quick_check` on the source and
use a snapshot taken while `lightningd` was stopped.


 ## Documentation 📚

- [Database Schema](docs/database_schema_documentation.md)
- [Migration Script](migrate_sqlite_to_postgres.sh)

 ## Security 🔒

- Passwords prompted, not stored
- Dedicated application user with minimal privileges
- Database ownership transferred to application user

 ## Rollback ⚠️
**DANGER / READ FIRST**
- **Rollback is only safe if `lightningd` never started using PostgreSQL after the migration.**
- If your node **created any new state in PostgreSQL** (payments, invoices, channel updates, gossip, etc.), **there is NO safe/deterministic way back to SQLite**.
- Rolling back after running on PostgreSQL can cause:
  - **loss of funds / stuck channels**
  - **inconsistent node state**
  - **database divergence** (SQLite will be missing newer state)
**Only do this rollback if ALL of the following are true:**
- `lightningd` is **stopped**
- you **never** started `lightningd` with `wallet=postgres://...`
- you are restoring the **exact SQLite file** you backed up right before migration
```bash
# Stop lightningd (must be stopped)
sudo systemctl stop lightningd
# Restore the pre-migration SQLite backup
cp ~/.lightning/lightningd.sqlite3.backup ~/.lightning/lightningd.sqlite3
# Update lightning.conf to use SQLite again (remove/disable wallet=postgres://...)
# Start lightningd
sudo systemctl start lightningd
```

 ## License

MIT License - see [LICENSE](LICENSE) file.

## Support
