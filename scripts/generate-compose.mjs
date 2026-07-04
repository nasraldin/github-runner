#!/usr/bin/env node
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";

const rootDir = resolve(new URL("..", import.meta.url).pathname);
const configFile = process.env.CONFIG_FILE || "runners.config.json";
const generatedFile = process.env.GENERATED_FILE || "compose.generated.yaml";
const configPath = resolve(rootDir, configFile);
const outputPath = resolve(rootDir, generatedFile);

const args = new Set(process.argv.slice(2));

if (!existsSync(configPath)) {
  console.error(
    `[generate-compose] ERROR: Missing ${configFile}. Copy runners.config.example.json to runners.config.json or set CONFIG_FILE.`,
  );
  process.exit(1);
}

const config = JSON.parse(readFileSync(configPath, "utf8"));

function fail(message) {
  console.error(`[generate-compose] ERROR: ${message}`);
  process.exit(1);
}

function serviceName(projectId, poolId) {
  return `${projectId}-${poolId}`
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-|-$/g, "");
}

function quote(value) {
  return JSON.stringify(String(value));
}

function actionsRunnerHostPath(workHostPath) {
  if (!workHostPath) {
    return "";
  }
  if (workHostPath.endsWith("/_work")) {
    return workHostPath.slice(0, -"/_work".length);
  }
  return workHostPath;
}

function toolcacheHostPath(workHostPath, explicitPath) {
  if (explicitPath) {
    return explicitPath;
  }
  if (!workHostPath) {
    return "";
  }
  const match = workHostPath.match(/^(.*)\/actions-runner\/[^/]+$/);
  if (match) {
    return `${match[1]}/hostedtoolcache`;
  }
  return "";
}

function pnpmStoreHostPath(workHostPath, explicitPath) {
  if (explicitPath) {
    return explicitPath;
  }
  if (!workHostPath) {
    return "";
  }
  const match = workHostPath.match(/^(.*)\/actions-runner\/[^/]+$/);
  if (match) {
    return `${match[1]}/pnpm-store`;
  }
  return "";
}

function pnpmStoreVolumeLines(pnpmStoreHost, pnpmStoreContainer) {
  if (!pnpmStoreHost) {
    return [];
  }
  return [`      - ${pnpmStoreHost}:${pnpmStoreContainer}`];
}

function workspaceVolumeLines(workHostPath, workContainerPath) {
  if (workHostPath) {
    return [`      - ${workHostPath}:${workContainerPath}`];
  }
  return [];
}

function externalsVolumeLines(actionsRunnerHost, actionsRunnerContainer) {
  if (!actionsRunnerHost || actionsRunnerHost === actionsRunnerContainer) {
    return [];
  }
  return [
    `      - ${actionsRunnerHost}/externals:${actionsRunnerContainer}/externals`,
  ];
}

function runnerWorkVolumeLines(
  dockerPathRewrite,
  workHostPath,
  workContainerPath,
  actionsRunnerHost,
  actionsRunnerContainer,
) {
  if (dockerPathRewrite && actionsRunnerHost) {
    return [
      `      - ${actionsRunnerHost}/workspaces:${actionsRunnerContainer}/workspaces`,
    ];
  }
  return workspaceVolumeLines(workHostPath, workContainerPath);
}

function envExpression(name, fallback = "") {
  return `\${${name}:-${fallback}}`;
}

function replicasFor(pool) {
  return pool.replicas ?? config.defaults?.defaultReplicas ?? 3;
}

const dockerPools = [];
const skippedPools = [];
const disabledPools = [];

for (const project of config.projects ?? []) {
  for (const pool of project.pools ?? []) {
    const runnerPackage = config.runnerPackages?.[pool.runnerPackage];
    if (!runnerPackage) {
      fail(
        `Pool ${project.id}/${pool.id} references missing runnerPackage ${pool.runnerPackage}`,
      );
    }

    if (!pool.enabled) {
      disabledPools.push({ project, pool, runnerPackage });
      continue;
    }

    if (pool.runtime !== "docker") {
      skippedPools.push({
        project,
        pool,
        runnerPackage,
        reason: `runtime is ${pool.runtime}`,
      });
      continue;
    }

    if (runnerPackage.os !== "linux") {
      skippedPools.push({
        project,
        pool,
        runnerPackage,
        reason:
          "Docker generation currently supports Linux runner containers; use native/service scripts for this pool",
      });
      continue;
    }

    if (!runnerPackage.sha256) {
      fail(
        `Pool ${project.id}/${pool.id} requires sha256 for ${pool.runnerPackage}`,
      );
    }

    dockerPools.push({ project, pool, runnerPackage });
  }
}

if (args.has("--scale-args")) {
  const scaleArgs = dockerPools
    .map(
      ({ project, pool }) =>
        `--scale ${serviceName(project.id, pool.id)}=${replicasFor(pool)}`,
    )
    .join(" ");
  process.stdout.write(scaleArgs);
  process.exit(0);
}

if (args.has("--list")) {
  for (const { project, pool, runnerPackage } of dockerPools) {
    console.log(
      `${serviceName(project.id, pool.id)}: ${project.owner}/${project.repo} ${runnerPackage.os}/${runnerPackage.arch} replicas=${replicasFor(pool)}`,
    );
  }
  for (const { project, pool, runnerPackage, reason } of skippedPools) {
    console.log(
      `skip ${project.id}/${pool.id}: ${runnerPackage.os}/${runnerPackage.arch} ${reason}`,
    );
  }
  for (const { project, pool, runnerPackage } of disabledPools) {
    console.log(
      `disabled ${project.id}/${pool.id}: ${runnerPackage.os}/${runnerPackage.arch} runtime=${pool.runtime} replicas=${replicasFor(pool)}`,
    );
  }
  process.exit(0);
}

if (args.has("--images")) {
  const images = new Set();
  for (const project of config.projects ?? []) {
    for (const pool of project.pools ?? []) {
      const runnerPackage = config.runnerPackages?.[pool.runnerPackage];
      if (
        !runnerPackage ||
        pool.runtime !== "docker" ||
        runnerPackage.os !== "linux"
      ) {
        continue;
      }
      images.add(
        pool.image ?? `${project.owner}/${project.repo}-runner:${pool.id}`,
      );
    }
  }
  for (const image of images) {
    console.log(image);
  }
  process.exit(0);
}

if (args.has("--workdir")) {
  const workHostPath = config.defaults?.runnerWorkHostPath ?? "";
  const actionsRunnerHost =
    config.defaults?.runnerActionsRunnerHostPath ??
    actionsRunnerHostPath(workHostPath);
  if (actionsRunnerHost) {
    console.log(actionsRunnerHost);
  }
  process.exit(0);
}

const lines = [
  `# Generated by scripts/generate-compose.mjs from ${configFile}.`,
  "# Do not edit directly.",
  "name: github-runner-manager",
  "",
  "services:",
];

function append(...items) {
  lines.push(...items);
}

if (dockerPools.length === 0) {
  append("  noop:", "    image: alpine:3.20", '    command: ["true"]');
} else {
  for (const { project, pool, runnerPackage } of dockerPools) {
    const name = serviceName(project.id, pool.id);
    const volumeName = `${name}-toolcache`;
    const labels = (pool.labels ?? []).join(",");
    const image =
      pool.image ?? `${project.owner}/${project.repo}-runner:${pool.id}`;
    const dockerfile = pool.dockerfile ?? "runner/Dockerfile";
    const baseImage =
      pool.baseImage ??
      runnerPackage.baseImage ??
      config.defaults?.baseImage ??
      "node:lts-bullseye";
    const workHostPath =
      pool.runnerWorkHostPath ?? config.defaults?.runnerWorkHostPath ?? "";
    const workContainerPath =
      pool.runnerWorkContainerPath ??
      config.defaults?.runnerWorkContainerPath ??
      `/home/runner/actions-runner/${pool.runnerWorkdir ?? config.defaults?.runnerWorkdir ?? "_work"}`;
    const actionsRunnerContainer =
      pool.runnerActionsRunnerContainerPath ??
      config.defaults?.runnerActionsRunnerContainerPath ??
      "/home/runner/actions-runner";
    const actionsRunnerHost =
      pool.runnerActionsRunnerHostPath ??
      config.defaults?.runnerActionsRunnerHostPath ??
      actionsRunnerHostPath(workHostPath);
    const toolcacheContainerPath =
      pool.runnerToolcacheContainerPath ??
      config.defaults?.runnerToolcacheContainerPath ??
      "/opt/hostedtoolcache";
    const toolcacheHost = toolcacheHostPath(
      workHostPath,
      pool.runnerToolcacheHostPath ?? config.defaults?.runnerToolcacheHostPath,
    );
    const pnpmStoreContainerPath =
      pool.runnerPnpmStoreContainerPath ??
      config.defaults?.runnerPnpmStoreContainerPath ??
      "/home/runner/.local/share/pnpm/store";
    const pnpmStoreHost = pnpmStoreHostPath(
      workHostPath,
      pool.runnerPnpmStoreHostPath ?? config.defaults?.runnerPnpmStoreHostPath,
    );
    const useHostToolcache = Boolean(toolcacheHost);
    const dockerPathRewrite =
      (actionsRunnerHost && actionsRunnerHost !== actionsRunnerContainer) ||
      useHostToolcache;

    append(
      `  ${name}:`,
      `    image: ${quote(image)}`,
      `    platform: ${quote(runnerPackage.dockerPlatform ?? "linux/amd64")}`,
      "    build:",
      "      context: .",
      `      dockerfile: ${quote(dockerfile)}`,
      "      args:",
      `        BASE_IMAGE: ${quote(baseImage)}`,
      `        RUNNER_VERSION: ${quote(runnerPackage.version)}`,
      `        RUNNER_SHA256: ${quote(runnerPackage.sha256)}`,
      "    restart: unless-stopped",
      "    init: true",
      "    environment:",
      `      GITHUB_OWNER: ${quote(project.owner)}`,
      `      GITHUB_REPO: ${quote(project.repo)}`,
      `      GITHUB_TOKEN: ${quote(envExpression("GITHUB_TOKEN"))}`,
      `      GITHUB_RUNNER_REGISTRATION_TOKEN: ${quote(envExpression("GITHUB_RUNNER_REGISTRATION_TOKEN"))}`,
      `      GITHUB_SERVER_URL: ${quote(config.defaults?.githubServerUrl ?? "https://github.com")}`,
      `      GITHUB_API_URL: ${quote(config.defaults?.githubApiUrl ?? "https://api.github.com")}`,
      `      RUNNER_NAME_PREFIX: ${quote(pool.namePrefix ?? name)}`,
      `      RUNNER_GROUP: ${quote(pool.runnerGroup ?? config.defaults?.runnerGroup ?? "Default")}`,
      `      RUNNER_LABELS: ${quote(labels)}`,
      `      RUNNER_WORKDIR: ${quote(pool.runnerWorkdir ?? config.defaults?.runnerWorkdir ?? "_work")}`,
      `      RUNNER_EPHEMERAL: ${quote(pool.ephemeral ?? config.defaults?.ephemeral ?? true)}`,
      `      RUNNER_REPLACE_EXISTING: ${quote(pool.replaceExisting ?? config.defaults?.replaceExisting ?? true)}`,
      `      RUNNER_DISABLE_UPDATE: ${quote(pool.disableUpdate ?? config.defaults?.disableUpdate ?? false)}`,
      `      DOCKER_GID: ${quote(envExpression("DOCKER_GID"))}`,
      ...(dockerPathRewrite
        ? [
            `      RUNNER_DOCKER_HOST_PATH_PREFIX: ${quote(actionsRunnerHost)}`,
            `      RUNNER_DOCKER_CONTAINER_PATH_PREFIX: ${quote(actionsRunnerContainer)}`,
            ...(useHostToolcache
              ? [
                  `      RUNNER_DOCKER_HOST_TOOLCACHE_PATH: ${quote(toolcacheHost)}`,
                ]
              : []),
          ]
        : []),
      "    volumes:",
      "      - /var/run/docker.sock:/var/run/docker.sock",
      ...runnerWorkVolumeLines(
        dockerPathRewrite,
        workHostPath,
        workContainerPath,
        actionsRunnerHost,
        actionsRunnerContainer,
      ),
      ...externalsVolumeLines(actionsRunnerHost, actionsRunnerContainer),
      ...pnpmStoreVolumeLines(pnpmStoreHost, pnpmStoreContainerPath),
      ...(useHostToolcache
        ? [`      - ${toolcacheHost}:${toolcacheContainerPath}`]
        : [`      - ${volumeName}:${toolcacheContainerPath}`]),
      "    stop_grace_period: 120s",
      "    healthcheck:",
      '      test: ["CMD-SHELL", "test -f /home/runner/actions-runner/.runner"]',
      "      interval: 30s",
      "      timeout: 5s",
      "      retries: 3",
      "      start_period: 30s",
      "    logging:",
      "      driver: json-file",
      "      options:",
      '        max-size: "10m"',
      '        max-file: "5"',
    );
  }
}

const namedVolumeLines = [];
if (dockerPools.length === 0) {
  namedVolumeLines.push("  noop:");
} else {
  for (const { project, pool } of dockerPools) {
    const workHostPath =
      pool.runnerWorkHostPath ?? config.defaults?.runnerWorkHostPath ?? "";
    const toolcacheHost = toolcacheHostPath(
      workHostPath,
      pool.runnerToolcacheHostPath ?? config.defaults?.runnerToolcacheHostPath,
    );
    if (!toolcacheHost) {
      namedVolumeLines.push(`  ${serviceName(project.id, pool.id)}-toolcache:`);
    }
  }
}

if (namedVolumeLines.length > 0) {
  append("", "volumes:", ...namedVolumeLines);
}
append("");

writeFileSync(outputPath, `${lines.join("\n")}\n`);

for (const { project, pool, runnerPackage, reason } of skippedPools) {
  console.error(
    `[generate-compose] skipped ${project.id}/${pool.id} (${runnerPackage.os}/${runnerPackage.arch}): ${reason}`,
  );
}

console.log(`[generate-compose] wrote ${outputPath}`);
