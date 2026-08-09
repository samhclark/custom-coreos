##########################################
#### Custom CoreOS Developer Experience ##
##########################################
##
## If you don't really know what to do, run `make help`.
##

## Image coordinates
IMAGE_NAME ?= custom-coreos
TAG        ?= stable

## ZFS stream to track (prefix of release tag, e.g. zfs-2.4)
ZFS_STREAM ?= zfs-2.4

## Tool variables (override on the command line, e.g. make build PODMAN=docker)
PODMAN       ?= podman
GH           ?= gh
SKOPEO       ?= skopeo
JQ           ?= jq
BUTANE_IMAGE ?= quay.io/coreos/butane:release@sha256:13fec166cb47a8e053dcc23256c0ca41aaa1c61cab39793832aaf8894ca78c8f
SHELLCHECK_IMAGE ?= docker.io/koalaman/shellcheck:v0.11.0@sha256:61862eba1fcf09a484ebcc6feea46f1782532571a34ed51fedf90dd25f925a8d
PYTHON       ?= python3

SHELL_SOURCES := $(shell git ls-files '*.sh' 'overlay-root/usr/local/bin/garage' ':!:docs/history/**')

## Colors
COLOR_BLUE  = \033[34m
COLOR_GREEN = \033[32m
COLOR_RED   = \033[31m
COLOR_RESET = \033[0m

###
### TASKS
###

.DEFAULT_GOAL := all

##@ Default

.PHONY: all
all: deps check test ## Run deps, check, test, and build (default)
	@$(MAKE) --no-print-directory build

##@ Utility

.PHONY: help
help: ## Display this help
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^[a-zA-Z0-9_-]+:.*?##/ { printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

##@ Information

.PHONY: zfs-version
zfs-version: ## Get the latest ZFS version (e.g. 2.4.2)
	@./scripts/resolve-zfs-version.sh $(ZFS_STREAM)

.PHONY: kernel-version
kernel-version: ## Get the current kernel version from Fedora CoreOS stable
	@./scripts/query-coreos-kernel.sh

.PHONY: versions
versions: ## Show all relevant versions and verify ZFS kmod availability
	@set -- $$(GH_BIN="$(GH)" JQ_BIN="$(JQ)" SKOPEO_BIN="$(SKOPEO)" \
		CONTAINER_CLI="$(PODMAN)" \
		./scripts/resolve-build-inputs.sh "$(ZFS_STREAM)"); \
	ZFS_VERSION="$$1"; \
	KERNEL_VERSION="$$2"; \
	IMAGE="$$3"; \
	printf "ZFS Version:    %s\n" "$$ZFS_VERSION"; \
	printf "Kernel Version: %s\n" "$$KERNEL_VERSION"; \
	printf "Kmod Image:     %s\n" "$$IMAGE"; \
	printf "$(COLOR_GREEN)ZFS kmods available$(COLOR_RESET)\n"

##@ Development

.PHONY: check
check: typecheck check-generated check-shell check-ignition ## Run static, non-mutating repository checks

.PHONY: check-generated
check-generated: ## Verify generated artifacts are current without changing them
	@$(PYTHON) generate-quadlets.py --check

.PHONY: check-shell
check-shell: ## Check all maintained shell programs
	@$(PODMAN) run --rm \
		--security-opt label=disable \
		--volume "$(PWD)":/mnt:ro --workdir /mnt \
		$(SHELLCHECK_IMAGE) --severity=warning $(SHELL_SOURCES)

.PHONY: check-ignition
check-ignition: ## Validate Butane strictly without writing ignition.json
	@$(PODMAN) run --rm --interactive \
		--security-opt label=disable \
		--volume "$(PWD)":/pwd --workdir /pwd \
		$(BUTANE_IMAGE) --strict < butane.yaml >/dev/null

.PHONY: check-zfs-available
check-zfs-available: ## Verify prebuilt ZFS kmods exist for the current versions
	@GH_BIN="$(GH)" JQ_BIN="$(JQ)" SKOPEO_BIN="$(SKOPEO)" \
		CONTAINER_CLI="$(PODMAN)" \
		./scripts/resolve-build-inputs.sh "$(ZFS_STREAM)" >/dev/null
	@printf "$(COLOR_GREEN)ZFS kmods available$(COLOR_RESET)\n"

.PHONY: test
test: ## Run unit tests
	@$(PYTHON) -m unittest discover -s tests -v

.PHONY: typecheck
typecheck: ## Run strict static Python type checks
	@$(PYTHON) -m ty check

##@ Building

.PHONY: build
build: ## Build the container image
	@set -e; \
	set -- $$(GH_BIN="$(GH)" JQ_BIN="$(JQ)" SKOPEO_BIN="$(SKOPEO)" \
		CONTAINER_CLI="$(PODMAN)" \
		./scripts/resolve-build-inputs.sh "$(ZFS_STREAM)"); \
	ZFS_VERSION="$$1"; \
	KERNEL_VERSION="$$2"; \
	printf "$(COLOR_BLUE)Building $(IMAGE_NAME):$(TAG) with ZFS=$$ZFS_VERSION kernel=$$KERNEL_VERSION$(COLOR_RESET)\n"; \
	$(PODMAN) build --rm \
		--build-arg ZFS_VERSION="$$ZFS_VERSION" \
		--build-arg KERNEL_VERSION="$$KERNEL_VERSION" \
		-t "$(IMAGE_NAME):$(TAG)" \
		.; \
	printf "$(COLOR_GREEN)build succeeded: $(IMAGE_NAME):$(TAG)$(COLOR_RESET)\n"

.PHONY: generate-ignition
generate-ignition: ## Generate ignition.json from butane.yaml
	@printf "$(COLOR_BLUE)Generating ignition.json from butane.yaml...$(COLOR_RESET)\n"
	@$(PODMAN) run --rm --interactive \
		--security-opt label=disable \
		--volume "$(PWD)":/pwd --workdir /pwd \
		$(BUTANE_IMAGE) --strict < butane.yaml > ignition.json
	@printf "$(COLOR_GREEN)Generated ignition.json$(COLOR_RESET)\n"

.PHONY: generate-quadlets
generate-quadlets: ## Generate quadlet files using the custom generator
	@printf "$(COLOR_BLUE)Generating quadlet files from config...$(COLOR_RESET)\n"
	@$(PYTHON) generate-quadlets.py
	@printf "$(COLOR_GREEN)Generated quadlet files$(COLOR_RESET)\n"

##@ GitHub Workflows

.PHONY: run-workflow
run-workflow: ## Trigger the build GitHub Actions workflow
	@$(GH) workflow run build.yaml
	@printf "$(COLOR_GREEN)Triggered build.yaml$(COLOR_RESET)\n"

.PHONY: run-pages
run-pages: ## Trigger Ignition file generation and GitHub Pages deployment
	@$(GH) workflow run pages.yaml
	@printf "$(COLOR_GREEN)Triggered pages.yaml$(COLOR_RESET)\n"

.PHONY: run-cleanup
run-cleanup: ## Trigger container image cleanup workflow (dry run by default)
	@$(GH) workflow run cleanup-images.yaml
	@printf "$(COLOR_GREEN)Triggered cleanup-images.yaml (dry run)$(COLOR_RESET)\n"

.PHONY: run-cleanup-force
run-cleanup-force: ## Trigger container image cleanup workflow (deletes images)
	@$(GH) workflow run cleanup-images.yaml -f dry_run=false
	@printf "$(COLOR_GREEN)Triggered cleanup-images.yaml (force)$(COLOR_RESET)\n"

.PHONY: workflow-status
workflow-status: ## Show recent build workflow runs
	@$(GH) run list --workflow=build.yaml --limit=5

.PHONY: all-workflows
all-workflows: ## Show recent runs for all workflows
	@printf "$(COLOR_BLUE)Build:$(COLOR_RESET)\n"
	@$(GH) run list --workflow=build.yaml --limit=3
	@echo ""
	@printf "$(COLOR_BLUE)Build Check:$(COLOR_RESET)\n"
	@$(GH) run list --workflow=build-check.yaml --limit=3
	@echo ""
	@printf "$(COLOR_BLUE)Cleanup:$(COLOR_RESET)\n"
	@$(GH) run list --workflow=cleanup-images.yaml --limit=3
	@echo ""
	@printf "$(COLOR_BLUE)Pages:$(COLOR_RESET)\n"
	@$(GH) run list --workflow=pages.yaml --limit=3

RETENTION_DAYS ?= 90
.PHONY: cleanup-dry-run
cleanup-dry-run: ## Plan cleanup locally; set RETENTION_DAYS=N to configure (default: 90)
	@./scripts/select-expired-images.sh $(RETENTION_DAYS)

##@ Dependencies

.PHONY: deps
deps: deps-check-podman deps-check-gh deps-check-skopeo deps-check-jq deps-check-python deps-check-ty ## Check that required tools are available
	@printf "$(COLOR_GREEN)All deps present!$(COLOR_RESET)\n"

.PHONY: deps-check-podman
deps-check-podman: ## Check that podman is available
	@command -v $(PODMAN) > /dev/null || \
		(printf "$(COLOR_RED)$(PODMAN) not found. Install via your system package manager.$(COLOR_RESET)\n" && false)
	@printf "$(COLOR_BLUE)podman: $$($(PODMAN) --version)$(COLOR_RESET)\n"

.PHONY: deps-check-gh
deps-check-gh: ## Check that the GitHub CLI is available
	@command -v $(GH) > /dev/null || \
		(printf "$(COLOR_RED)gh not found. See https://cli.github.com for install instructions.$(COLOR_RESET)\n" && false)
	@printf "$(COLOR_BLUE)gh: $$($(GH) --version | head -1)$(COLOR_RESET)\n"

.PHONY: deps-check-skopeo
deps-check-skopeo: ## Check that skopeo is available
	@command -v $(SKOPEO) > /dev/null || \
		(printf "$(COLOR_RED)skopeo not found. Install via your system package manager.$(COLOR_RESET)\n" && false)
	@printf "$(COLOR_BLUE)skopeo: $$($(SKOPEO) --version)$(COLOR_RESET)\n"

.PHONY: deps-check-jq
deps-check-jq: ## Check that jq is available
	@command -v $(JQ) > /dev/null || \
		(printf "$(COLOR_RED)$(JQ) not found. Install via your system package manager.$(COLOR_RESET)\n" && false)
	@printf "$(COLOR_BLUE)jq: $$($(JQ) --version)$(COLOR_RESET)\n"

.PHONY: deps-check-python
deps-check-python: ## Check that Python is available
	@command -v $(PYTHON) > /dev/null || \
		(printf "$(COLOR_RED)$(PYTHON) not found. Install Python 3.11 or newer.$(COLOR_RESET)\n" && false)
	@$(PYTHON) -c 'import sys; raise SystemExit(sys.version_info < (3, 11))' || \
		(printf "$(COLOR_RED)Python 3.11 or newer is required.$(COLOR_RESET)\n" && false)
	@printf "$(COLOR_BLUE)python: $$($(PYTHON) --version)$(COLOR_RESET)\n"

.PHONY: deps-check-ty
deps-check-ty: deps-check-python ## Check that pinned Python development tools are installed
	@$(PYTHON) -c 'import ty' 2>/dev/null || \
		(printf "$(COLOR_RED)ty not found. Run $(PYTHON) -m pip install --requirement requirements-dev.txt.$(COLOR_RESET)\n" && false)
	@printf "$(COLOR_BLUE)ty: $$($(PYTHON) -m ty --version)$(COLOR_RESET)\n"
