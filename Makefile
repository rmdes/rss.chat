# rss.chat deployment Makefile -- run from the repo root.
# `make help` lists everything; `make install` takes a fresh clone to a
# running instance. Thin wrapper over deploy/docker-compose.yml and
# deploy/scripts/*.sh -- it never duplicates their logic.

COMPOSE := docker compose --project-directory deploy -f deploy/docker-compose.yml
ENV_FILE := deploy/.env

.DEFAULT_GOAL := help
.PHONY: help install up down restart update build logs ps shell env backup migrate test e2e clean

help: ## List the available targets
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
		| sort \
		| awk 'BEGIN {FS = ":.*?## "} {printf "  \033[36m%-10s\033[0m %s\n", $$1, $$2}'

$(ENV_FILE):
	@bash deploy/scripts/generate-env.sh

install: $(ENV_FILE) ## First run: create .env if needed, build, start, wait until healthy
	@$(COMPOSE) build
	@$(COMPOSE) up -d --wait
	@domain=$$(grep -E '^RSSCHAT_DOMAIN=' $(ENV_FILE) | cut -d= -f2-); \
		echo ""; \
		echo "rss.chat is up. Open:  https://$$domain/"; \
		echo "Sign-in emails (until you set a real SMTP relay) are at:  https://$$domain/mail"; \
		echo "Mail-catcher login is the MAILPIT_USER / MAILPIT_PASSWORD in $(ENV_FILE)."

up: $(ENV_FILE) ## Start the stack (creates .env on first run), wait until healthy
	@$(COMPOSE) up -d --wait

down: ## Stop the stack (keeps data)
	@$(COMPOSE) down

restart: ## Restart the running services
	@$(COMPOSE) restart

build: ## Rebuild the app image
	@$(COMPOSE) build

update: ## Pull the latest code, rebuild, and restart
	@git pull
	@$(COMPOSE) build
	@$(COMPOSE) up -d --wait

logs: ## Follow logs (optionally SERVICE=rsschat)
	@$(COMPOSE) logs -f $(SERVICE)

ps: ## Show service status
	@$(COMPOSE) ps

shell: ## Open a shell in the rsschat container
	@$(COMPOSE) exec rsschat bash

env: ## Generate deploy/.env with random passwords (refuses to overwrite)
	@bash deploy/scripts/generate-env.sh

backup: ## Back up the database (the feeds live in it)
	@bash deploy/scripts/backup.sh

migrate: ## Apply a SQL migration: make migrate FILE=path/to.sql
	@if [ -z "$(FILE)" ]; then echo "usage: make migrate FILE=path/to/migration.sql" >&2; exit 1; fi
	@bash deploy/scripts/migrate.sh "$(FILE)"

test: ## Run the unit and build tests
	@node --test deploy/daves3-shim/test.js deploy/aws-sdk-shim/test.js deploy/test-make-config.js
	@bash deploy/test-vendor.sh
	@bash deploy/patches/test-patch-client.sh

e2e: ## Run the full end-to-end test against the running stack
	@bash deploy/scripts/e2e-test.sh

clean: ## DESTROY the stack AND its data (every volume)
	@printf 'This deletes the database and all feeds. Type y to confirm: '; \
		read ans; \
		if [ "$$ans" = "y" ]; then $(COMPOSE) down -v; else echo "aborted."; fi
