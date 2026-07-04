#!/usr/bin/env bash
# Rewrites Docker bind-mount sources from runner container paths to Docker host paths.
# Required on macOS Docker Desktop when the runner runs in a container but job/service
# containers are started via the host docker.sock using /home/runner/actions-runner/...
set -Eeuo pipefail

DOCKER_REAL="${DOCKER_REAL:-/usr/bin/docker}"
HOST_PREFIX="${RUNNER_DOCKER_HOST_PATH_PREFIX:-}"
CONTAINER_PREFIX="${RUNNER_DOCKER_CONTAINER_PATH_PREFIX:-}"
HOST_TOOLCACHE_PATH="${RUNNER_DOCKER_HOST_TOOLCACHE_PATH:-}"
CONTAINER_TOOLCACHE_PATH="/opt/hostedtoolcache"
HOST_WORK_PATH="${RUNNER_DOCKER_HOST_WORK_PATH:-}"
CONTAINER_WORK_PATH="${RUNNER_DOCKER_CONTAINER_WORK_PATH:-}"
INSTANCE_ID="${RUNNER_DOCKER_INSTANCE_ID:-${HOSTNAME}}"

if [[ -z "${HOST_WORK_PATH}" && -n "${HOST_PREFIX}" && -n "${CONTAINER_PREFIX}" && "${HOST_PREFIX}" != "${CONTAINER_PREFIX}" ]]; then
  CONTAINER_WORK_PATH="${CONTAINER_PREFIX}/workspaces/${INSTANCE_ID}/_work"
  HOST_WORK_PATH="${HOST_PREFIX}/workspaces/${INSTANCE_ID}/_work"
fi

rewrite_volume() {
  local vol="$1"

  if [[ "${vol}" == \"*\" && "${vol}" == *\" ]]; then
    vol="${vol#\"}"
    vol="${vol%\"}"
  fi

  if [[ -n "${HOST_TOOLCACHE_PATH}" && "${vol}" == "${CONTAINER_TOOLCACHE_PATH}"* ]]; then
    printf '%s' "${HOST_TOOLCACHE_PATH}${vol#${CONTAINER_TOOLCACHE_PATH}}"
    return
  fi

  if [[ -n "${HOST_WORK_PATH}" && -n "${CONTAINER_WORK_PATH}" && "${vol}" == "${CONTAINER_WORK_PATH}"* ]]; then
    printf '%s' "${HOST_WORK_PATH}${vol#${CONTAINER_WORK_PATH}}"
    return
  fi

  if [[ -n "${HOST_PREFIX}" && -n "${CONTAINER_PREFIX}" && -n "${INSTANCE_ID}" && "${vol}" == "${CONTAINER_PREFIX}/workspaces/${INSTANCE_ID}"* ]]; then
    printf '%s' "${HOST_PREFIX}/workspaces/${INSTANCE_ID}${vol#${CONTAINER_PREFIX}/workspaces/${INSTANCE_ID}}"
    return
  fi

  if [[ -n "${HOST_PREFIX}" && -n "${CONTAINER_PREFIX}" && "${vol}" == "${CONTAINER_PREFIX}"* ]]; then
    printf '%s' "${HOST_PREFIX}${vol#${CONTAINER_PREFIX}}"
    return
  fi

  printf '%s' "${vol}"
}

args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -v | --volume)
      if [[ $# -lt 2 ]]; then
        echo "docker-wrapper: missing value for $1" >&2
        exit 1
      fi
      args+=("$1" "$(rewrite_volume "$2")")
      shift 2
      ;;
    *)
      args+=("$1")
      shift
      ;;
  esac
done

exec "${DOCKER_REAL}" "${args[@]}"
