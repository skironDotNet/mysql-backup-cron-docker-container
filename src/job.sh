#!/bin/sh
set -u

: "${MYSQL_HOST:=mysql}"
: "${MYSQL_PORT:=3306}"
: "${MYSQL_USER:=backup_job}"
: "${BACKUP_DIR:=/backups}"

# Prefer a mounted client option file for credentials. MYSQL_PWD is also
# supported by the MySQL clients; do not pass passwords on the command line.
# --defaults-extra-file must be the first client option.
mysql_client() {
    if [ -n "${MYSQL_DEFAULTS_EXTRA_FILE:-}" ]; then
        mysql --defaults-extra-file="$MYSQL_DEFAULTS_EXTRA_FILE" \
            --host="$MYSQL_HOST" --port="$MYSQL_PORT" --user="$MYSQL_USER" \
            --protocol=TCP "$@"
    else
        mysql --host="$MYSQL_HOST" --port="$MYSQL_PORT" --user="$MYSQL_USER" \
            --protocol=TCP "$@"
    fi
}

dump_database() {
    if [ -n "${MYSQL_DEFAULTS_EXTRA_FILE:-}" ]; then
        mysqldump --defaults-extra-file="$MYSQL_DEFAULTS_EXTRA_FILE" \
            --host="$MYSQL_HOST" --port="$MYSQL_PORT" --user="$MYSQL_USER" \
            --protocol=TCP "$@"
    else
        mysqldump --host="$MYSQL_HOST" --port="$MYSQL_PORT" --user="$MYSQL_USER" \
            --protocol=TCP "$@"
    fi
}

mkdir -p "$BACKUP_DIR" || exit 1
umask 077

lock="$BACKUP_DIR/.mysql-backup.lock"
marker="$BACKUP_DIR/.backup-in-progress"
failed_marker="$BACKUP_DIR/.backup-failed"

if ! mkdir "$lock" 2>/dev/null; then
    echo 'ERROR: Backup already running or stale lock exists.' >&2
    exit 1
fi

if ! : > "$marker"; then
    rmdir "$lock" 2>/dev/null || true
    exit 1
fi

finished=0
cleanup() {
    status=$?
    trap - EXIT HUP INT TERM
    if [ "$finished" -ne 1 ] || [ "$status" -ne 0 ]; then
        : > "$failed_marker"
    fi
    rm -f "$marker"
    rmdir "$lock" 2>/dev/null || true
    exit "$status"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

: > "$failed_marker" || exit 1

# System schemas are not portable logical application backups. In particular,
# users and grants must be exported/provisioned separately, not via mysql.*.
# Batch output escapes special characters: reject those names rather than
# silently treating an escaped name as a different database.
if ! databases=$(mysql_client --batch --skip-column-names --execute="
    SELECT SCHEMA_NAME FROM information_schema.SCHEMATA
    WHERE SCHEMA_NAME NOT IN ('information_schema', 'performance_schema', 'sys', 'mysql')
    ORDER BY SCHEMA_NAME"); then
    echo 'ERROR: Could not discover databases.' >&2
    exit 1
fi
[ -n "$databases" ] || { echo 'ERROR: No user databases found.' >&2; exit 1; }

while IFS= read -r db; do
    [ -n "$db" ] || continue
    case "$db" in
        *\\*) echo 'ERROR: Database name contains unsupported escaped characters.' >&2; exit 1 ;;
    esac
    label=$(printf '%s' "$db" | sed 's/[^[:alnum:]_.-]/_/g')
    file="$BACKUP_DIR/db__${label}.sql"

    echo "Backing up database: $db"
    # No pipeline: a failed dump must not be masked by successful compression.
    # --single-transaction provides a consistent snapshot for InnoDB only.
    if ! dump_database --single-transaction --quick --skip-lock-tables \
        --routines --events --triggers --hex-blob --no-tablespaces \
        --set-gtid-purged=OFF --databases -- "$db" > "$file.tmp"; then
        echo "ERROR: mysqldump failed for: $db" >&2
        exit 1
    fi
    # Do not store the staging filename or timestamp in the gzip header.
    if ! gzip -n -c "$file.tmp" > "$file.gz.tmp"; then
        echo "ERROR: Compression failed for: $db" >&2
        exit 1
    fi
    rm -f "$file.tmp" || exit 1
done <<EOF_DATABASES
$databases
EOF_DATABASES

# Publish only after every dump and compression succeeds. Renames are atomic
# per file; snapshot scheduling and marker checks protect the complete set.
while IFS= read -r db; do
    [ -n "$db" ] || continue
    label=$(printf '%s' "$db" | sed 's/[^[:alnum:]_.-]/_/g')
    file="$BACKUP_DIR/db__${label}.sql.gz"
    mv -f "$file.tmp" "$file" || exit 1
    echo "Completed: $file"
done <<EOF_DATABASES
$databases
EOF_DATABASES

rm -f "$failed_marker" || exit 1
finished=1
echo 'All MySQL backups completed successfully.'
