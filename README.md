# MySQL backup cron container

1. Adjust `MYSQL_HOST`, `MYSQL_USER`, network name, and backup host path in `docker-compose.yml`.
2. Put `BACKUP_USER_PASSWORD=your-password` in a local `.env` (never commit it).
3. Verify the MySQL client image in `src/Dockerfile` is compatible with your server. The default is Oracle MySQL 8.4.
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
  entrypoint.sh
  job.sh
  .kopiaignore
```

`src/job.sh` requires Oracle MySQL client tools (`mysql`, `mysqldump`), `gzip`,
and standard POSIX shell utilities. Use clients compatible with
your server; this script is not intended for MariaDB client tools.

Configuration:

| Variable | Script default | Compose setting |
| --- | --- | --- |
| `MYSQL_HOST` | `mysql` | `mysql` |
| `MYSQL_PORT` | `3306` | `3306` |
| `MYSQL_USER` | `root` | `backup_job` |
| `BACKUP_DIR` | `/backups` | `/backups`, mounted from `/srv/backups/mysql` |
| `MYSQL_DEFAULTS_EXTRA_FILE` | Unset; optional client option file path | Unset |
| `MYSQL_PWD` | Unset; optional client password environment variable | From `BACKUP_USER_PASSWORD` in `.env` |

`BACKUP_USER_PASSWORD` is a Compose input, not a variable read by `job.sh`.
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
- Accounts, grants, server configuration, and binary logs are **not included**.
  Provision accounts/grants separately, including accounts referenced by
  DEFINER clauses in views, routines, triggers, and events.
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

Restore a dump by decompressing it first, checking success, then importing
(adjust the path and restore account for your environment):

```sh
gzip -dc /srv/backups/mysql/db__sales_europe.sql.gz > restore.sql &&
mysql --defaults-extra-file=/run/secrets/mysql-client.cnf --host=mysql --user=backup_user < restore.sql
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
```                                

The account cannot modify data, but it can read all databases, including sensitive system tables.
