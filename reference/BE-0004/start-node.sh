#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
compose=(docker compose --project-directory "$script_dir" -f "$script_dir/docker-compose.yaml")

case "${1-}" in
  --node)
    exec "${compose[@]}" up -d besu-node
    ;;
  --full)
    exec "${compose[@]}" up -d \
      besu-node \
      blockscout-indexer \
      blockscout-backend \
      blockscout-frontend
    ;;
  "")
    exec "${compose[@]}" up -d
    ;;
  *)
    printf 'Usage: %s [--node|--full]\n' "$0" >&2
    exit 2
    ;;
esac
