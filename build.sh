#!/bin/bash
set -eu

docker build -t mysql-backup-cron ./src
