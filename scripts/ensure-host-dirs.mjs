#!/usr/bin/env node
import { existsSync, mkdirSync, readFileSync } from "node:fs";
import { resolve } from "node:path";

const rootDir = resolve(new URL("..", import.meta.url).pathname);
const configFile = process.env.CONFIG_FILE || "runners.config.json";
const configPath = resolve(rootDir, configFile);

if (!existsSync(configPath)) {
  console.error(
    `[ensure-host-dirs] ERROR: Missing ${configFile}. Run make config-init first.`,
  );
  process.exit(1);
}

const config = JSON.parse(readFileSync(configPath, "utf8"));

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

const dirs = new Set();

for (const project of config.projects ?? []) {
  for (const pool of project.pools ?? []) {
    if (!pool.enabled || pool.runtime !== "docker") {
      continue;
    }

    const workHostPath =
      pool.runnerWorkHostPath ?? config.defaults?.runnerWorkHostPath ?? "";
    const actionsRunnerHost =
      pool.runnerActionsRunnerHostPath ??
      config.defaults?.runnerActionsRunnerHostPath ??
      actionsRunnerHostPath(workHostPath);
    const toolcacheHost = toolcacheHostPath(
      workHostPath,
      pool.runnerToolcacheHostPath ?? config.defaults?.runnerToolcacheHostPath,
    );
    const pnpmStoreHost = pnpmStoreHostPath(
      workHostPath,
      pool.runnerPnpmStoreHostPath ?? config.defaults?.runnerPnpmStoreHostPath,
    );

    if (workHostPath) {
      dirs.add(workHostPath);
    }
    if (actionsRunnerHost) {
      dirs.add(actionsRunnerHost);
      dirs.add(`${actionsRunnerHost}/externals`);
      dirs.add(`${actionsRunnerHost}/workspaces`);
    }
    if (toolcacheHost) {
      dirs.add(toolcacheHost);
    }
    if (pnpmStoreHost) {
      dirs.add(pnpmStoreHost);
    }
  }
}

if (dirs.size === 0) {
  console.log(
    "[ensure-host-dirs] No host paths configured; nothing to create.",
  );
  process.exit(0);
}

for (const dir of dirs) {
  mkdirSync(dir, { recursive: true });
  console.log(`[ensure-host-dirs] ${dir}`);
}
