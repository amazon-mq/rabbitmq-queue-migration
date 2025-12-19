#!/usr/bin/env bash

set -euo pipefail

script_dir="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly script_dir

echo "[INFO] stopping RabbitMQ cluster..."
docker compose --file "$script_dir/docker-compose.yml" down
echo "[INFO] RabbitMQ cluster stopped"
