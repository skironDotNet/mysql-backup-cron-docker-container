# Install Oracle MySQL clients without the database server.
FROM oraclelinux:9-slim

USER root
COPY mysql-community.repo /etc/yum.repos.d/mysql-community.repo
# The base image supplies coreutils-single; installing coreutils conflicts with it.
RUN microdnf install -y --setopt=install_weak_deps=0 --setopt=tsflags=nodocs \
        mysql-community-client bash cronie gzip sed tzdata \
    && microdnf clean all \
    && mysql --version \
    && mysqldump --version \
    && ! command -v mysqld

COPY job.sh /job.sh
COPY entrypoint.sh /entrypoint.sh
RUN chmod 0755 /job.sh /entrypoint.sh

ENV SCHEDULE_EXPR="0 3 * * *" \
    MYSQL_HOST=mysql \
    MYSQL_PORT=3306 \
    MYSQL_USER=backup_job \
    BACKUP_DIR=/backups \
    TZ=America/Chicago

ENTRYPOINT ["/entrypoint.sh"]
