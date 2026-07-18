#!/bin/bash
# Verify the CheekyPint schema on a throwaway local Postgres — no Supabase CLI or Docker
# required. Spins up a temporary cluster, installs a minimal auth/storage shim (so the real
# migrations run unmodified), applies every migration + seed, runs the RLS/RPC allow-deny
# suite, then tears everything down. Exits non-zero on any failure.
#
# Usage:
#   ./run_local_pg.sh                     # auto-detects Homebrew postgresql@16
#   PG_BIN=/path/to/pg/bin ./run_local_pg.sh
set -uo pipefail

PG_BIN="${PG_BIN:-/opt/homebrew/opt/postgresql@16/bin}"
[ -x "$PG_BIN/initdb" ] || { echo "Postgres not found at $PG_BIN. Set PG_BIN=..."; exit 2; }

HERE="$(cd "$(dirname "$0")" && pwd)"
SUPA="$(dirname "$HERE")"
DATA="$(mktemp -d)/pgdata"
SOCK="/tmp/cp_pgtest_$$"   # short path — macOS caps unix socket paths at 103 bytes
mkdir -p "$SOCK"

"$PG_BIN/initdb" -U postgres -A trust --locale=C -E UTF8 -D "$DATA" >/dev/null 2>&1
"$PG_BIN/pg_ctl" -D "$DATA" -w -o "-p 5544 -k $SOCK -c listen_addresses=''" -l "$DATA/server.log" start >/dev/null 2>&1
trap '"$PG_BIN/pg_ctl" -D "$DATA" -m fast stop >/dev/null 2>&1; rm -rf "$DATA" "$SOCK"' EXIT

export PGHOST="$SOCK" PGPORT=5544 PGUSER=postgres
psql() { "$PG_BIN/psql" -v ON_ERROR_STOP=1 -X -q "$@"; }

psql -d postgres -c "create database cheekypint_test" >/dev/null

echo "== shim + migrations =="
psql -d cheekypint_test -f "$HERE/_shim_bootstrap.sql" >/dev/null
for f in $(ls "$SUPA"/migrations/*.sql | sort); do
  printf '  %-52s' "$(basename "$f")"
  psql -d cheekypint_test -f "$f" >/dev/null 2>/tmp/cp_err && echo ok || { echo FAILED; cat /tmp/cp_err; exit 1; }
done

echo "== grants + seed =="
psql -d cheekypint_test -f "$HERE/_shim_grants.sql" >/dev/null
psql -d cheekypint_test -f "$SUPA/seed.sql" >/dev/null

echo "== RLS / RPC suite =="
psql -d cheekypint_test -f "$HERE/rls_rpc_suite.sql"
