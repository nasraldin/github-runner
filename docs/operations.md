# Operations Runbook

## 1. Prepare The Host

Install Docker Engine and the Docker Compose v2 plugin on each Linux Docker runner host.

Recommended baseline:

- 4 CPU and 8 GB RAM per heavy runner.
- 40 GB or more free disk for Docker images, caches, and workspaces.
- Outbound HTTPS to `github.com` and `api.github.com`.

Check Docker socket permissions:

```bash
stat -c '%g %n' /var/run/docker.sock
```

If needed, put that group ID in `.env` as `DOCKER_GID`.

## 2. Configure Projects

Add repositories and pools in `runners.config.json`.

Create it from the public example if needed:

```bash
make config-init
```

Use at least three replicas for heavy monorepos:

```json
{
  "id": "linux-x64-docker",
  "enabled": true,
  "runtime": "docker",
  "replicas": 3
}
```

## 3. Configure GitHub Token

Create a token owned by a GitHub account with admin access to each configured repository.

Use one of:

- Classic PAT with `repo` scope.
- Fine-grained PAT with repository access and `Administration` write permission.

Set it only in `.env` as `GITHUB_TOKEN`.

Never commit `.env`.

One-hour tokens from GitHub's "Add new self-hosted runner" page are only for short manual tests:

Set short manual test tokens only in `GITHUB_RUNNER_REGISTRATION_TOKEN`.

For production, leave `GITHUB_RUNNER_REGISTRATION_TOKEN` empty and use `GITHUB_TOKEN` so containers can fetch fresh registration and removal tokens.

## 4. Validate Before Starting

```bash
make env
make config-init
make list-pools
make validate
```

If `.env` has a real `GITHUB_TOKEN`, also run:

```bash
make doctor
```

## 5. Start Runners

Recommended config-driven mode:

```bash
make apply
make ps-generated
make logs-generated
```

Single-pool compatibility mode:

```bash
make build
make up SINGLE_POOL_REPLICAS=1
make logs
```

Confirm runners appear in the GitHub repository runner settings page for each configured repository.

## 6. Scale Running Runners

Runner counts live in `runners.config.json`. Do not scale production pools from `.env`.

For example, to increase an already-running pool from 3 to 5 runners, edit the target pool:

```json
"replicas": 5
```

Apply the config again:

```bash
make apply
```

Check containers:

```bash
make ps-generated
```

Check GitHub:

```bash
gh api repos/<owner>/<repo>/actions/runners \
  --jq '.runners[] | [.name, .status, .busy] | @tsv'
```

One runner container equals one concurrent GitHub Actions job.

## 7. Stop Runners

Generated config mode:

```bash
make stop
```

Single-pool mode:

```bash
make down
```

The entrypoint requests a remove token and deregisters the runner during shutdown when `GITHUB_TOKEN` is available. If a server is killed abruptly, remove stale offline runners from GitHub settings.

## 8. Rotate Token

1. Create a new GitHub token.
2. Update `.env`.
3. Restart the runner pools:

```bash
make restart-generated
```

## 9. Upgrade Runner Packages

Update the matching entry in `runnerPackages`:

- `version`
- `archive`
- `url`
- `sha256`

Then rebuild and apply:

```bash
make apply
```

## 10. Systemd

On Linux Docker hosts, install and manage the service through Make:

```bash
make systemd-install
make systemd-enable
make systemd-start
```

Inspect the service:

```bash
make systemd-status
make systemd-logs
```

The unit runs `make apply` on start and `make down-generated` on stop from `/opt/github-runner-manager`.

## 11. Troubleshooting

Runner does not appear in GitHub:

- Run `make list-pools`.
- Confirm the pool is `enabled: true`.
- Confirm the token has repository admin access.
- Check logs with `make logs-generated`.

Docker commands fail inside jobs:

- Confirm `/var/run/docker.sock` is mounted.
- Confirm the host Docker daemon is running.
- Set `DOCKER_GID` to `stat -c '%g' /var/run/docker.sock` and restart.

Jobs do not pick this runner:

- Ensure workflow `runs-on` includes labels from the selected pool:

```yaml
runs-on: [self-hosted, linux, x64, docker, project-id]
```

Runner exits after a job:

- This is expected when `RUNNER_EPHEMERAL=true`.
- Compose restarts the container and it registers a fresh runner.
