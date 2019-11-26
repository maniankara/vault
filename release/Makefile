# Include config.mk relative to the repo root (this allows us to invoke this file
# from different directories safely).
include $(shell git rev-parse --show-toplevel)/release/config.mk

.PHONY: packages commands build package write-builder-cache-keys build-all-layers save-builder-cache load-builder-cache \
	write-package-cache-keys build-all

GOOS ?= $(shell go env GOOS 2>/dev/null || echo linux)
GOARCH ?= $(shell go env GOARCH 2>/dev/null || echo amd64)

PACKAGE_CACHE_KEY_FILES := $(shell yq -r '.packages[].meta.PACKAGE_CACHE_KEY_FILE' < $(LOCK))
PACKAGE_CACHE_KEY_FILES := $(addprefix $(REPO_ROOT)/,$(PACKAGE_CACHE_KEY_FILES))

packages:
	@# Remove layers.lock entirely to avoid buildup of old layers.
	@# Easier to do that here than in packages.mk.
	@rm -rf packages.lock
	@packagespec lock

commands:
	@$(MAKE) -f packages.mk commands

# build is a convenience target for local builds, do not use in CI.
# Instead, use `make package`.
build: $(LOCK)
	@echo "==> Building default package for GOOS=$(GOOS) GOARCH=$(GOARCH)"
	@COMMAND=$$(yq -r '.packages[] | \
		select(.inputs.GOOS=="$(GOOS)" and .inputs.GOARCH=="$(GOARCH)") | \
		.meta.LOCAL_BUILD_COMMAND' < $(LOCK) | head -n1); \
		echo "$$COMMAND"; \
		$(SHELL) "$$COMMAND"

# MK is shorthand for changing to repo root and selecting a make target
# from a file in this directory.
MK := $(MAKE) -C $(REPO_ROOT) -f $(RELEASE_DIR)/

package:
	@$(MK)build.mk package

write-builder-cache-keys:
	@echo "==> Writing build layer cache keys"
	@$(MK)layer.mk write-cache-keys

build-all-layers:
	@echo "==> Building all builder layers"
	@$(MK)layer.mk build-all-layers

save-builder-cache:
	@echo "==> Exporting Docker build cache"
	@$(MK)layer.mk save-builder-cache

load-builder-cache:
	@echo "==> Loading Docker build cache"
	@$(MK)layer.mk load-builder-cache

write-package-cache-keys: $(PACKAGE_CACHE_KEY_FILES)
	@echo "==> Package cache keys written:"
	@echo $(PACKAGE_CACHE_KEY_FILES)

build-all: commands
	cd $(REPO_ROOT) && $(SHELL) "$$(cat release/.tmp/all-commands.sh)"

.PHONY: $(PACKAGE_CACHE_KEY_FILES)
$(PACKAGE_CACHE_KEY_FILES):
	mkdir -p $(dir $@)
	echo $(PACKAGE_SOURCE_ID) > $@

