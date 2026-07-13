# sbx-cursor — Makefile
#
#   make install   install to $(PREFIX) (default ~/.local) and run sbx-doctor
#   make check     shellcheck all scripts + run the stubbed smoke test
#   make demo      run the scripted demo against the stub CLIs (no real sbx)
#   make uninstall remove installed files

SHELL := /usr/bin/env bash
PREFIX ?= $(HOME)/.local

BIN     := $(wildcard bin/*)
LIBS    := $(wildcard lib/*.sh)
STUBS   := test/stubs/sbx test/stubs/cursor test/stubs/ssh
SCRIPTS := $(BIN) $(LIBS) $(STUBS) test/smoke.sh install.sh

.DEFAULT_GOAL := help

.PHONY: help
help: ## Show this help
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
	  | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

.PHONY: install
install: ## Install commands + libs to $(PREFIX), then run sbx-doctor
	@PREFIX=$(PREFIX) ./install.sh

.PHONY: update
update: ## Upgrade an existing install in place (reports old -> new version)
	@PREFIX=$(PREFIX) ./install.sh --update

.PHONY: uninstall
uninstall: ## Remove installed commands + libs
	@PREFIX=$(PREFIX) ./install.sh --uninstall

.PHONY: version
version: ## Print the toolkit version of this source tree
	@cat VERSION

.PHONY: shellcheck
shellcheck: ## Static-analyze every script (shellcheck)
	@command -v shellcheck >/dev/null || { echo "shellcheck not installed"; exit 1; }
	@shellcheck -x $(SCRIPTS)
	@echo "shellcheck: clean"

.PHONY: smoke
smoke: ## Run the stubbed smoke test (no real sbx needed)
	@./test/smoke.sh

.PHONY: check
check: shellcheck smoke ## shellcheck + smoke test
	@echo "check: all good"

.PHONY: demo
demo: ## Run the scripted terminal demo against the stub CLIs
	@./test/demo-run.sh
