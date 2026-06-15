#!/usr/bin/env bash
#
# Project-local PostgreSQL 16 cluster manager (mise-provisioned, no sudo).
#
# The server binaries come from the mise-pinned `postgres@16.14` tool, the data
# directory lives in the (gitignored) project-local `.pgdata/`, and the server
# listens on localhost:5432 with trust auth as superuser `postgres` — matching
# config/dev.exs and config/test.exs (username/password "postgres").
#
# Usage:
#   scripts/pg.sh init      # one-time: initialize the cluster
#   scripts/pg.sh start     # start the server (daemonized)
#   scripts/pg.sh stop      # stop the server
#   scripts/pg.sh restart
#   scripts/pg.sh status
#   scripts/pg.sh psql -- [args]   # open psql against the cluster
#
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PGDATA="${PGDATA:-$PROJECT_DIR/.pgdata}"
PGPORT="${PGPORT:-5432}"
PGHOST="localhost"
SOCKDIR="${PGSOCKDIR:-/tmp}"
LOG="$PGDATA/server.log"
MISE=(mise -C "$PROJECT_DIR" exec --)

case "${1:-}" in
  init)
    if [ -d "$PGDATA/base" ]; then
      echo "cluster already initialized at $PGDATA"; exit 0
    fi
    mkdir -p "$PGDATA"
    "${MISE[@]}" initdb -D "$PGDATA" -U postgres --auth=trust --encoding=UTF8 >/dev/null
    echo "initialized cluster at $PGDATA (superuser: postgres, trust auth)"
    ;;
  start)
    "${MISE[@]}" pg_ctl -D "$PGDATA" -l "$LOG" \
      -o "-c listen_addresses=localhost -c port=$PGPORT -c unix_socket_directories=$SOCKDIR" \
      start
    ;;
  stop)
    "${MISE[@]}" pg_ctl -D "$PGDATA" stop -m fast || true
    ;;
  restart)
    "$0" stop || true
    "$0" start
    ;;
  status)
    "${MISE[@]}" pg_ctl -D "$PGDATA" status || true
    "${MISE[@]}" pg_isready -h "$PGHOST" -p "$PGPORT" || true
    ;;
  psql)
    shift
    [ "${1:-}" = "--" ] && shift || true
    "${MISE[@]}" psql -h "$PGHOST" -p "$PGPORT" -U postgres "$@"
    ;;
  *)
    echo "usage: scripts/pg.sh {init|start|stop|restart|status|psql}"; exit 1
    ;;
esac
