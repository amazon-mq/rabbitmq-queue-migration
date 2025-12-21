#!/usr/bin/env bash

set -euo pipefail

script_dir="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly script_dir

wait_for_message() {
    while ! docker compose logs "$1" 2>&1 | grep -q "$2"; do
        echo "Waiting 5 seconds for $1 to start..."
        sleep 5
    done
}

echo "[INFO] starting RabbitMQ cluster..."

docker compose --file "$script_dir/docker-compose.yml" up --detach

wait_for_message rmq0 "completed with"
wait_for_message rmq1 "completed with"
wait_for_message rmq2 "completed with"

echo "[INFO] waiting for cluster formation..."
docker compose exec rmq0 rabbitmqctl await_online_nodes 3

echo "[INFO] cluster status:"
docker compose exec rmq0 rabbitmqctl cluster_status

echo "[INFO] RabbitMQ cluster started successfully"
