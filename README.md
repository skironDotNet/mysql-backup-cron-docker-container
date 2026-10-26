# MySQL backup cron container

1. Adjust `MYSQL_HOST`, `MYSQL_USER`, network name, and backup host path in `docker-compose.yml`.
2. Put `MYSQL_BACKUP_PASSWORD=your-password` in a local `.env` (never commit it).
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
`sha256sum`, and standard POSIX shell utilities. Use clients compatible with
your server; this script is not intended for MariaDB client tools.

Configuration:

| Variable | Default |
| --- | --- |
| `MYSQL_HOST` | `mysql` |
| `MYSQL_PORT` | `3306` |
| `MYSQL_USER` | `root` |
| `BACKUP_DIR` | `/backups` |
| `MYSQL_DEFAULTS_EXTRA_FILE` | Optional client option file path |
| `MYSQL_PWD` | Optional password environment variable |

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
- Uses fixed, hashed filenames and stages all dumps before replacing previous
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

Restore a dump by decompressing it first, checking success, then importing:

```sh
gzip -dc database-HASH.sql.gz > restore.sql &&
mysql --defaults-extra-file=/run/secrets/mysql-client.cnf --host=mysql --user=root < restore.sql
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
