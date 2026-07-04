# syntax=docker/dockerfile:1.7

ARG BASE_IMAGE=node:lts-bullseye
FROM ${BASE_IMAGE}

ARG TARGETARCH
ARG BASE_IMAGE=node:lts-bullseye
ARG RUNNER_VERSION=2.335.1
ARG RUNNER_SHA256=4ef2f25285f0ae4477f1fe1e346db76d2f3ebf03824e2ddd1973a2819bf6c8cf

ENV DEBIAN_FRONTEND=noninteractive \
  RUNNER_HOME=/home/runner/actions-runner \
  AGENT_TOOLSDIRECTORY=/opt/hostedtoolcache \
  PNPM_HOME=/home/runner/.local/share/pnpm

ENV PATH="${PNPM_HOME}:${PATH}"

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN set -eux; \
  apt-get update; \
  apt-get install -y --no-install-recommends \
  bash \
  build-essential \
  ca-certificates \
  curl \
  git \
  git-lfs \
  gnupg \
  iproute2 \
  iputils-ping \
  jq \
  lsb-release \
  openssh-client \
  python3 \
  python3-pip \
  sudo \
  tar \
  unzip \
  xz-utils \
  zip; \
  install -m 0755 -d /etc/apt/keyrings; \
  curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg; \
  chmod a+r /etc/apt/keyrings/docker.gpg; \
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" > /etc/apt/sources.list.d/docker.list; \
  apt-get update; \
  apt-get install -y --no-install-recommends \
  docker-buildx-plugin \
  docker-ce-cli \
  docker-compose-plugin; \
  rm -rf /var/lib/apt/lists/*; \
  useradd --create-home --shell /bin/bash runner; \
  echo "runner ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/runner; \
  chmod 0440 /etc/sudoers.d/runner; \
  mkdir -p "${RUNNER_HOME}" "${AGENT_TOOLSDIRECTORY}" /home/runner/.local/share; \
  chown -R runner:runner /home/runner "${AGENT_TOOLSDIRECTORY}"; \
  corepack enable

WORKDIR ${RUNNER_HOME}

RUN set -eux; \
  case "${TARGETARCH:-amd64}" in \
  amd64) runner_arch="x64" ;; \
  arm64) runner_arch="arm64" ;; \
  *) echo "Unsupported TARGETARCH: ${TARGETARCH}" >&2; exit 1 ;; \
  esac; \
  if [[ "${RUNNER_VERSION}" == "latest" ]]; then \
  runner_version="$(curl -fsSL https://api.github.com/repos/actions/runner/releases/latest | jq -r '.tag_name | ltrimstr("v")')"; \
  else \
  runner_version="${RUNNER_VERSION}"; \
  fi; \
  archive="actions-runner-linux-${runner_arch}-${runner_version}.tar.gz"; \
  curl -fL "https://github.com/actions/runner/releases/download/v${runner_version}/${archive}" -o "${archive}"; \
  if [[ -n "${RUNNER_SHA256}" ]]; then \
  echo "${RUNNER_SHA256}  ${archive}" | sha256sum -c -; \
  fi; \
  tar xzf "${archive}"; \
  rm "${archive}"; \
  ./bin/installdependencies.sh; \
  cp -a "${RUNNER_HOME}/externals" /opt/runner-externals-seed; \
  chown -R runner:runner "${RUNNER_HOME}"

COPY --chmod=755 runner/docker-wrapper.sh /usr/local/bin/docker
COPY --chmod=755 runner/entrypoint.sh /usr/local/bin/github-runner-entrypoint

ENTRYPOINT ["/usr/local/bin/github-runner-entrypoint"]
