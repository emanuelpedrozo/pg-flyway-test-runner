#!/usr/bin/env bash
set -euo pipefail

MODULE="${1:-dpg}"
ACTION="${2:-all}"

export MODULE

case "$ACTION" in
  up)
    docker compose up -d postgres
    ;;
  migrate)
    docker compose run --rm flyway-migrate
    ;;
  test)
    docker compose run --rm db-tests
    ;;
  reset)
    docker compose down -v
    docker compose up -d postgres
    docker compose run --rm flyway-migrate
    ;;
  all)
    docker compose up -d postgres
    docker compose run --rm flyway-migrate
    docker compose run --rm db-tests
    ;;
  *)
    echo "Uso: $0 [module] [up|migrate|test|reset|all]"
    exit 1
    ;;
esac
