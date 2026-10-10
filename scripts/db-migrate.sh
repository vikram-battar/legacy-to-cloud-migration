#!/usr/bin/env bash
# db-migrate.sh — move data from the legacy SQLite file into RDS Postgres.
#
# Usage:
#   SQLITE_DB=./inventory.db PG_DSN="postgresql://user:pass@host:5432/inventory" ./scripts/db-migrate.sh
#
# How it works: dumps the SQLite table to CSV, then COPYs it into Postgres.
# This is the simple version for a small table. For a large or live database,
# use a real replication tool (AWS DMS) — see docs/migration-runbook.md.
#
# Safe to re-run: the COPY goes into a temp staging table, and the final
# INSERT skips rows whose id already exists.
set -euo pipefail

: "${SQLITE_DB:?set SQLITE_DB to the legacy sqlite file}"
: "${PG_DSN:?set PG_DSN to the target postgres connection string}"

TMPDIR_WORK=$(mktemp -d)
trap 'rm -rf "$TMPDIR_WORK"' EXIT
CSV="$TMPDIR_WORK/items.csv"

echo "==> exporting from SQLite ($SQLITE_DB)"
sqlite3 "$SQLITE_DB" <<SQL
.headers on
.mode csv
.output $CSV
SELECT id, name, quantity FROM items;
SQL

ROWS=$(($(wc -l < "$CSV") - 1))
echo "==> exported $ROWS rows"

echo "==> loading into Postgres (staging table, idempotent)"
psql "$PG_DSN" <<SQL
CREATE TEMP TABLE items_staging (LIKE items INCLUDING ALL);
\\copy items_staging(id, name, quantity) FROM '$CSV' WITH CSV HEADER
INSERT INTO items (id, name, quantity)
  SELECT id, name, quantity FROM items_staging
  ON CONFLICT (id) DO NOTHING;
SELECT setval(pg_get_serial_sequence('items','id'),
              COALESCE((SELECT max(id) FROM items), 1));
SQL

echo "==> verifying row counts"
SQLITE_COUNT=$(sqlite3 "$SQLITE_DB" "SELECT COUNT(*) FROM items;")
PG_COUNT=$(psql -tA "$PG_DSN" -c "SELECT COUNT(*) FROM items;")
echo "sqlite: $SQLITE_COUNT rows | postgres: $PG_COUNT rows"
if [ "$SQLITE_COUNT" -ne "$PG_COUNT" ]; then
  echo "MISMATCH — investigate before cutover" >&2
  exit 1
fi
echo "OK — counts match"
