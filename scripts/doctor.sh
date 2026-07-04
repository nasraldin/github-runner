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

ENV_FILE="${ENV_FILE:-.env}"
CONFIG_FILE="${CONFIG_FILE:-runners.config.json}"

if [[ ! -f "${ENV_FILE}" ]]; then
  fail "Missing ${ENV_FILE}. Copy .env.example to ${ENV_FILE} and set GITHUB_TOKEN."
fi

set -a
# shellcheck disable=SC1091
source "${ENV_FILE}"
set +a

command -v docker >/dev/null || fail "docker is not installed."
docker compose version >/dev/null || fail "docker compose plugin is not installed."
command -v jq >/dev/null || fail "jq is not installed."
command -v node >/dev/null || fail "node is not installed."

socket_group_id() {
  local path="$1"

  if stat -c '%g' "${path}" >/dev/null 2>&1; then
    stat -c '%g' "${path}"
    return
  fi

  if stat -f '%g' "${path}" >/dev/null 2>&1; then
    stat -f '%g' "${path}"
    return
  fi

  fail "Could not determine Docker socket group id for ${path}."
}

if [[ ! -S /var/run/docker.sock ]]; then
  fail "Docker socket /var/run/docker.sock was not found."
fi

socket_gid="$(socket_group_id /var/run/docker.sock)"
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
    log "Ready for a short manual startup test using ${CONFIG_FILE}."
    exit 0
  fi

  fail "Set GITHUB_TOKEN for production, or set GITHUB_RUNNER_REGISTRATION_TOKEN for a short manual test."
fi

repos=()
if [[ -f "${CONFIG_FILE}" ]]; then
  while IFS= read -r repo; do
    repos+=("${repo}")
  done < <(
    CONFIG_FILE="${CONFIG_FILE}" node <<'NODE'
const fs = require("node:fs");
const config = JSON.parse(fs.readFileSync(process.env.CONFIG_FILE, "utf8"));
const repos = new Set();
for (const project of config.projects ?? []) {
  const pools = project.pools ?? [];
  if (pools.length === 0 || pools.some((pool) => pool.enabled)) {
    repos.add(`${project.owner}/${project.repo}`);
  }
}
for (const repo of repos) {
  console.log(repo);
}
NODE
  )
elif [[ -n "${GITHUB_OWNER:-}" && -n "${GITHUB_REPO:-}" ]]; then
  repos+=("${GITHUB_OWNER}/${GITHUB_REPO}")
else
  fail "Missing ${CONFIG_FILE}. Run make config-init, or set GITHUB_OWNER and GITHUB_REPO for single-pool compatibility."
fi

if [[ "${#repos[@]}" -eq 0 ]]; then
  fail "No repositories found in ${CONFIG_FILE}."
fi

tmp_body="$(mktemp)"
cleanup() {
  rm -f "${tmp_body}"
}
trap cleanup EXIT

for repo in "${repos[@]}"; do
  api_url="https://api.github.com/repos/${repo}/actions/runners/registration-token"
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
    log "GitHub API response for ${repo}:"
    jq -r '.message // .' "${tmp_body}" 2>/dev/null || true
    fail "Could not create a repository runner registration token for ${repo}. HTTP ${http_code}."
  fi

  if ! jq -e '.token and .expires_at' "${tmp_body}" >/dev/null; then
    fail "GitHub API response for ${repo} did not include token and expires_at."
  fi

  expires_at="$(jq -r '.expires_at' "${tmp_body}")"
  log "GitHub runner registration endpoint works for ${repo}. Test token expires at ${expires_at}."
done

log "Ready to start runners from ${CONFIG_FILE}."
