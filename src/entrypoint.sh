#!/bin/bash
set -eu

# Cronie does not forward arbitrary container environment variables to jobs.
# Save only backup configuration, shell-quoted, in a root-only runtime file.
umask 077
env_file=/run/mysql-backup.env
: > "$env_file"
for name in MYSQL_HOST MYSQL_PORT MYSQL_USER MYSQL_PWD MYSQL_DEFAULTS_EXTRA_FILE BACKUP_DIR TZ; do
    if [[ -v "$name" ]]; then
        printf 'export %s=%q\n' "$name" "${!name}" >> "$env_file"
    fi
done

# Set the system timezone as well as TZ for cron scheduling.
if [[ -n "${TZ:-}" ]]; then
    if [[ ! -f "/usr/share/zoneinfo/$TZ" ]]; then
        echo "ERROR: Unknown timezone: $TZ" >&2
        exit 1
    fi
    ln -snf "/usr/share/zoneinfo/$TZ" /etc/localtime
fi

schedule=${SCHEDULE_EXPR:-0 3 * * *}
if [[ "$schedule" == *$'\n'* || "$schedule" == *$'\r'* || "$schedule" == *%* ]]; then
    echo 'ERROR: Invalid cron schedule.' >&2
    exit 1
fi
read -r -a fields <<< "$schedule"
if [[ ${#fields[@]} -ne 5 ]]; then
    echo 'ERROR: SCHEDULE_EXPR must contain five cron fields.' >&2
    exit 1
fi

# Open container stdout before cron starts; jobs forward their output here.
printf '%s /bin/bash -c '\''source /run/mysql-backup.env; exec /job.sh'\'' >> /proc/1/fd/1 2>&1\n' "$schedule" | crontab -
exec crond -n
