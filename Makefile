SHELL := /usr/bin/env bash
.DEFAULT_GOAL := help

ENV_FILE ?= .env
ENV_EXAMPLE ?= .env.example
CONFIG_FILE ?= runners.config.json
CONFIG_EXAMPLE ?= runners.config.example.json
COMPOSE_FILE ?= compose.yaml
GENERATED_FILE ?= compose.generated.yaml
SINGLE_POOL_REPLICAS ?= 3
LOG_TAIL ?= 200
SYSTEMD_UNIT ?= github-runner-manager.service
PROJECT ?=
POOL ?=
PROJECT_ID ?=
POOL_ID ?=
SERVICE ?=
VM_NAME ?= Windows 11

COMPOSE := docker compose --env-file $(ENV_FILE) -f $(COMPOSE_FILE)
GENERATED_COMPOSE := docker compose --env-file $(ENV_FILE) -f $(GENERATED_FILE)

.PHONY: help env config-init init-workdir ensure-host-dirs require-env require-config doctor validate validate-example validate-generated config config-generated list-pools generate apply start build-generated up-generated down-generated stop restart-generated logs-generated ps-generated native-instructions test-windows-parallels build up down restart logs ps pull clean destroy destroy-all systemd-install systemd-enable systemd-start systemd-stop systemd-restart systemd-status systemd-logs

help:
	@printf '%s\n' \
		'GitHub self-hosted runner manager' \
		'' \
		'Common workflow:' \
		'  make env                         Create .env from .env.example when missing' \
		'  make config-init                 Create runners.config.json from example when missing' \
		'  make init-workdir                Create _work + hostedtoolcache dirs (macOS/Linux; needs sudo)' \
		'  make validate                    Validate scripts and generated Docker Compose' \
		'  make validate-example            Validate the public example config' \
		'  make doctor                      Validate host tools and GitHub API access' \
		'  make list-pools                  List enabled, disabled, and skipped pools' \
		'  make apply                       Generate, build, and start enabled Docker pools' \
		'  make logs-generated              Follow generated runner logs' \
		'  make stop                        Stop generated Docker pools' \
		'  make destroy                     Remove containers, volumes, images, generated compose' \
		'  make destroy-all                 destroy + remove host _work workspace' \
		'' \
		'Generated multi-project stack:' \
		'  make generate                    Write $(GENERATED_FILE) from $(CONFIG_FILE)' \
		'  make config-generated            Render generated Docker Compose config' \
		'  make build-generated             Build generated Docker runner images' \
		'  make up-generated                Start generated pools with configured replicas' \
		'  make down-generated              Stop generated pools' \
		'  make restart-generated           Restart generated pools' \
		'  make ps-generated                Show generated pool containers' \
		'' \
		'Native runner helpers:' \
		'  make native-instructions PROJECT=<id> POOL=<id>' \
		'  make test-windows-parallels PROJECT_ID=<id> POOL_ID=<id> VM_NAME="Windows 11"' \
		'' \
		'Single-pool compatibility stack:' \
		'  make build                       Build compose.yaml runner image' \
		'  make up                          Start compose.yaml runner replicas (advanced)' \
		'  make down                        Stop compose.yaml runner stack' \
		'  make logs                        Follow compose.yaml runner logs' \
		'  make ps                          Show compose.yaml containers' \
		'' \
		'Systemd on Linux hosts:' \
		'  make systemd-install             Install systemd unit' \
		'  make systemd-enable              Enable manager at boot' \
		'  make systemd-start               Start manager service' \
		'  make systemd-status              Show manager service status' \
		'' \
		'Variables:' \
		'  ENV_FILE=.env CONFIG_FILE=runners.config.json LOG_TAIL=200 SINGLE_POOL_REPLICAS=3'

env:
	@if [[ -f "$(ENV_FILE)" ]]; then \
		printf '[env] %s already exists\n' "$(ENV_FILE)"; \
	else \
		cp "$(ENV_EXAMPLE)" "$(ENV_FILE)"; \
		printf '[env] created %s from %s. Edit it and set GITHUB_TOKEN before production use.\n' "$(ENV_FILE)" "$(ENV_EXAMPLE)"; \
	fi

require-env:
	@if [[ ! -f "$(ENV_FILE)" ]]; then \
		printf '[env] ERROR: missing %s. Run `make env` and set GITHUB_TOKEN.\n' "$(ENV_FILE)" >&2; \
		exit 1; \
	fi

config-init:
	@if [[ -f "$(CONFIG_FILE)" ]]; then \
		printf '[config] %s already exists\n' "$(CONFIG_FILE)"; \
	else \
		cp "$(CONFIG_EXAMPLE)" "$(CONFIG_FILE)"; \
		printf '[config] created %s from %s. Edit owner, repo, labels, and enabled pools.\n' "$(CONFIG_FILE)" "$(CONFIG_EXAMPLE)"; \
	fi

init-workdir:
	@sudo scripts/init-runner-workdir.sh

ensure-host-dirs: require-config
	@CONFIG_FILE="$(CONFIG_FILE)" node scripts/ensure-host-dirs.mjs

require-config:
	@if [[ ! -f "$(CONFIG_FILE)" ]]; then \
		printf '[config] ERROR: missing %s. Run `make config-init` or set CONFIG_FILE.\n' "$(CONFIG_FILE)" >&2; \
		exit 1; \
	fi

doctor: require-env
	@./scripts/doctor.sh

validate: require-config generate
	@node --check scripts/generate-compose.mjs
	@node --check scripts/ensure-host-dirs.mjs
	@node --check scripts/print-native-instructions.mjs
	@bash -n scripts/apply.sh scripts/doctor.sh scripts/destroy.sh runner/entrypoint.sh scripts/test-windows-parallels.sh
	@if [[ -f "$(ENV_FILE)" ]]; then \
		docker compose --env-file "$(ENV_FILE)" -f "$(GENERATED_FILE)" config --quiet; \
	else \
		docker compose --env-file "$(ENV_EXAMPLE)" -f "$(GENERATED_FILE)" config --quiet; \
	fi

validate-example:
	@CONFIG_FILE="$(CONFIG_EXAMPLE)" GENERATED_FILE="$(GENERATED_FILE)" $(MAKE) validate

validate-generated: validate

config: require-env
	@$(COMPOSE) config

config-generated: require-env require-config generate
	@$(GENERATED_COMPOSE) config

list-pools: require-config
	@CONFIG_FILE="$(CONFIG_FILE)" node scripts/generate-compose.mjs --list

generate: require-config
	@CONFIG_FILE="$(CONFIG_FILE)" GENERATED_FILE="$(GENERATED_FILE)" node scripts/generate-compose.mjs

apply: ensure-host-dirs start

start: build-generated up-generated

build-generated: require-env require-config generate
	@$(GENERATED_COMPOSE) build

up-generated: require-env require-config generate
	@scale_args="$$(CONFIG_FILE="$(CONFIG_FILE)" node scripts/generate-compose.mjs --scale-args)"; \
	$(GENERATED_COMPOSE) up -d $${scale_args}

down-generated: require-env
	@$(GENERATED_COMPOSE) down

stop: down-generated

restart-generated: down-generated start

logs-generated: require-env
	@if [[ -n "$(SERVICE)" ]]; then \
		$(GENERATED_COMPOSE) logs -f --tail="$(LOG_TAIL)" "$(SERVICE)"; \
	else \
		$(GENERATED_COMPOSE) logs -f --tail="$(LOG_TAIL)"; \
	fi

ps-generated: require-env
	@$(GENERATED_COMPOSE) ps

native-instructions: require-config
	@if [[ -z "$(PROJECT)" || -z "$(POOL)" ]]; then \
		printf 'Usage: make native-instructions PROJECT=<project-id> POOL=<pool-id>\n' >&2; \
		exit 1; \
	fi
	@CONFIG_FILE="$(CONFIG_FILE)" node scripts/print-native-instructions.mjs "$(PROJECT)" "$(POOL)"

test-windows-parallels: require-env require-config
	@if [[ -z "$(PROJECT_ID)" || -z "$(POOL_ID)" ]]; then \
		printf 'Usage: make test-windows-parallels PROJECT_ID=<project-id> POOL_ID=<pool-id> VM_NAME="Windows 11"\n' >&2; \
		exit 1; \
	fi
	@CONFIG_FILE="$(CONFIG_FILE)" VM_NAME="$(VM_NAME)" PROJECT_ID="$(PROJECT_ID)" POOL_ID="$(POOL_ID)" ./scripts/test-windows-parallels.sh

build: require-env
	@$(COMPOSE) build

up: require-env
	@$(COMPOSE) up -d --scale runner=$(SINGLE_POOL_REPLICAS)

down: require-env
	@$(COMPOSE) down

restart: down up

logs: require-env
	@$(COMPOSE) logs -f --tail="$(LOG_TAIL)" runner

ps: require-env
	@$(COMPOSE) ps

pull: require-env
	@$(COMPOSE) pull --ignore-buildable

clean: require-env
	@$(COMPOSE) down --remove-orphans
	@docker image rm "$${RUNNER_IMAGE:-github-runner-manager:local}" 2>/dev/null || true

destroy: require-env
	@chmod +x scripts/destroy.sh
	@CONFIG_FILE="$(CONFIG_FILE)" ENV_FILE="$(ENV_FILE)" GENERATED_FILE="$(GENERATED_FILE)" COMPOSE_FILE="$(COMPOSE_FILE)" ./scripts/destroy.sh

destroy-all: require-env
	@chmod +x scripts/destroy.sh
	@DESTROY_WORKDIR=1 CONFIG_FILE="$(CONFIG_FILE)" ENV_FILE="$(ENV_FILE)" GENERATED_FILE="$(GENERATED_FILE)" COMPOSE_FILE="$(COMPOSE_FILE)" ./scripts/destroy.sh

systemd-install:
	@sudo install -m 0644 systemd/github-runner-manager.service "/etc/systemd/system/$(SYSTEMD_UNIT)"
	@sudo systemctl daemon-reload
	@printf '[systemd] installed %s\n' "$(SYSTEMD_UNIT)"

systemd-enable:
	@sudo systemctl enable "$(SYSTEMD_UNIT)"

systemd-start:
	@sudo systemctl start "$(SYSTEMD_UNIT)"

systemd-stop:
	@sudo systemctl stop "$(SYSTEMD_UNIT)"

systemd-restart:
	@sudo systemctl restart "$(SYSTEMD_UNIT)"

systemd-status:
	@sudo systemctl status --no-pager "$(SYSTEMD_UNIT)"

systemd-logs:
	@sudo journalctl -u "$(SYSTEMD_UNIT)" -f
