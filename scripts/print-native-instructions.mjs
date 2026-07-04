#!/usr/bin/env node
import { existsSync, readFileSync } from "node:fs";
import { resolve } from "node:path";

const rootDir = resolve(new URL("..", import.meta.url).pathname);
const configFile = process.env.CONFIG_FILE || "runners.config.json";
const configPath = resolve(rootDir, configFile);

if (!existsSync(configPath)) {
  console.error(
    `[native-instructions] ERROR: Missing ${configFile}. Copy runners.config.example.json to runners.config.json or set CONFIG_FILE.`
  );
  process.exit(1);
}

const config = JSON.parse(readFileSync(configPath, "utf8"));

const requestedProject = process.argv[2];
const requestedPool = process.argv[3];

function fail(message) {
  console.error(`[native-instructions] ERROR: ${message}`);
  process.exit(1);
}

if (!requestedProject || !requestedPool) {
  fail("Usage: node scripts/print-native-instructions.mjs <project-id> <pool-id>");
}

const project = config.projects.find((item) => item.id === requestedProject);
if (!project) {
  fail(`Unknown project id: ${requestedProject}`);
}

const pool = project.pools.find((item) => item.id === requestedPool);
if (!pool) {
  fail(`Unknown pool id for ${requestedProject}: ${requestedPool}`);
}

const runnerPackage = config.runnerPackages[pool.runnerPackage];
if (!runnerPackage) {
  fail(`Unknown runner package: ${pool.runnerPackage}`);
}

const baseRunnerName = pool.namePrefix || `${project.id}-${pool.id}`;
const repoUrl = `${config.defaults.githubServerUrl}/${project.owner}/${project.repo}`;
const labels = (pool.labels ?? []).join(",");
const unixRunnerName = `${baseRunnerName}-$(hostname)`;
const windowsRunnerName = `${baseRunnerName}-$env:COMPUTERNAME`;

if (runnerPackage.os === "macos" || runnerPackage.os === "linux") {
  console.log(`# ${project.id}/${pool.id}`);
  console.log(`mkdir -p actions-runner && cd actions-runner`);
  console.log(`curl -o ${runnerPackage.archive} -L ${runnerPackage.url}`);
  if (runnerPackage.sha256) {
    console.log(`echo "${runnerPackage.sha256}  ${runnerPackage.archive}" | shasum -a 256 -c`);
  }
  console.log(`tar xzf ./${runnerPackage.archive}`);
  console.log(`./config.sh --url ${repoUrl} --token "$GITHUB_RUNNER_REGISTRATION_TOKEN" --name "${unixRunnerName}" --labels "${labels}" --work "${pool.runnerWorkdir ?? config.defaults.runnerWorkdir}" --unattended --replace`);
  console.log(`./run.sh`);
  process.exit(0);
}

if (runnerPackage.os === "windows") {
  const archivePath = `$PWD\\${runnerPackage.archive}`;
  console.log(`# ${project.id}/${pool.id}`);
  console.log(String.raw`mkdir \actions-runner; cd \actions-runner`);
  console.log(`Invoke-WebRequest -Uri ${runnerPackage.url} -OutFile ${runnerPackage.archive}`);
  if (runnerPackage.sha256) {
    console.log(`if((Get-FileHash -Path ${runnerPackage.archive} -Algorithm SHA256).Hash.ToUpper() -ne '${runnerPackage.sha256}'.ToUpper()){ throw 'Computed checksum did not match' }`);
  }
  console.log(`Add-Type -AssemblyName System.IO.Compression.FileSystem`);
  console.log(`[System.IO.Compression.ZipFile]::ExtractToDirectory("${archivePath}", "$PWD")`);
  console.log(String.raw`.\config.cmd` + ` --url ${repoUrl} --token "$env:GITHUB_RUNNER_REGISTRATION_TOKEN" --name "${windowsRunnerName}" --labels "${labels}" --work "${pool.runnerWorkdir ?? config.defaults.runnerWorkdir}" --unattended --replace`);
  console.log(String.raw`.\run.cmd`);
  process.exit(0);
}

fail(`Unsupported OS: ${runnerPackage.os}`);

