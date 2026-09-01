#!/bin/bash
# Runs once, on the very first boot of an empty pgdata volume. Docker's entry
# point skips this entirely if the volume already has a cluster in it, so it is
# safe to leave here forever — but it also means editing this file does nothing
# to an existing database. Add later schema changes as migrations instead.

set -euo pipefail

: "${APP_DATABASES:=}"

for db in $APP_DATABASES; do
    echo "  creating database: $db"
    psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname postgres <<-SQL
        CREATE DATABASE "$db" OWNER "$POSTGRES_USER" ENCODING 'UTF8';
SQL
    # pgcrypto for gen_random_uuid(), which every one of these apps ends up
    # wanting for primary keys.
    psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$db" <<-SQL
        CREATE EXTENSION IF NOT EXISTS pgcrypto;
SQL
done

echo "  databases ready: $APP_DATABASES"
