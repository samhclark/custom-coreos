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
BUTANE_IMAGE ?= quay.io/coreos/butane:release

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
all: deps check test build ## Run deps, check, test, and build (default)

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
	@ZFS_VERSION=$$(./scripts/resolve-zfs-version.sh $(ZFS_STREAM)); \
	KERNEL_VERSION=$$(./scripts/query-coreos-kernel.sh); \
	IMAGE="ghcr.io/samhclark/fedora-zfs-kmods:zfs-$${ZFS_VERSION}_kernel-$${KERNEL_VERSION}"; \
	printf "ZFS Version:    %s\n" "$$ZFS_VERSION"; \
	printf "Kernel Version: %s\n" "$$KERNEL_VERSION"; \
	echo ""; \
	printf "$(COLOR_BLUE)Checking: %s$(COLOR_RESET)\n" "$$IMAGE"; \
	if $(SKOPEO) inspect "docker://$$IMAGE" >/dev/null 2>&1; then \
		printf "$(COLOR_GREEN)ZFS kmods available$(COLOR_RESET)\n"; \
	else \
		printf "$(COLOR_RED)ZFS kmods not available$(COLOR_RESET)\n"; \
		exit 1; \
	fi

##@ Development

.PHONY: check
check: check-zfs-available ## Run all pre-build checks

.PHONY: check-zfs-available
check-zfs-available: ## Verify prebuilt ZFS kmods exist for the current versions
	@ZFS_VERSION=$$(./scripts/resolve-zfs-version.sh $(ZFS_STREAM)); \
	KERNEL_VERSION=$$(./scripts/query-coreos-kernel.sh); \
	IMAGE="ghcr.io/samhclark/fedora-zfs-kmods:zfs-$${ZFS_VERSION}_kernel-$${KERNEL_VERSION}"; \
	printf "$(COLOR_BLUE)Checking availability: %s$(COLOR_RESET)\n" "$$IMAGE"; \
	if $(SKOPEO) inspect "docker://$$IMAGE" >/dev/null 2>&1; then \
		printf "$(COLOR_GREEN)ZFS kmods available for ZFS %s + kernel %s$(COLOR_RESET)\n" "$$ZFS_VERSION" "$$KERNEL_VERSION"; \
	else \
		printf "$(COLOR_RED)No prebuilt ZFS kmods found for this combination$(COLOR_RESET)\n"; \
		printf "  ZFS:    %s\n" "$$ZFS_VERSION"; \
		printf "  Kernel: %s\n" "$$KERNEL_VERSION"; \
		printf "  Image:  %s\n" "$$IMAGE"; \
		exit 1; \
	fi

.PHONY: test
test: ## Run unit tests
	@python3 -m unittest discover -s tests -v

##@ Building

.PHONY: build
build: ## Build the container image
	@ZFS_VERSION=$$(./scripts/resolve-zfs-version.sh $(ZFS_STREAM)); \
	KERNEL_VERSION=$$(./scripts/query-coreos-kernel.sh); \
	IMAGE="ghcr.io/samhclark/fedora-zfs-kmods:zfs-$${ZFS_VERSION}_kernel-$${KERNEL_VERSION}"; \
	$(SKOPEO) inspect "docker://$$IMAGE" >/dev/null 2>&1 || \
		{ printf "$(COLOR_RED)ZFS kmods not available — cannot build$(COLOR_RESET)\n"; exit 1; }; \
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
		$(BUTANE_IMAGE) < butane.yaml > ignition.json
	@printf "$(COLOR_GREEN)Generated ignition.json$(COLOR_RESET)\n"

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
	@printf "$(COLOR_BLUE)Cleanup:$(COLOR_RESET)\n"
	@$(GH) run list --workflow=cleanup-images.yaml --limit=3
	@echo ""
	@printf "$(COLOR_BLUE)Pages:$(COLOR_RESET)\n"
	@$(GH) run list --workflow=pages.yaml --limit=3

RETENTION_DAYS ?= 30
.PHONY: cleanup-dry-run
cleanup-dry-run: ## Test cleanup logic locally; set RETENTION_DAYS=N to configure (default: 30)
	@./scripts/cleanup-dry-run.sh $(RETENTION_DAYS)

##@ Dependencies

.PHONY: deps
deps: deps-check-podman deps-check-gh deps-check-skopeo ## Check that required tools are available
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
