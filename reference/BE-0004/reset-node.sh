#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
compose=(docker compose --project-directory "$script_dir" -f "$script_dir/docker-compose.yaml")

case "${1-}" in
  ""|--help|-h)
    if [[ -n "${1-}" ]]; then
      printf 'Usage: %s\n' "$0"
      printf 'Stops this BE-0004 Compose project, removes its named volumes, and deletes data/singlenode.\n'
      exit 0
    fi
    ;;
  *)
    printf 'Usage: %s [--help]\n' "$0" >&2
    exit 2
    ;;
esac

printf 'This will stop and remove BE-0004 services, delete their named volumes (including databases),\n'
printf 'and permanently delete %s/data/singlenode.\n' "$script_dir"
printf 'Config files and the node key will be kept.\n'
read -r -p 'Continue? Type yes to confirm: ' answer
if [[ "$answer" != "yes" ]]; then
  printf 'Reset cancelled.\n'
  exit 0
fi

"${compose[@]}" down --volumes
rm -rf -- "$script_dir/data/singlenode"
printf 'BE-0004 reset complete.\n'
