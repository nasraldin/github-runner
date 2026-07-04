#!/usr/bin/env bash
set -Eeuo pipefail

CONTAINER_WORK_DIR="/home/runner/actions-runner/_work"
RUNNER_UID="${RUNNER_UID:-1000}"
RUNNER_GID="${RUNNER_GID:-1000}"

log() {
  printf '[init-runner-workdir] %s\n' "$*"
}

require_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    echo "Run with sudo: sudo $0" >&2
    exit 1
  fi
}

print_config_hint() {
  local host_work="$1"
  local host_toolcache="$2"
  log ""
  log "Add to runners.config.json (under defaults or per pool):"
  log "  \"runnerWorkHostPath\": \"${host_work}\","
  log "  \"runnerWorkContainerPath\": \"${CONTAINER_WORK_DIR}\""
  if [[ -n "${host_toolcache}" ]]; then
    log "  \"runnerToolcacheHostPath\": \"${host_toolcache}\""
  fi
  log ""
  log "Then run: make apply"
}

toolcache_from_work() {
  local host_work="$1"
  if [[ "${host_work}" == *"/actions-runner/_work" ]]; then
    printf '%s' "${host_work%/actions-runner/_work}/hostedtoolcache"
    return
  fi
  if [[ "${host_work}" == "/home/runner/actions-runner/_work" ]]; then
    printf '%s' "/home/runner/hostedtoolcache"
    return
  fi
  printf '%s' ""
}

pnpm_store_from_work() {
  local host_work="$1"
  if [[ "${host_work}" == *"/actions-runner/_work" ]]; then
    printf '%s' "${host_work%/actions-runner/_work}/pnpm-store"
    return
  fi
  if [[ "${host_work}" == "/home/runner/actions-runner/_work" ]]; then
    printf '%s' "/home/runner/pnpm-store"
    return
  fi
  printf '%s' ""
}

ensure_host_dirs() {
  local host_work="$1"
  local host_toolcache="$2"
  local host_pnpm_store="$3"
  local owner_user="${4:-}"
  local owner_group="${5:-}"
  local actions_runner_root
  actions_runner_root="$(dirname "${host_work}")"

  mkdir -p "${host_work}" "${host_toolcache}" "${host_pnpm_store}" "${actions_runner_root}/workspaces" "${actions_runner_root}/externals"
  log "Created ${host_work}"
  log "Created ${host_toolcache}"
  log "Created ${host_pnpm_store}"
  log "Created ${actions_runner_root}/workspaces"
  log "Created ${actions_runner_root}/externals"

  if [[ -n "${owner_user}" ]]; then
    log "Setting ownership on host directories (top level only; skipping workspace contents)."
    chown "${owner_user}:${owner_group}" \
      "${host_work}" \
      "${host_toolcache}" \
      "${host_pnpm_store}" \
      "${actions_runner_root}" \
      "${actions_runner_root}/workspaces" \
      "${actions_runner_root}/externals" \
      2>/dev/null || true
  fi
}

mac_invoke_user() {
  if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    printf '%s' "${SUDO_USER}"
    return
  fi
  if [[ -n "${USER:-}" && "${USER}" != "root" ]]; then
    printf '%s' "${USER}"
    return
  fi
  local console_user
  console_user="$(stat -f '%Su' /dev/console 2>/dev/null || true)"
  if [[ -n "${console_user}" && "${console_user}" != "root" ]]; then
    printf '%s' "${console_user}"
    return
  fi
  logname 2>/dev/null || printf '%s' "${SUDO_USER:-root}"
}

init_macos() {
  local host_work=""
  local host_toolcache=""
  local mac_user
  mac_user="$(mac_invoke_user)"
  local mac_root="${MAC_USER_ROOT:-/Users/${mac_user}/github-runner}"

  log "macOS: creating host directories Docker Desktop can share."

  # Some Macs allow real directories under /home with sudo; symlinks do not work.
  if mkdir -p /home/runner/actions-runner/_work /home/runner/hostedtoolcache 2>/dev/null \
    && [[ -d /home/runner/actions-runner/_work ]]; then
    host_work="/home/runner/actions-runner/_work"
    host_toolcache="/home/runner/hostedtoolcache"
    log "Created ${host_work} and ${host_toolcache} directly under /home."
  else
    log "/home is not usable on this Mac — using ${mac_root} instead."
    log "(Symlinks like /home/runner -> /Users/runner fail with 'Operation not supported'.)"
    host_work="${mac_root}/actions-runner/_work"
    host_toolcache="${mac_root}/hostedtoolcache"
    ensure_host_dirs "${host_work}" "${host_toolcache}" "${mac_root}/pnpm-store" "${mac_user}" "staff"
  fi

  ls -la "$(dirname "${host_work}")/"
  ls -la "${host_toolcache}/"
  print_config_hint "${host_work}" "${host_toolcache}"
}

init_linux() {
  local host_work="${CONTAINER_WORK_DIR}"
  local host_toolcache
  host_toolcache="$(toolcache_from_work "${host_work}")"
  local host_pnpm_store
  host_pnpm_store="$(pnpm_store_from_work "${host_work}")"

  log "Linux: creating host directories for runner bind mounts."

  mkdir -p "${host_work}" "${host_toolcache}" "${host_pnpm_store}" /home/runner/actions-runner/workspaces /home/runner/actions-runner/externals
  chown "${RUNNER_UID}:${RUNNER_GID}" \
    /home/runner/actions-runner \
    "${host_work}" \
    "${host_toolcache}" \
    "${host_pnpm_store}" \
    /home/runner/actions-runner/workspaces \
    /home/runner/actions-runner/externals \
    2>/dev/null || true

  log "Created ${host_work}"
  log "Created ${host_toolcache}"
  ls -la /home/runner/actions-runner/
  ls -la "${host_toolcache}/"
  print_config_hint "${host_work}" "${host_toolcache}"
}

case "$(uname -s)" in
  Darwin)
    require_root
    init_macos
    ;;
  Linux)
    require_root
    init_linux
    ;;
  *)
    echo "Unsupported OS: $(uname -s). Use Linux or macOS." >&2
    exit 1
    ;;
esac
