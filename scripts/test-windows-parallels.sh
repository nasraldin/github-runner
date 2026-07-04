#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

VM_NAME="${VM_NAME:-Windows 11}"
PROJECT_ID="${PROJECT_ID:-}"
POOL_ID="${POOL_ID:-}"
RUN_ID="$(date +%s)"

log() {
  printf '[windows-e2e] %s\n' "$*"
}

fail() {
  printf '[windows-e2e] ERROR: %s\n' "$*" >&2
  exit 1
}

if [[ -z "${PROJECT_ID}" || -z "${POOL_ID}" ]]; then
  fail 'Set PROJECT_ID and POOL_ID, for example: PROJECT_ID=project-id POOL_ID=windows-arm64-native'
fi

encode_ps() {
  printf '%s' "$1" | iconv -f UTF-8 -t UTF-16LE | base64 | tr -d '\n'
}

win_ps() {
  local script="$1"
  local encoded
  encoded="$(encode_ps "${script}")"
  prlctl exec "${VM_NAME}" powershell.exe -NoProfile -ExecutionPolicy Bypass -EncodedCommand "${encoded}"
}

read_config() {
  node -e '
    const fs = require("fs");
    const configFile = process.env.CONFIG_FILE || "runners.config.json";
    const config = JSON.parse(fs.readFileSync(configFile, "utf8"));
    const project = config.projects.find((item) => item.id === process.env.PROJECT_ID);
    if (!project) throw new Error(`Unknown project: ${process.env.PROJECT_ID}`);
    const pool = project.pools.find((item) => item.id === process.env.POOL_ID);
    if (!pool) throw new Error(`Unknown pool: ${process.env.POOL_ID}`);
    const pkg = config.runnerPackages[pool.runnerPackage];
    if (!pkg) throw new Error(`Unknown runnerPackage: ${pool.runnerPackage}`);
    console.log([
      project.owner,
      project.repo,
      config.defaults.githubServerUrl,
      pool.namePrefix,
      (pool.labels || []).join(","),
      pkg.url,
      pkg.archive,
      pkg.sha256,
      pkg.arch
    ].join("\t"));
  '
}

command -v prlctl >/dev/null || fail "prlctl is not installed."
command -v gh >/dev/null || fail "GitHub CLI is not installed."
gh auth status >/dev/null || fail "GitHub CLI is not authenticated."

IFS=$'\t' read -r OWNER REPO GITHUB_SERVER_URL NAME_PREFIX LABELS PACKAGE_URL ARCHIVE SHA256 ARCH < <(
  PROJECT_ID="${PROJECT_ID}" POOL_ID="${POOL_ID}" read_config
)

REPO_URL="${GITHUB_SERVER_URL}/${OWNER}/${REPO}"
RUNNER_NAME="${NAME_PREFIX:-windows-runner}-e2e-${RUN_ID}"
WIN_DIR="C:\\actions-runner-e2e-${RUN_ID}"

cleanup() {
  set +e
  if [[ -n "${OWNER:-}" && -n "${REPO:-}" ]]; then
    remove_token="$(gh api -X POST "repos/${OWNER}/${REPO}/actions/runners/remove-token" --jq .token 2>/dev/null)"
    if [[ -n "${remove_token}" ]]; then
      win_ps "\$ErrorActionPreference = 'SilentlyContinue'
\$ProgressPreference = 'SilentlyContinue'
\$RunnerDir = '${WIN_DIR}'
if (Test-Path \$RunnerDir) {
  Get-CimInstance Win32_Process |
    Where-Object { \$_.CommandLine -and \$_.CommandLine.Contains(\$RunnerDir) -and \$_.ProcessId -ne \$PID } |
    ForEach-Object { Stop-Process -Id \$_.ProcessId -Force -ErrorAction SilentlyContinue }
  Start-Sleep -Seconds 2
  Set-Location \$RunnerDir
  if (Test-Path '.runner') {
    .\\config.cmd remove --token '${remove_token}' | Out-Null
  }
  Set-Location 'C:\\'
  Remove-Item -Path \$RunnerDir -Recurse -Force -ErrorAction SilentlyContinue
}" >/dev/null 2>&1 || true
    fi

    remaining="$(gh api "repos/${OWNER}/${REPO}/actions/runners" --jq "[.runners[] | select(.name == \"${RUNNER_NAME}\")] | length" 2>/dev/null)"
    log "remaining_test_runners=${remaining:-unknown}"
  fi
}

trap cleanup EXIT INT TERM

log "Testing ${PROJECT_ID}/${POOL_ID} on Parallels VM '${VM_NAME}'."
log "Runner architecture from config: ${ARCH}"
log "Runner name: ${RUNNER_NAME}"

REG_TOKEN="$(gh api -X POST "repos/${OWNER}/${REPO}/actions/runners/registration-token" --jq .token)"

win_ps "\$ErrorActionPreference = 'Stop'
\$ProgressPreference = 'SilentlyContinue'
\$RunnerDir = '${WIN_DIR}'
\$Archive = '${ARCHIVE}'
if (Test-Path \$RunnerDir) { Remove-Item -Path \$RunnerDir -Recurse -Force }
New-Item -ItemType Directory -Path \$RunnerDir | Out-Null
Set-Location \$RunnerDir
Invoke-WebRequest -Uri '${PACKAGE_URL}' -OutFile \$Archive
\$Hash = (Get-FileHash -Path \$Archive -Algorithm SHA256).Hash.ToLowerInvariant()
if (\$Hash -ne '${SHA256}') { throw \"Checksum mismatch: \$Hash\" }
Add-Type -AssemblyName System.IO.Compression.FileSystem
[System.IO.Compression.ZipFile]::ExtractToDirectory((Join-Path \$PWD \$Archive), \$PWD)
.\\config.cmd --url '${REPO_URL}' --token '${REG_TOKEN}' --name '${RUNNER_NAME}' --labels '${LABELS}' --work '_work' --unattended --replace --ephemeral
\$Launch = 'cd /d \"' + \$RunnerDir + '\" && start \"\" /min run.cmd > runner.out.log 2> runner.err.log'
Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', \$Launch -WorkingDirectory \$RunnerDir -WindowStyle Hidden
Write-Output 'started=detached'"

for attempt in {1..24}; do
  status="$(
    gh api "repos/${OWNER}/${REPO}/actions/runners" \
      --jq ".runners[] | select(.name == \"${RUNNER_NAME}\") | .status" 2>/dev/null || true
  )"
  log "status=${status:-missing}"
  if [[ "${status}" == "online" ]]; then
    gh api "repos/${OWNER}/${REPO}/actions/runners" \
      --jq ".runners[] | select(.name == \"${RUNNER_NAME}\") | {name,status,busy,labels:[.labels[].name]}"
    exit 0
  fi
  sleep 5
done

log "Runner did not become online. Fetching Windows runner logs."
win_ps "\$RunnerDir = '${WIN_DIR}'
if (Test-Path (Join-Path \$RunnerDir 'runner.out.log')) {
  Get-Content (Join-Path \$RunnerDir 'runner.out.log') -Tail 160
}
if (Test-Path (Join-Path \$RunnerDir 'runner.err.log')) {
  Get-Content (Join-Path \$RunnerDir 'runner.err.log') -Tail 160
}"
exit 1
