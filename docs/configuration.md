# Configuration Guide

`runners.config.json` is the local source of truth for reusable runner setup across projects and platforms, including replica counts.

Secrets and host-specific values stay in `.env`; repository metadata, labels, platforms, runner packages, and `replicas` stay in JSON. The local config is ignored by Git. Use `runners.config.example.json` as the public template.

Create your local config:

```bash
make config-init
```

## Project Structure

```json
{
  "projects": [
    {
      "id": "project-id",
      "owner": "github-owner",
      "repo": "github-repo",
      "pools": [
        {
          "id": "linux-x64-docker",
          "enabled": true,
          "runtime": "docker",
          "runnerPackage": "linux-x64-2.335.1",
          "baseImage": "node:lts-bullseye",
          "replicas": 3,
          "namePrefix": "project-linux-x64",
          "labels": ["self-hosted", "linux", "x64", "docker", "project-id"]
        }
      ]
    }
  ]
}
```

## Add A New Project

Add another object under `projects`, then run:

```bash
make list-pools
make apply
```

The generator creates one Compose service per enabled Linux Docker pool and scales each service to its configured `replicas`.

## Runner Packages

Runner package entries define OS, architecture, GitHub runner version, archive URL, and SHA-256.

The current config includes package metadata for:

- Linux x64
- Linux ARM64
- macOS ARM64
- Windows x64
- Windows ARM64

Add or update hashes from GitHub's "Add new self-hosted runner" screen before enabling a pool.

## Linux Base Image

Linux Docker pools use the default base image from `defaults.baseImage`:

```json
{
  "defaults": {
    "baseImage": "node:lts-bullseye"
  }
}
```

Override per pool when needed:

```json
{
  "id": "linux-arm64-docker",
  "baseImage": "node:lts-bullseye"
}
```

## Platform Support Model

| Runner OS | Architecture | Runtime                        | Status                                   |
| --------- | ------------ | ------------------------------ | ---------------------------------------- |
| Linux     | x64          | Docker Compose                 | Supported                                |
| Linux     | ARM64        | Docker Compose                 | Supported when SHA is configured         |
| macOS     | ARM64/x64    | Native host process or service | Supported through native instructions    |
| Windows   | x64/ARM64    | Native host process or service | Supported through native instructions    |
| Windows   | x64/ARM64    | Windows Docker container       | Modeled in JSON for Windows Docker hosts |

Docker Compose generation in this repository currently starts enabled Linux Docker pools. macOS runners must run on macOS hosts. Windows native runners must run on Windows hosts. Windows Docker pools require a Windows Docker host and a compatible Windows runner image.

## Native Instructions

Print install commands from JSON:

```bash
make native-instructions PROJECT=project-id POOL=macos-arm64-native
make native-instructions PROJECT=project-id POOL=windows-x64-native
make native-instructions PROJECT=project-id POOL=windows-arm64-native
```

Set a fresh registration token in the target terminal with `GITHUB_RUNNER_REGISTRATION_TOKEN` before running the commands.

For Parallels Desktop Windows VMs on this Mac, run live validation from macOS:

```bash
VM_NAME="Windows 11" PROJECT_ID=project-id POOL_ID=windows-arm64-native ./scripts/test-windows-parallels.sh
VM_NAME="Windows 11" PROJECT_ID=project-id POOL_ID=windows-x64-native ./scripts/test-windows-parallels.sh
```

## Labels

Prefer specific labels in workflows:

```yaml
runs-on: [self-hosted, linux, x64, docker, project-id]
```

For macOS ARM64 jobs:

```yaml
runs-on: [self-hosted, macos, arm64, project-id]
```

For Windows x64 jobs:

```yaml
runs-on: [self-hosted, windows, x64, project-id]
```
