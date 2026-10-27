# MySQL backup cron container

1. Adjust `MYSQL_HOST`, `MYSQL_USER`, network name, and backup host path in `docker-compose.yml`.
2. Create `backup.env` alongside `docker-compose.yml` with `MYSQL_PWD=your-password` (never commit it). Compose loads this file into the container environment.
3. Verify the MySQL client version is compatible with your server. The image uses `oraclelinux:9-slim` with Oracle MySQL 8.4 LTS client packages from the repository in `src/mysql-community.repo`.
4. Run `docker compose up -d --build`.
5. Test immediately: `docker compose exec mysql-backup /job.sh`.
6. Inspect `docker compose logs mysql-backup` and `/srv/backups/mysql`.
7. Copy `src/.kopiaignore` to `/srv/backups/mysql/.kopiaignore` and configure Kopia as described below.

The default schedule is daily at 03:00 America/Chicago. Change `SCHEDULE_EXPR`
and `TZ` in Compose as needed. The external `mysql-network` must already exist
and provide access to your MySQL server. Compose's `init: true` provides the
init process; `src/entrypoint.sh` configures Cronie and forwards job output to
container logs. No MySQL server is started in this container.

```text
docker-compose.yml
build.sh
README.md
src/
  Dockerfile
  mysql-community.repo
  entrypoint.sh
  job.sh
  .kopiaignore
```

`src/job.sh` requires Oracle MySQL client tools (`mysql`, `mysqldump`), `gzip`,
and standard POSIX shell utilities. Use clients compatible with
your server; this script is not intended for MariaDB client tools.

The image installs only the MySQL client and its dependencies, plus the cron and
shell tools used by the backup scripts. It does not install the MySQL server.
Package signature verification is enabled; weak dependencies and package
documentation are omitted, and package caches are cleaned during the build.
The build checks that `mysql` and `mysqldump` run and that `mysqld` is absent.

Build and inspect the local image size:

```sh
./build.sh
docker image inspect mysql-backup-cron --format '{{.Size}}'
docker compose up -d --force-recreate
```

The reported size is in bytes; the exact size depends on current base-image and
client package versions.

Configuration:

| Variable | Script default | Compose setting |
| --- | --- | --- |
| `MYSQL_HOST` | `mysql` | `mysql` |
| `MYSQL_PORT` | `3306` | `3306` |
| `MYSQL_USER` | `root` | `backup_job` |
| `BACKUP_DIR` | `/backups` | `/backups`, mounted from `/srv/backups/mysql` |
| `MYSQL_DEFAULTS_EXTRA_FILE` | Unset; optional client option file path | Unset |
| `MYSQL_PWD` | Unset; optional client password environment variable | From `backup.env` |

`SCHEDULE_EXPR` and `TZ` configure scheduling in the container, not dump filenames.

Prefer a protected mounted option file for the password:

```ini
[client]
password=your-password
```

Run with:

```sh
MYSQL_DEFAULTS_EXTRA_FILE=/run/secrets/mysql-client.cnf sh ./src/job.sh
```

The account must be able to discover and dump all intended databases, including
views, triggers, routines, and events. Discovery only lists schemas visible to
that account. Configure appropriate privileges for your MySQL version.

## Backup behavior

- Discovers user databases, excluding `mysql`, `sys`, `information_schema`, and
  `performance_schema`.
- Creates one compressed SQL dump per database, including CREATE DATABASE / USE
  statements, routines, events, and triggers.
- Uses fixed filenames, `db__<sanitized-database-name>.sql.gz`, and stages all dumps before replacing previous
  successful files. Historical retention is delegated to Kopia. Files belonging
  to databases subsequently dropped are not automatically deleted.
- Rejects overlapping runs and records in-progress and failed markers.
- Exports accounts, roles, grants, and default roles into `users.sql.gz`, using
  `SHOW CREATE USER` and `SHOW GRANTS`. Includes authentication settings and
  password hashes where present. MySQL's built-in `mysql.infoschema`,
  `mysql.session`, and `mysql.sys` accounts are excluded.
- Stages the account export as `users.sql.tmp` and `users.sql.gz.tmp`. An account
  export failure prevents publication of the entire backup set.
- Server configuration and binary logs are **not included**.
- `--single-transaction` provides per-database consistency for InnoDB. Avoid
  schema changes during dumps. Nontransactional tables require a separate
  locking/maintenance strategy; different databases have separate snapshots.
- GTID state is not included; these are logical restore backups, not replication
  provisioning or point-in-time recovery backups.

Database names are sanitized by replacing characters other than letters, numbers,
`_`, `.`, and `-` with `_`. For example, `sales europe` produces
`db__sales_europe.sql.gz`. Staging files are `db__sales_europe.sql.tmp` and
`db__sales_europe.sql.gz.tmp` inside `BACKUP_DIR`.

Existing files using the old hash suffix are not renamed or deleted automatically.
After verifying a successful backup with the new names, remove obsolete hashed
files from the backup directory if they are no longer needed.

## Restore

Restore accounts first so users referenced by database objects' `DEFINER`
clauses exist. Restore each database next, then apply grants and default roles:
table- and routine-level grants can require the referenced objects to exist.
Each database dump includes its own `CREATE DATABASE` and `USE` statements.

Use an administrative restore account, not the read-only backup account. Adjust
paths and connection settings for your environment:

```sh
gzip -dc /srv/backups/mysql/users.sql.gz > users.restore.sql &&
sed '/^-- Grants and default roles/,$d' users.restore.sql > accounts.restore.sql &&
mysql --defaults-extra-file=/run/secrets/mysql-client.cnf --host=mysql --user=root < accounts.restore.sql
```

For each database:

```sh
gzip -dc /srv/backups/mysql/db__sales_europe.sql.gz > restore.sql &&
mysql --defaults-extra-file=/run/secrets/mysql-client.cnf --host=mysql --user=root < restore.sql
```

`CREATE USER IF NOT EXISTS` preserves existing accounts and their passwords;
grants are added, not reset to an exact copy. New accounts retain their exported
authentication settings. Restore to a compatible MySQL version with the required
authentication plugins available. Keep the account export protected like other
backup files. Avoid changing accounts or grants while the export runs.

After restoring all databases, import the full account export to apply grants
and default roles. Existing accounts are skipped by `CREATE USER IF NOT EXISTS`:

```sh
mysql --defaults-extra-file=/run/secrets/mysql-client.cnf --host=mysql --user=root < users.restore.sql
```

## Kopia

Copy `.kopiaignore` into the backup directory and configure Kopia to recognize
it. Schedule snapshots after backups finish. An essential before-snapshot
action should reject snapshots when either `.backup-in-progress` or
`.backup-failed` exists in the backup directory. A marker check is not a lock:
ensure the next backup cannot start while the snapshot is reading files.

A hard kill or container crash can leave a stale `.mysql-backup.lock` directory
or marker. Investigate before manually clearing them. A successful backup
clears the failure marker.

## backup user

For **MySql v8+**, the simplest approach is to create a dedicated backup user.

```
CREATE USER 'backup_job'@'%' IDENTIFIED BY 'your_strong_password';

GRANT SELECT, SHOW VIEW, TRIGGER, EVENT, LOCK TABLES
ON *.* TO 'backup_job'@'%';

GRANT SHOW_ROUTINE ON *.* TO 'backup_job'@'%';
```                                

The account cannot modify data, but it can read all databases, including sensitive
system tables. Global `SELECT` covers `mysql.user` and `mysql.default_roles`, and
allows inspecting other accounts with `SHOW CREATE USER` and `SHOW GRANTS`.
`SHOW_ROUTINE` allows exporting routine definitions on MySQL 8.0.20 and later.
Account-export errors fail the backup rather than silently omitting users.
