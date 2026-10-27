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
# users and grants are exported as account-management SQL, not system tables.
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

# Export all accounts before any grants so role references can be restored.
# Backtick quoting avoids dependence on NO_BACKSLASH_ESCAPES for account names.
if ! accounts=$(mysql_client --batch --skip-column-names --execute="
    SELECT CONCAT(CHAR(96), REPLACE(User, CHAR(96), REPEAT(CHAR(96), 2)),
                  CHAR(96), '@', CHAR(96),
                  REPLACE(Host, CHAR(96), REPEAT(CHAR(96), 2)), CHAR(96))
    FROM mysql.user
    WHERE User NOT IN ('mysql.infoschema', 'mysql.session', 'mysql.sys')
    ORDER BY User, Host"); then
    echo 'ERROR: Could not discover accounts.' >&2
    exit 1
fi
users_file="$BACKUP_DIR/users.sql"
printf '%s\n' '-- Accounts, roles, grants and default roles.' \
    'SET @backup_saved_sql_mode = @@SESSION.sql_mode;' \
    "SET SESSION sql_mode = '';" > "$users_file.tmp" || exit 1
tab=$(printf '\t')
while IFS= read -r account; do
    [ -n "$account" ] || continue
    case "$account" in
        *\\*) echo 'ERROR: Account name contains unsupported escaped characters.' >&2; exit 1 ;;
    esac
    if ! definition=$(mysql_client --batch --raw --skip-column-names \
        --execute="SET SESSION sql_mode = ''; SHOW CREATE USER $account"); then
        echo "ERROR: Could not export account: $account" >&2
        exit 1
    fi
    # SHOW CREATE USER returns the account label followed by a tab and SQL.
    definition=${definition#*"$tab"}
    case "$definition" in
        'CREATE USER '*) definition="CREATE USER IF NOT EXISTS ${definition#CREATE USER }" ;;
        *) echo 'ERROR: Unexpected SHOW CREATE USER output.' >&2; exit 1 ;;
    esac
    printf '%s;\n' "$definition" >> "$users_file.tmp" || exit 1
done <<EOF_ACCOUNTS
$accounts
EOF_ACCOUNTS

printf '%s\n' '-- Grants and default roles' >> "$users_file.tmp" || exit 1
while IFS= read -r account; do
    [ -n "$account" ] || continue
    if ! grants=$(mysql_client --batch --raw --skip-column-names \
        --execute="SET SESSION sql_mode = ''; SHOW GRANTS FOR $account"); then
        echo "ERROR: Could not export grants: $account" >&2
        exit 1
    fi
    while IFS= read -r grant; do
        [ -n "$grant" ] || continue
        printf '%s;\n' "$grant" >> "$users_file.tmp" || exit 1
    done <<EOF_GRANTS
$grants
EOF_GRANTS
done <<EOF_ACCOUNTS
$accounts
EOF_ACCOUNTS

# Group defaults in the shell to avoid GROUP_CONCAT truncating long role lists.
if ! defaults=$(mysql_client --batch --skip-column-names --execute="
    SELECT CONCAT(CHAR(96), REPLACE(USER, CHAR(96), REPEAT(CHAR(96), 2)),
                  CHAR(96), '@', CHAR(96), REPLACE(HOST, CHAR(96), REPEAT(CHAR(96), 2)), CHAR(96)),
           CONCAT(CHAR(96), REPLACE(DEFAULT_ROLE_USER, CHAR(96), REPEAT(CHAR(96), 2)),
                  CHAR(96), '@', CHAR(96), REPLACE(DEFAULT_ROLE_HOST, CHAR(96), REPEAT(CHAR(96), 2)), CHAR(96))
    FROM mysql.default_roles
    WHERE USER NOT IN ('mysql.infoschema', 'mysql.session', 'mysql.sys')
    ORDER BY USER, HOST, DEFAULT_ROLE_USER, DEFAULT_ROLE_HOST"); then
    echo 'ERROR: Could not export default roles.' >&2
    exit 1
fi
previous_account=
roles=
while IFS="$tab" read -r account role; do
    [ -n "$account" ] || continue
    case "$account$role" in
        *\\*) echo 'ERROR: Default role contains unsupported escaped characters.' >&2; exit 1 ;;
    esac
    if [ "$account" != "$previous_account" ]; then
        if [ -n "$previous_account" ]; then
            printf 'SET DEFAULT ROLE %s TO %s;\n' "$roles" "$previous_account" >> "$users_file.tmp" || exit 1
        fi
        previous_account=$account
        roles=$role
    else
        roles="$roles, $role"
    fi
done <<EOF_DEFAULTS
$defaults
EOF_DEFAULTS
if [ -n "$previous_account" ]; then
    printf 'SET DEFAULT ROLE %s TO %s;\n' "$roles" "$previous_account" >> "$users_file.tmp" || exit 1
fi
printf '%s\n' 'SET SESSION sql_mode = @backup_saved_sql_mode;' >> "$users_file.tmp" || exit 1
if ! gzip -n -c "$users_file.tmp" > "$users_file.gz.tmp"; then
    echo 'ERROR: Could not compress accounts export.' >&2
    exit 1
fi
rm -f "$users_file.tmp" || exit 1

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

mv -f "$users_file.gz.tmp" "$users_file.gz" || exit 1
echo "Completed: $users_file.gz"

rm -f "$failed_marker" || exit 1
finished=1
echo 'All MySQL backups completed successfully.'
