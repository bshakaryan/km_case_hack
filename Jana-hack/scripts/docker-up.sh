#!/bin/sh
# Docker is the only runtime required on the host. Keep an existing .env intact.
set -eu

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$project_dir"

docker compose version >/dev/null
docker info >/dev/null

if [ ! -f .env ]; then
  docker run --rm --user "$(id -u):$(id -g)" \
    --mount "type=bind,source=$project_dir,target=/workspace" \
    --workdir /workspace \
    python:3.12-slim python scripts/setup_env.py
fi

docker compose up --build --detach --wait --wait-timeout 180 "$@"
