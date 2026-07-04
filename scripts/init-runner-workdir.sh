#!/usr/bin/env bash
set -Eeuo pipefail

WORK_DIR="/home/runner/actions-runner/_work"
RUNNER_UID="${RUNNER_UID:-1000}"
RUNNER_GID="${RUNNER_GID:-1000}"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run with sudo: sudo $0" >&2
  exit 1
fi

mkdir -p "${WORK_DIR}"
chown -R "${RUNNER_UID}:${RUNNER_GID}" /home/runner/actions-runner

echo "Created ${WORK_DIR}"
ls -la /home/runner/actions-runner/
