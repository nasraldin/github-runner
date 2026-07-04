#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

ENV_FILE="${ENV_FILE:-.env}"
CONFIG_FILE="${CONFIG_FILE:-runners.config.json}"
GENERATED_FILE="${GENERATED_FILE:-compose.generated.yaml}"
COMPOSE_FILE="${COMPOSE_FILE:-compose.yaml}"
COMPOSE_TIMEOUT="${COMPOSE_TIMEOUT:-120}"
DESTROY_WORKDIR="${DESTROY_WORKDIR:-0}"
DESTROY_GENERATED="${DESTROY_GENERATED:-1}"
DESTROY_IMAGES="${DESTROY_IMAGES:-1}"
DESTROY_GITHUB_OFFLINE="${DESTROY_GITHUB_OFFLINE:-1}"

log() {
  printf '[destroy] %s\n' "$*"
}

warn() {
  printf '[destroy] WARN: %s\n' "$*" >&2
}

compose_down() {
  local file="$1"
  local label="$2"

  if [[ ! -f "${file}" ]]; then
    return
  fi

  if [[ ! -f "${ENV_FILE}" ]]; then
    warn "Skipping ${label}: missing ${ENV_FILE}"
    return
  fi

  log "Stopping ${label} (graceful shutdown, ${COMPOSE_TIMEOUT}s)..."
  docker compose --env-file "${ENV_FILE}" -f "${file}" down \
    -v \
    --remove-orphans \
    --timeout "${COMPOSE_TIMEOUT}" || warn "${label} down failed (may already be stopped)"
}

remove_images() {
  if [[ "${DESTROY_IMAGES}" != "1" ]]; then
    log "Skipping image removal (DESTROY_IMAGES=${DESTROY_IMAGES})"
    return
  fi

  if [[ ! -f "${CONFIG_FILE}" ]]; then
    warn "Skipping image removal: missing ${CONFIG_FILE}"
    return
  fi

  while IFS= read -r image; do
    [[ -z "${image}" ]] && continue
    if docker image inspect "${image}" >/dev/null 2>&1; then
      log "Removing image ${image}"
      docker image rm -f "${image}" || warn "Could not remove image ${image}"
    fi
  done < <(CONFIG_FILE="${CONFIG_FILE}" node scripts/generate-compose.mjs --images)

  local legacy_image="${RUNNER_IMAGE:-github-runner-manager:local}"
  if docker image inspect "${legacy_image}" >/dev/null 2>&1; then
    log "Removing legacy image ${legacy_image}"
    docker image rm -f "${legacy_image}" || true
  fi
}

remove_workdir() {
  if [[ "${DESTROY_WORKDIR}" != "1" ]]; then
    return
  fi

  if [[ ! -f "${CONFIG_FILE}" ]]; then
    warn "Skipping workdir removal: missing ${CONFIG_FILE}"
    return
  fi

  local workdir
  workdir="$(CONFIG_FILE="${CONFIG_FILE}" node scripts/generate-compose.mjs --workdir || true)"
  if [[ -z "${workdir}" ]]; then
    warn "No runnerWorkHostPath configured; nothing to remove from host"
    return
  fi

  if [[ ! -e "${workdir}" ]]; then
    log "Host workspace already absent: ${workdir}"
    return
  fi

  log "Removing host workspace ${workdir}"
  if [[ "$(id -u)" -eq 0 ]]; then
    rm -rf "${workdir}"
  elif rm -rf "${workdir}" 2>/dev/null; then
    :
  else
    warn "Could not remove ${workdir}. Run: sudo rm -rf ${workdir}"
  fi
}

remove_github_offline_runners() {
  if [[ "${DESTROY_GITHUB_OFFLINE}" != "1" ]]; then
    log "Skipping GitHub offline runner cleanup (DESTROY_GITHUB_OFFLINE=${DESTROY_GITHUB_OFFLINE})"
    return
  fi

  if [[ ! -f "${ENV_FILE}" || ! -f "${CONFIG_FILE}" ]]; then
    warn "Skipping GitHub cleanup: missing ${ENV_FILE} or ${CONFIG_FILE}"
    return
  fi

  set -a
  # shellcheck disable=SC1091
  source "${ENV_FILE}"
  set +a

  if [[ -z "${GITHUB_TOKEN:-}" ]]; then
    warn "Skipping GitHub offline runner cleanup: GITHUB_TOKEN not set"
    return
  fi

  command -v jq >/dev/null || {
    warn "Skipping GitHub offline runner cleanup: jq not installed"
    return
  }

  local api_url="${GITHUB_API_URL:-https://api.github.com}"
  local repos
  repos="$(jq -r '[.projects[] | "\(.owner)/\(.repo)"] | unique | .[]' "${CONFIG_FILE}")"

  while IFS= read -r repo_slug; do
    [[ -z "${repo_slug}" ]] && continue
    local owner="${repo_slug%%/*}"
    local repo="${repo_slug#*/}"

    log "Removing offline runners from ${owner}/${repo}..."
    local runners
    runners="$(curl -fsSL \
      -H "Accept: application/vnd.github+json" \
      -H "Authorization: Bearer ${GITHUB_TOKEN}" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      "${api_url}/repos/${owner}/${repo}/actions/runners?per_page=100" || true)"

    if [[ -z "${runners}" ]]; then
      warn "Could not list runners for ${owner}/${repo}"
      continue
    fi

    while IFS=$'\t' read -r runner_id runner_name; do
      [[ -z "${runner_id}" ]] && continue
      log "  Deleting offline runner ${runner_name} (${runner_id})"
      curl -fsSL -X DELETE \
        -H "Accept: application/vnd.github+json" \
        -H "Authorization: Bearer ${GITHUB_TOKEN}" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "${api_url}/repos/${owner}/${repo}/actions/runners/${runner_id}" >/dev/null \
        || warn "  Could not delete runner ${runner_name}"
    done < <(jq -r '.runners[] | select(.status == "offline") | [.id, .name] | @tsv' <<<"${runners}")
  done <<<"${repos}"
}

log "Destroying runner manager runtime state..."

compose_down "${GENERATED_FILE}" "generated pools"
compose_down "${COMPOSE_FILE}" "legacy compose stack"

remove_images

if [[ "${DESTROY_GENERATED}" == "1" && -f "${GENERATED_FILE}" ]]; then
  log "Removing ${GENERATED_FILE}"
  rm -f "${GENERATED_FILE}"
fi

remove_github_offline_runners
remove_workdir

log "Destroy complete."
log "Preserved: ${ENV_FILE}, ${CONFIG_FILE}"
log "Fresh start: make init-workdir (if needed), then make apply"

if [[ "${DESTROY_WORKDIR}" != "1" ]]; then
  log "Host workspace kept. Full wipe including _work: make destroy-all"
fi
