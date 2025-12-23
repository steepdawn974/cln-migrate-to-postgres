# cln-migrate-to-postgres 🚀
 
 Migrate Core Lightning SQLite database to PostgreSQL using `pgloader`.
 
 [![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
 
 **Links:**
 - **Migration script:** `migrate_sqlite_to_postgres.sh`
 - **Schema docs:** `docs/database_schema_documentation.md`

 ## Features 📈

- Complete data migration with automatic type conversion
- Supports all Core Lightning database versions
- Creates PostgreSQL database and application user
- TCP and UNIX socket connections

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
```

 ## Pre-Migration 🚨

**Backup and shutdown:**
```bash
# Stop lightningd
sudo systemctl stop lightningd

# Backup SQLite database
cp ~/.lightning/lightningd.sqlite3 ~/.lightning/lightningd.sqlite3.backup
```

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

 ## Troubleshooting 🤷‍♂️

**pgloader issues:**
See https://github.com/darold/pgloader.git for usage instructions


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
