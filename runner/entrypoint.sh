#!/usr/bin/env bash
set -Eeuo pipefail

RUNNER_HOME="${RUNNER_HOME:-/home/runner/actions-runner}"
GITHUB_API_URL="${GITHUB_API_URL:-https://api.github.com}"
GITHUB_SERVER_URL="${GITHUB_SERVER_URL:-https://github.com}"
RUNNER_WORKDIR="${RUNNER_WORKDIR:-_work}"
RUNNER_GROUP="${RUNNER_GROUP:-Default}"
RUNNER_LABELS="${RUNNER_LABELS:-self-hosted,linux,x64,docker}"
RUNNER_NAME_PREFIX="${RUNNER_NAME_PREFIX:-github-runner}"
RUNNER_EPHEMERAL="${RUNNER_EPHEMERAL:-true}"
RUNNER_REPLACE_EXISTING="${RUNNER_REPLACE_EXISTING:-true}"
RUNNER_DISABLE_UPDATE="${RUNNER_DISABLE_UPDATE:-false}"

runner_pid=""
configured="false"

log() {
  printf '[github-runner] %s\n' "$*"
}

# Bind-mounted host trees (workspaces, pnpm-store, toolcache) can contain huge CI
# artifacts. Never chown -R through them — it blocks startup for minutes with no logs.
chown_runner_top() {
  local path="$1"
  if [[ -e "${path}" ]]; then
    chown runner:runner "${path}" 2>/dev/null || true
  fi
}

fail() {
  printf '[github-runner] ERROR: %s\n' "$*" >&2
  exit 1
}

require_env() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    fail "Missing required environment variable: ${name}"
  fi
}

github_api_post() {
  local path="$1"
  if [[ -z "${github_token:-}" ]]; then
    fail "GITHUB_TOKEN is required for GitHub API calls. Set it for production auto-registration and clean deregistration."
  fi

  curl -fsSL \
    -X POST \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer ${github_token}" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "${GITHUB_API_URL}${path}"
}

registration_token() {
  github_api_post "/repos/${GITHUB_OWNER}/${GITHUB_REPO}/actions/runners/registration-token" | jq -r '.token'
}

remove_token() {
  github_api_post "/repos/${GITHUB_OWNER}/${GITHUB_REPO}/actions/runners/remove-token" | jq -r '.token'
}

configure_docker_socket_access() {
  if [[ ! -S /var/run/docker.sock ]]; then
    log "Docker socket is not mounted; Docker-based workflow steps will not work."
    return
  fi

  local socket_gid
  socket_gid="${DOCKER_GID:-$(stat -c '%g' /var/run/docker.sock)}"

  if ! getent group "${socket_gid}" >/dev/null; then
    groupadd --gid "${socket_gid}" docker-host
  fi

  local group_name
  group_name="$(getent group "${socket_gid}" | cut -d: -f1)"
  usermod -aG "${group_name}" runner
  log "Added runner user to Docker socket group ${group_name} (${socket_gid})."
}

configure_per_instance_workdir() {
  local actions_runner_host="${RUNNER_DOCKER_HOST_PATH_PREFIX:-}"
  local actions_runner_container="${RUNNER_DOCKER_CONTAINER_PATH_PREFIX:-${RUNNER_HOME}}"

  if [[ -z "${actions_runner_host}" || "${actions_runner_host}" == "${actions_runner_container}" ]]; then
    mkdir -p "${RUNNER_HOME}/${RUNNER_WORKDIR}"
    chown_runner_top "${RUNNER_HOME}/${RUNNER_WORKDIR}"
    return
  fi

  local instance_id="${HOSTNAME}"
  RUNNER_WORKDIR="workspaces/${instance_id}/_work"

  mkdir -p "${RUNNER_HOME}/${RUNNER_WORKDIR}"
  chown_runner_top "${RUNNER_HOME}/workspaces"
  chown_runner_top "${RUNNER_HOME}/workspaces/${instance_id}"
  chown_runner_top "${RUNNER_HOME}/${RUNNER_WORKDIR}"

  local legacy_work_link="${RUNNER_HOME}/_work"
  if [[ -L "${legacy_work_link}" ]]; then
    rm -f "${legacy_work_link}"
  fi

  log "Per-instance workdir: ${RUNNER_HOME}/${RUNNER_WORKDIR}"
}

seed_externals_if_empty() {
  local seed="/opt/runner-externals-seed"
  if [[ ! -d "${seed}" ]]; then
    return
  fi

  mkdir -p "${RUNNER_HOME}/externals"
  if [[ -z "$(ls -A "${RUNNER_HOME}/externals" 2>/dev/null)" ]]; then
    cp -a "${seed}/." "${RUNNER_HOME}/externals/"
    log "Seeded ${RUNNER_HOME}/externals from image (host bind mount was empty)."
  fi
  chown_runner_top "${RUNNER_HOME}/externals"
}

ensure_docker_host_directories() {
  mkdir -p "${AGENT_TOOLSDIRECTORY:-/opt/hostedtoolcache}"
  chown_runner_top "${AGENT_TOOLSDIRECTORY:-/opt/hostedtoolcache}"

  mkdir -p /home/runner/.local/share/pnpm/store
  chown_runner_top /home/runner/.local/share/pnpm
  chown_runner_top /home/runner/.local/share/pnpm/store

  if [[ -n "${RUNNER_DOCKER_HOST_TOOLCACHE_PATH:-}" ]]; then
    log "Hosted toolcache bind mount: ${AGENT_TOOLSDIRECTORY:-/opt/hostedtoolcache}"
  fi
}

reset_existing_configuration() {
  if [[ ! -f "${RUNNER_HOME}/.runner" ]]; then
    return
  fi

  log "Existing local runner configuration found; removing it before re-registering."
  local token
  if [[ -n "${github_token:-}" ]] && token="$(remove_token 2>/dev/null)" && [[ -n "${token}" && "${token}" != "null" ]]; then
    runuser -u runner -- "${RUNNER_HOME}/config.sh" remove --unattended --token "${token}" || true
  else
    log "No GitHub remove token available; removing only local runner configuration."
  fi

  rm -f \
    "${RUNNER_HOME}/.runner" \
    "${RUNNER_HOME}/.credentials" \
    "${RUNNER_HOME}/.credentials_rsaparams"
}

cleanup() {
  local exit_code=$?
  trap - EXIT INT TERM

  if [[ -n "${runner_pid}" ]] && kill -0 "${runner_pid}" 2>/dev/null; then
    log "Stopping runner listener."
    kill -TERM "${runner_pid}" 2>/dev/null || true
    wait "${runner_pid}" 2>/dev/null || true
  fi

  if [[ "${configured}" == "true" && -f "${RUNNER_HOME}/.runner" ]]; then
    log "Removing runner registration from GitHub."
    local token
    if [[ -n "${github_token:-}" ]] && token="$(remove_token 2>/dev/null)" && [[ -n "${token}" && "${token}" != "null" ]]; then
      runuser -u runner -- "${RUNNER_HOME}/config.sh" remove --unattended --token "${token}" || true
    else
      log "Could not create remove token; the runner may need manual cleanup in GitHub settings."
    fi
  fi

  exit "${exit_code}"
}

trap cleanup EXIT INT TERM

require_env GITHUB_OWNER
require_env GITHUB_REPO

github_token="${GITHUB_TOKEN:-}"
unset GITHUB_TOKEN

mkdir -p "${AGENT_TOOLSDIRECTORY:-/opt/hostedtoolcache}"
chown_runner_top "${AGENT_TOOLSDIRECTORY:-/opt/hostedtoolcache}"

seed_externals_if_empty
configure_per_instance_workdir
ensure_docker_host_directories
configure_docker_socket_access
reset_existing_configuration

runner_name="${RUNNER_NAME:-${RUNNER_NAME_PREFIX}-${HOSTNAME}}"
repo_url="${GITHUB_SERVER_URL}/${GITHUB_OWNER}/${GITHUB_REPO}"

if [[ -n "${GITHUB_RUNNER_REGISTRATION_TOKEN:-}" ]]; then
  log "Using one-hour registration token from GITHUB_RUNNER_REGISTRATION_TOKEN."
  token="${GITHUB_RUNNER_REGISTRATION_TOKEN}"
else
  token="$(registration_token)"
fi
unset GITHUB_RUNNER_REGISTRATION_TOKEN

if [[ -z "${token}" || "${token}" == "null" ]]; then
  fail "GitHub did not return a runner registration token."
fi

config_args=(
  --unattended
  --url "${repo_url}"
  --token "${token}"
  --name "${runner_name}"
  --work "${RUNNER_WORKDIR}"
  --labels "${RUNNER_LABELS}"
)

if [[ "${RUNNER_GROUP}" != "Default" ]]; then
  config_args+=(--runnergroup "${RUNNER_GROUP}")
fi

if [[ "${RUNNER_EPHEMERAL}" == "true" ]]; then
  config_args+=(--ephemeral)
fi

if [[ "${RUNNER_REPLACE_EXISTING}" == "true" ]]; then
  config_args+=(--replace)
fi

if [[ "${RUNNER_DISABLE_UPDATE}" == "true" ]]; then
  config_args+=(--disableupdate)
fi

log "Registering ${runner_name} for ${repo_url} with labels: ${RUNNER_LABELS}"
runuser -u runner -- "${RUNNER_HOME}/config.sh" "${config_args[@]}"
configured="true"

log "Starting runner listener."
runuser -u runner -- "${RUNNER_HOME}/run.sh" &
runner_pid="$!"
wait "${runner_pid}"
