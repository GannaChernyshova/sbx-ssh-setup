# sbx-ide — Makefile
#
#   make install   install to $(PREFIX) (default ~/.local) and run sbx-ide doctor
#   make check     lint (optional) + stubbed smoke test
#   make demo      run the scripted demo against the stub CLIs (no real sbx)
#   make uninstall graceful, auditable teardown
#
# Optional dev tools (shellcheck, shfmt) are DETECTED, not required: a missing
# tool SKIPS its step with an install hint and never blocks install/demo/smoke.
# Use `make check STRICT=1` to turn skips into failures (for CI).

SHELL := /usr/bin/env bash
PREFIX ?= $(HOME)/.local
STRICT ?= 0

BIN     := $(wildcard bin/*)
LIBS    := $(wildcard lib/*.sh)
STUBS   := test/stubs/sbx test/stubs/cursor test/stubs/code test/stubs/ssh
SCRIPTS := $(BIN) $(LIBS) $(STUBS) test/smoke.sh test/demo-run.sh install.sh

.DEFAULT_GOAL := help

.PHONY: help
help: ## Show this help
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
	  | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

.PHONY: install
install: ## Install commands + libs to $(PREFIX), then run sbx-ide doctor
	@PREFIX=$(PREFIX) ./install.sh

.PHONY: update
update: ## Upgrade an existing install in place (reports old -> new version)
	@PREFIX=$(PREFIX) ./install.sh --update

.PHONY: uninstall
uninstall: ## Remove installed commands + libs (auditable teardown)
	@PREFIX=$(PREFIX) ./install.sh --uninstall

.PHONY: version
version: ## Print the toolkit version of this source tree
	@cat VERSION

.PHONY: lint
lint: ## Static-analyze scripts (shellcheck) — SKIPPED with a hint if absent
	@if command -v shellcheck >/dev/null 2>&1; then \
	  shellcheck -x $(SCRIPTS) && echo "✅ shellcheck: clean"; \
	else \
	  echo "⚠️  shellcheck not installed — SKIPPING lint. Install: brew install shellcheck"; \
	  if [ "$(STRICT)" = "1" ]; then echo "❌ STRICT=1: a skipped step is a failure"; exit 1; fi; \
	fi

.PHONY: fmt
fmt: ## Auto-format scripts with shfmt if present (optional convenience)
	@if command -v shfmt >/dev/null 2>&1; then \
	  shfmt -w $(SCRIPTS) && echo "✅ shfmt: formatted"; \
	else \
	  echo "⚠️  shfmt not installed — SKIPPING format. Install: brew install shfmt"; \
	  if [ "$(STRICT)" = "1" ]; then echo "❌ STRICT=1: a skipped step is a failure"; exit 1; fi; \
	fi

.PHONY: smoke
smoke: ## Run the stubbed smoke test (no real sbx needed) — always runs
	@./test/smoke.sh

.PHONY: check
check: lint smoke ## lint (optional, skippable) + smoke test (always runs)
	@echo "check: all RUN steps passed$$([ "$(STRICT)" = "1" ] && echo ' (STRICT)')"

.PHONY: demo
demo: ## Run the scripted terminal demo against the stub CLIs
	@./test/demo-run.sh
