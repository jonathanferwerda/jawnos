#!/bin/sh
# SQLite health of a JawnOS database.
#
# Answers: "is the database in WAL, how big is the WAL, and can a read-only
#           connection see the newest rows?"
# Usage: db-state.sh [DB_PATH]
# Example: db-state.sh ./database/jawnos.db
# Read-only: sqlite3 -readonly only.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
DB=${1:-${JAWNOS_DB:-"$ROOT/database/jawnos.db"}}

[ -r "$DB" ] || { echo "no readable database: $DB" >&2; exit 1; }
command -v sqlite3 >/dev/null 2>&1 || { echo "sqlite3 not found" >&2; exit 1; }

q() { sqlite3 -readonly -cmd ".timeout 3000" "$DB" "$1" 2>/dev/null; }

echo "journal_mode=$(q 'pragma journal_mode;')"
echo "busy_timeout=$(q 'pragma busy_timeout;')"
pages=$(q "select page_count*page_size from pragma_page_count(), pragma_page_size();")
case "$pages" in ''|*[!0-9]*) pages=0 ;; esac
echo "db_size_mb=$(( pages / 1048576 ))"
wal=$(wc -c < "$DB-wal" 2>/dev/null)
echo "wal_bytes=${wal:-0}"
echo "--- does a read-only count see the newest rows?"
q "select count(*) from appointments where server_time > (cast(strftime('%s','now') as integer)-600)*1000;"
