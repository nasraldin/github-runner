# Production Setup Guide

This guide explains how to run the GitHub Self-Hosted Runner Manager on a **Linux VM or server** for real production CI — including workflows that use GitHub Actions **job containers** (`container:`) and **service containers** (`services:`), such as Postgres, Redis, or Semgrep.

Use your Mac with Docker Desktop for local development and smoke tests. Use a Linux host for production-equivalent CI.

## Production Architecture

![Healthy Docker runner containers](prod-architecture.png)

```mermaid
flowchart TB
  subgraph gh [GitHub]
    WF[Repository workflows]
  end

  subgraph linuxVM [Linux VM or server]
    DM[Docker Engine on Linux host]
    MGR[github-runner manager<br/>make apply]
    WORK["Host path<br/>/home/runner/actions-runner/_work"]
    R1[Runner container 1]
    R2[Runner container 2]
    R3[Runner container 3]
    SVC[Service containers<br/>Postgres, Redis, job containers]
  end

  WF -->|runs-on labels| R1
  WF --> R2
  WF --> R3
  MGR --> DM
  DM --> R1
  DM --> R2
  DM --> R3
  WORK -->|bind mount| R1
  WORK -->|bind mount| R2
  WORK -->|bind mount| R3
  R1 -->|docker.sock| SVC
  R2 -->|docker.sock| SVC
  R3 -->|docker.sock| SVC
```

### How it fits together

1. **GitHub** schedules a workflow job and picks a runner by `runs-on` labels.
2. The **runner manager** (`make apply`) keeps N runner containers registered for each enabled pool.
3. Each **runner container** runs the GitHub Actions listener and mounts:
   - `/var/run/docker.sock` — so jobs can run `docker build`, service containers, and job containers
   - `/home/runner/actions-runner/_work` — the job workspace, bind-mounted from the **Linux host**
4. When a workflow uses `container:` or `services:`, Docker on the Linux host starts child containers and bind-mounts `_work`. That only works when `_work` exists on the host at the same path.

One runner container handles **one concurrent job**. Set `replicas` in `runners.config.json` for the concurrency you need.

## Dev Host vs Production Host

|                                               | Mac + Docker Desktop (dev)                    | Linux VM + Docker Engine (production) |
| --------------------------------------------- | --------------------------------------------- | ------------------------------------- |
| Runner manager                                | Same project, `make apply`                    | Same project, `make apply`            |
| Docker                                        | Docker Desktop on macOS                       | Docker Engine on Linux                |
| Plain CI jobs (no `container:` / `services:`) | Works                                         | Works                                 |
| `container:` and `services:` jobs             | Often fails with `_work` mount errors         | Works with `_work` host bind mount    |
| Linux x64 pools                               | Poor fit (QEMU issues on ARM Mac)             | Native on x64 VM                      |
| macOS / Windows native pools                  | Use `make native-instructions` on those hosts | Not applicable on Linux               |

### The `_work` mount error on Mac

If you see:

```text
Error response from daemon: mounts denied:
The path /home/runner/actions-runner/_work is not shared from the host and is not known to Docker.
```

That is expected on **Mac + Docker Desktop** when workflows use `container:` or `services:`. The path exists inside the runner container but not on the Docker Desktop host.

**Production fix:** run the manager on a **Linux VM** and bind-mount `_work` from the host (steps below). Do not rely on Docker Desktop File Sharing for this path.

## Host Requirements

Recommended baseline per heavy monorepo pool:

| Resource | Minimum                                             |
| -------- | --------------------------------------------------- |
| CPU      | 4 vCPU                                              |
| RAM      | 8 GB                                                |
| Disk     | 40 GB free (images, caches, workspaces)             |
| OS       | Ubuntu 22.04/24.04 LTS or similar Linux             |
| Network  | Outbound HTTPS to `github.com` and `api.github.com` |

Supported VM providers include Parallels Ubuntu, Hetzner, AWS EC2, GCP Compute, or any bare-metal Linux server.

## Step-by-Step Production Install

### 1. Provision the Linux VM

Create an Ubuntu (or Debian) VM. SSH in as a user with `sudo`.

Install Docker Engine and the Compose plugin using your distribution’s recommended method. Confirm:

```bash
docker version
docker compose version
```

Note the Docker socket group ID (used later if needed):

```bash
stat -c '%g %n' /var/run/docker.sock
```

### 2. Create the workspace directory on the host

GitHub Actions expects the runner work directory at:

```text
/home/runner/actions-runner/_work
```

Create it on the **Linux host** before starting runners:

```bash
sudo mkdir -p /home/runner/actions-runner/_work
sudo chown -R 1000:1000 /home/runner/actions-runner/_work
```

The `runner` user inside the container typically has UID `1000`. Adjust ownership if your image uses a different UID.

### 3. Install the runner manager

Clone this repository on the Linux host:

```bash
sudo mkdir -p /opt/github-runner-manager
sudo chown "$USER":"$USER" /opt/github-runner-manager
git clone https://github.com/nasraldin/github-runner.git /opt/github-runner-manager
cd /opt/github-runner-manager
```

Create local config and secrets:

```bash
make env
make config-init
```

Edit `runners.config.json`:

- Set `owner`, `repo`, and `id` for each project
- Enable the correct pool (`linux-x64-docker` or `linux-arm64-docker`)
- Set `replicas` (default `3` = three concurrent jobs)
- Set `labels` to match workflow `runs-on` in your repositories

Edit `.env`:

```bash
GITHUB_TOKEN=ghp_...   # PAT with repo admin access, or fine-grained with Administration write
# Optional if socket group is not 999:
# DOCKER_GID=999
```

Never commit `.env` or `runners.config.json`.

### 4. Add the production `_work` bind mount

Generate Compose and add the host workspace volume to each runner service.

Run:

```bash
make validate
```

Open `compose.generated.yaml` and ensure each runner service includes **both** volume mounts:

```yaml
volumes:
  - /var/run/docker.sock:/var/run/docker.sock
  - /home/runner/actions-runner/_work:/home/runner/actions-runner/_work
  - <pool>-toolcache:/opt/hostedtoolcache
```

The `_work` line is **required for production** when workflows use `container:` or `services:`. Without it, service containers cannot mount the job workspace.

> **Note:** `compose.generated.yaml` is regenerated by `make apply`. After changing pool config, re-apply and confirm the `_work` bind mount is still present. A future manager release may add `runnerWorkHostPath` to `runners.config.json` to generate this automatically.

### 5. Validate and start

```bash
make doctor
make list-pools
make apply
make ps-generated
```

Confirm runners appear in GitHub:

**Settings → Actions → Runners** for each configured repository.

Or with the GitHub CLI:

```bash
gh api repos/<owner>/<repo>/actions/runners \
  --jq '.runners[] | [.name, .status, .busy] | @tsv'
```

### 6. Enable systemd (recommended)

For always-on runners that survive reboots:

```bash
make systemd-install
make systemd-enable
make systemd-start
make systemd-status
```

The unit runs from `/opt/github-runner-manager` and executes `make apply` on start.

## Workflow Targeting

Use labels from your pool config in repository workflows:

```yaml
runs-on: [self-hosted, linux, x64, docker, my-project-id]
```

Example for an ARM64 Linux pool:

```yaml
runs-on: [self-hosted, linux, arm64, docker, my-project-id]
```

Workflows that use service containers (Postgres, Redis) and job containers (`container: node:24-bookworm`) require the production `_work` bind mount described above.

## Scaling

Edit `replicas` in `runners.config.json` for the target pool:

```json
"replicas": 5
```

Apply:

```bash
make apply
make ps-generated
```

Each replica is one runner container and one concurrent job slot.

## Operations Quick Reference

| Task                         | Command                  |
| ---------------------------- | ------------------------ |
| Start / update runners       | `make apply`             |
| View containers              | `make ps-generated`      |
| Follow logs                  | `make logs-generated`    |
| Stop runners                 | `make stop`              |
| Restart after token rotation | `make restart-generated` |
| Validate config              | `make validate`          |
| Check GitHub API + Docker    | `make doctor`            |

See [Operations Runbook](operations.md) for the full runbook.

## Troubleshooting

### `mounts denied` for `_work`

- **On Mac:** expected for `container:` / `services:` jobs. Use a Linux VM for those workflows, or refactor workflows to start Postgres/Redis manually without GHA `services:`.
- **On Linux:** ensure `/home/runner/actions-runner/_work` exists on the host and is bind-mounted into runner containers (step 4).

### Docker commands fail inside jobs

- Confirm `/var/run/docker.sock` is mounted in `compose.generated.yaml`.
- Confirm the host Docker daemon is running: `docker ps`.
- Set `DOCKER_GID` in `.env` to match `stat -c '%g' /var/run/docker.sock`, then `make restart-generated`.

### Jobs do not pick up runners

- Confirm workflow `runs-on` labels match the pool’s `labels` in `runners.config.json`.
- Confirm runners show **Idle** (not offline) in GitHub settings.
- Confirm the pool is `enabled: true`.

### Runner disappears after each job

Expected when `ephemeral: true` in config. Compose restarts the container and registers a fresh runner automatically.

## Security

Docker runner pools mount `/var/run/docker.sock`, which grants effective root access to the host Docker daemon. Use these runners only for **trusted private repositories** and workflows you control.

See [Security Runbook](security.md).

## Related Docs

- [Configuration Guide](configuration.md) — `runners.config.json` structure and pools
- [Operations Runbook](operations.md) — day-to-day commands and systemd
- [Production Validation Report](production-validation.md) — what was validated on which hosts
