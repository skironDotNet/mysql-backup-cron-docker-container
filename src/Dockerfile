# Use Oracle MySQL clients compatible with your server.
FROM mysql:8.4

USER root
RUN microdnf install -y cronie gzip coreutils tzdata && microdnf clean all

COPY job.sh /job.sh
COPY entrypoint.sh /entrypoint.sh
RUN chmod 0755 /job.sh /entrypoint.sh

ENV SCHEDULE_EXPR="0 3 * * *" \
    MYSQL_HOST=mysql \
    MYSQL_PORT=3306 \
    MYSQL_USER=root \
    BACKUP_DIR=/backups \
    TZ=America/Chicago

ENTRYPOINT ["/entrypoint.sh"]
