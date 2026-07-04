#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

log() {
  printf '[doctor] %s\n' "$*"
}

fail() {
  printf '[doctor] ERROR: %s\n' "$*" >&2
  exit 1
}

if [[ ! -f .env ]]; then
  fail "Missing .env. Copy .env.example to .env and set GITHUB_TOKEN."
fi

set -a
# shellcheck disable=SC1091
source .env
set +a

: "${GITHUB_OWNER:?Set GITHUB_OWNER in .env}"
: "${GITHUB_REPO:?Set GITHUB_REPO in .env}"

command -v docker >/dev/null || fail "docker is not installed."
docker compose version >/dev/null || fail "docker compose plugin is not installed."

if [[ ! -S /var/run/docker.sock ]]; then
  fail "Docker socket /var/run/docker.sock was not found."
fi

socket_gid="$(stat -c '%g' /var/run/docker.sock)"
log "Docker socket group id: ${socket_gid}"
if [[ -z "${DOCKER_GID:-}" ]]; then
  log "DOCKER_GID is not set; the runner entrypoint will auto-detect ${socket_gid}."
elif [[ "${DOCKER_GID}" != "${socket_gid}" ]]; then
  log "DOCKER_GID=${DOCKER_GID}, but the current Docker socket group id is ${socket_gid}."
fi

if [[ -z "${GITHUB_TOKEN:-}" ]]; then
  if [[ -n "${GITHUB_RUNNER_REGISTRATION_TOKEN:-}" ]]; then
    log "GITHUB_TOKEN is empty and a manual one-hour runner registration token is set."
    log "Skipping GitHub API registration-token validation. Production should use GITHUB_TOKEN."
    log "Ready for a short manual startup test for ${GITHUB_OWNER}/${GITHUB_REPO}."
    exit 0
  fi

  fail "Set GITHUB_TOKEN for production, or set GITHUB_RUNNER_REGISTRATION_TOKEN for a short manual test."
fi

tmp_body="$(mktemp)"
cleanup() {
  rm -f "${tmp_body}"
}
trap cleanup EXIT

api_url="https://api.github.com/repos/${GITHUB_OWNER}/${GITHUB_REPO}/actions/runners/registration-token"
http_code="$(
  curl -sS \
    -o "${tmp_body}" \
    -w '%{http_code}' \
    -X POST \
    -H 'Accept: application/vnd.github+json' \
    -H "Authorization: Bearer ${GITHUB_TOKEN}" \
    -H 'X-GitHub-Api-Version: 2022-11-28' \
    "${api_url}"
)"

if [[ "${http_code}" != "201" ]]; then
  log "GitHub API response:"
  jq -r '.message // .' "${tmp_body}" 2>/dev/null || true
  fail "Could not create a repository runner registration token. HTTP ${http_code}."
fi

if ! jq -e '.token and .expires_at' "${tmp_body}" >/dev/null; then
  fail "GitHub API response did not include token and expires_at."
fi

expires_at="$(jq -r '.expires_at' "${tmp_body}")"
log "GitHub runner registration endpoint works. Test token expires at ${expires_at}."
log "Ready to start runners for ${GITHUB_OWNER}/${GITHUB_REPO}."

