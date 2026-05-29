#!/usr/bin/env bash
# Creates the separate pycsw database on first Postgres startup.
# Runs as POSTGRES_USER (geomdb) which is a superuser in Docker.
set -e

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
  SELECT 'CREATE DATABASE geomdb_pycsw'
  WHERE NOT EXISTS (
    SELECT FROM pg_database WHERE datname = 'geomdb_pycsw'
  )\gexec
EOSQL

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "geomdb_pycsw" <<-EOSQL
  CREATE EXTENSION IF NOT EXISTS postgis;
  CREATE EXTENSION IF NOT EXISTS unaccent;
EOSQL

echo "✅ pycsw database ready."
