#---------------------------
#---------------------------
# VARIABLES
#---------------------------
#---------------------------

REQUIREMENTS_DOC=docs/requirements.md
REPO_ROOT:=$(abspath $(dir $(lastword $(MAKEFILE_LIST))))
MISE_TOML:=$(REPO_ROOT)/mise.toml
# Versions of the tools are defined only in the mise.toml file
MISE_TOOLS:=$(shell sed -n '/^\[tools\]/,/^\[/s/^\([a-zA-Z0-9_-]*\) *= *".*/\1/p' "$(MISE_TOML)")
# Dependencies that are not installed by mise
SYSTEM_DEPS=git curl docker
MISE:=$(shell command -v mise 2>/dev/null || echo "$(HOME)/.local/bin/mise")
MISE_EXEC=cd "$(REPO_ROOT)" && "$(MISE)" exec --

# These variables can be changed in the command line. Example: make build IMAGE_TAG=test
IMAGE_NAME?=zabbix-server-ha-label-manager
IMAGE_TAG?=local
IMAGE=$(IMAGE_NAME):$(IMAGE_TAG)
# kind cluster used by kind-test and kind-load. kind-test creates it if it doesn't exist. The Makefile of the Helm chart
# creates the "helm-zabbix" cluster with "make kind-create"
KIND_CLUSTER_NAME?=helm-zabbix-image-ha-labels-sidecar

.PHONY: requirements check-mise check-os check-deps install-deps lint build kind-test kind-delete kind-load clean help

#----------------------------------------------------------------------------------------------------------




#---------------------------
#---------------------------
# MAIN
#---------------------------
#---------------------------

# Check requirements
requirements:
	@if command -v docker >/dev/null 2>&1; then \
		echo "Found docker"; \
	else \
		echo "ERROR: please install docker. See $(REQUIREMENTS_DOC)" >&2; \
		exit 1; \
	fi

# Check if mise is available to run the tools of the mise.toml file
check-mise:
	@if [ ! -x "$(MISE)" ]; then \
		echo "ERROR: mise is not installed. Run 'make install-deps'" >&2; \
		exit 1; \
	fi

# Check if the operating system is supported
check-os: ## Check if the operating system is supported
	@os="$$(uname -s)"; arch="$$(uname -m)"; \
	case "$$os-$$arch" in \
		Darwin-arm64|Darwin-x86_64) \
			system="macOS"; supported=yes ;; \
		Linux-x86_64) \
			system="Linux"; supported=no; \
			if [ -r /etc/os-release ]; then \
				. /etc/os-release; \
				system="$$ID $$VERSION_ID"; \
				case "$$ID-$$VERSION_ID" in \
					ubuntu-22.04|ubuntu-24.04|ubuntu-26.04) supported=yes ;; \
				esac; \
			fi ;; \
		*) \
			system="$$os"; supported=no ;; \
	esac; \
	if [ "$$supported" = yes ]; then \
		echo "Supported operating system: $$system ($$arch)"; \
	else \
		echo "ERROR: unsupported operating system: $$system ($$arch)" >&2; \
		echo "Supported: Ubuntu 22.04, 24.04 and 26.04 (amd64) and macOS (arm64 and amd64)" >&2; \
		exit 1; \
	fi

# Check if all dependencies are installed and show the missing ones
check-deps: ## Check if the dependencies are installed and show the missing ones
	@missing=""; \
	for dep in $(SYSTEM_DEPS); do \
		if command -v "$$dep" >/dev/null 2>&1; then \
			echo "[ok]      $$dep"; \
		else \
			echo "[missing] $$dep"; missing="$$missing $$dep"; \
		fi; \
	done; \
	if [ -x "$(MISE)" ]; then \
		echo "[ok]      mise"; \
	else \
		echo "[missing] mise"; missing="$$missing mise"; \
	fi; \
	for tool in $(MISE_TOOLS); do \
		if [ -x "$(MISE)" ] && (cd "$(REPO_ROOT)" && MISE_TRUSTED_CONFIG_PATHS="$(REPO_ROOT)" "$(MISE)" which "$$tool" >/dev/null 2>&1); then \
			echo "[ok]      $$tool (mise.toml)"; \
		else \
			echo "[missing] $$tool (mise.toml)"; missing="$$missing $$tool"; \
		fi; \
	done; \
	if [ -n "$$missing" ]; then \
		echo "ERROR: missing dependencies:$$missing" >&2; \
		echo "Run 'make install-deps' to install mise and the tools of mise.toml. Install git, curl and docker according to $(REQUIREMENTS_DOC)" >&2; \
		exit 1; \
	fi; \
	echo "All dependencies are installed"

# Install mise and the tools defined in mise.toml
install-deps: check-os ## Install mise and the tools of mise.toml (docker is installed separately)
	@if [ ! -x "$(MISE)" ]; then \
		if ! command -v curl >/dev/null 2>&1; then \
			echo "ERROR: please install curl to install mise" >&2; \
			exit 1; \
		fi; \
		curl -fsSL https://mise.run | sh; \
		echo "Activate mise in your shell. See $(REQUIREMENTS_DOC)"; \
	fi
	@cd "$(REPO_ROOT)" && "$(MISE)" trust mise.toml && "$(MISE)" install
	@command -v docker >/dev/null 2>&1 || echo "WARNING: docker is not installed and must be installed separately. See $(REQUIREMENTS_DOC)"

# Lint the shell scripts and the Dockerfile
lint: check-mise ## Lint the shell scripts (shellcheck) and the Dockerfile (hadolint)
	@$(MISE_EXEC) shellcheck ha-label-manager.sh tests/kind-test.sh
	@$(MISE_EXEC) hadolint Dockerfile
	@echo "Lint OK"

# Build the image for the local architecture
build: requirements ## Build the image locally (IMAGE_NAME, IMAGE_TAG)
	docker build --pull -t "$(IMAGE)" "$(REPO_ROOT)"

# Run the end-to-end test in a kind cluster
kind-test: requirements check-mise ## Test the local image in the kind cluster KIND_CLUSTER_NAME, created if needed
	@$(MISE_EXEC) env IMAGE="$(IMAGE)" KIND_CLUSTER_NAME="$(KIND_CLUSTER_NAME)" "$(REPO_ROOT)/tests/kind-test.sh"

# Delete the kind cluster of the tests
kind-delete: requirements check-mise ## Delete the kind cluster KIND_CLUSTER_NAME
	@$(MISE_EXEC) kind delete cluster --name "$(KIND_CLUSTER_NAME)"

# Load the local image into a kind cluster, to test it with the Helm chart
kind-load: requirements check-mise ## Load the local image into the kind cluster KIND_CLUSTER_NAME, to test it with the Helm chart
	@$(MISE_EXEC) kind load docker-image "$(IMAGE)" --name "$(KIND_CLUSTER_NAME)"

# Remove the local image
clean: requirements ## Remove the local image (IMAGE_NAME, IMAGE_TAG)
	-docker image rm "$(IMAGE)"

# Show this help message
help: ## Show this help message
	@grep -E '^[a-zA-Z0-9_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2}'
