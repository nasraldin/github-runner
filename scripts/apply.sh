#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

ENV_FILE="${ENV_FILE:-.env}"
CONFIG_FILE="${CONFIG_FILE:-runners.config.json}"
GENERATED_FILE="${GENERATED_FILE:-compose.generated.yaml}"

if [[ ! -f "${ENV_FILE}" ]]; then
  printf '[apply] ERROR: Missing %s. Copy .env.example to it and set GITHUB_TOKEN.\n' "${ENV_FILE}" >&2
  exit 1
fi

CONFIG_FILE="${CONFIG_FILE}" GENERATED_FILE="${GENERATED_FILE}" node scripts/generate-compose.mjs
scale_args="$(CONFIG_FILE="${CONFIG_FILE}" node scripts/generate-compose.mjs --scale-args)"

docker compose --env-file "${ENV_FILE}" -f "${GENERATED_FILE}" build

# shellcheck disable=SC2086
docker compose --env-file "${ENV_FILE}" -f "${GENERATED_FILE}" up -d ${scale_args}
