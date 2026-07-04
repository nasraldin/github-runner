# Security Runbook

## Private Repositories Only

GitHub recommends using self-hosted runners with private repositories. Public repository pull requests can execute untrusted code on your runner host.

Use this manager only for trusted repositories and workflows.

## Docker Socket Risk

Linux Docker pools mount:

```yaml
/var/run/docker.sock:/var/run/docker.sock
```

Any workflow with access to Docker can control the host Docker daemon. Treat this as root-equivalent host access.

Recommended controls:

- Keep runner pools scoped to trusted repositories.
- Do not allow untrusted forks or arbitrary external pull requests to run on these labels.
- Protect deployment workflows with environments and required reviewers.
- Keep branch protection enabled for sensitive branches.
- Prefer ephemeral runners so each container handles one job and restarts cleanly.

## Token Handling

The long-lived token is read from `.env` by the container entrypoint. The entrypoint:

- Uses it to request a short-lived GitHub runner registration token.
- Unsets `GITHUB_TOKEN` before starting the runner listener.
- Uses the token again only in the parent process to request a remove token on shutdown.

Do not expose `.env` to workflows. Do not mount the manager directory into runner containers.

One-hour tokens from GitHub's "Add new self-hosted runner" screen should not be committed or reused for production automation. If used, put them only in `GITHUB_RUNNER_REGISTRATION_TOKEN` for a short manual test, then remove them from `.env`.

## Runner Labels

Use project-specific labels from `runners.config.json`, for example:

```text
self-hosted,linux,x64,docker,project-id
```

Use all labels in workflow `runs-on` so jobs do not accidentally land on another self-hosted runner pool.

## Secret Hygiene

- Keep `.env`, `runners.config.json`, and `compose.generated.yaml` out of Git.
- Commit `runners.config.example.json` only; use it as a public template.
- Store production secrets in GitHub Actions environments or repository secrets.
- Avoid writing secrets to job logs.
- Use short-lived cloud credentials where possible.
- Rotate the runner admin token periodically.
- Remove stale offline runners from GitHub settings.

## Host Hardening

Recommended host practices:

- Dedicated VM or machine for runners.
- Automatic OS security updates.
- Disk monitoring for Docker image growth.
- Firewall inbound access closed unless explicitly required.
- Central log collection for Docker and systemd logs.
- Regular image rebuilds to pick up patched base packages.

## When To Use Stronger Isolation

Use one VM per job, Kubernetes Actions Runner Controller, or another stronger isolation model if you need to run untrusted code, public pull requests, or workloads from multiple teams with different trust levels.
