# config.mk
#
# config.mk contains constants and derived configuration that applies to
# building both layers and final packages.

# Only include the config once. This means we can include it in the header
# of each makefile, to allow calling them individually and when they call
# each other.
ifneq ($(CONFIG_INCLUDED),YES)
CONFIG_INCLUDED := YES

# Set SHELL to strict mode, in a way compatible with both old and new GNU make.
SHELL := /usr/bin/env bash -euo pipefail -c

# RELEASE_DIR is the path to the dir containing all the
# release makefiles etc., relative from the repo root.
# Typically this is 'release'.
RELEASE_DIR := release

# CACHE_ROOT is the build cache directory.
CACHE_ROOT ?= .buildcache

# SPEC is the human-managed description of which packages we are able to build.
SPEC := packages.yml

# LOCKDIR contains the lockfile and layer files.
LOCKDIR := packages.lock

# LOCK is the generated fully-expanded rendition of SPEC, for use in generating CI
# pipelines and other things.
LOCK := $(LOCKDIR)/pkgs.yml

# PACKAGE_CACHE_KEY_FILES is the place we write package cache key files.
PACKAGE_CACHE_KEY_FILES := .tmp/cache-keys

# ALWAYS_EXCLUDE_SOURCE prevents source from these directories from taking
# part in the SOURCE_ID, or from being sent to the builder image layers.
# This is important for allowing the head of master to build other commits
# where this build system has not been vendored.
#
# Source in RELEASE_DIR is encoded as PACKAGE_SPEC_ID and included in paths
# and cache keys. Source in .circleci/ should not do much more than call
# code in the release/ directory.
ALWAYS_EXCLUDE_SOURCE     := $(RELEASE_DIR)/ .circleci/
# ALWAYS_EXCLUD_SOURCE_GIT is git path filter parlance for the above.
ALWAYS_EXCLUDE_SOURCE_GIT := ':(exclude)$(RELEASE_DIR)/' ':(exclude).circleci/'

# Even though layers may have different Git revisions, based on the latest
# revision of their source, we always want to
# honour either HEAD or the specified PRODUCT_REVISION for compiling the
# final binaries, as this revision is the one picked by a human to form
# the release.
ifeq ($(PRODUCT_REVISION),)
# If PRODUCT_REVISION is empty (the default) we are concerned with building the
# current work tree, regardless of whether it is dirty or not. For local builds
# this is more convenient and more likely expected behaviour than having to commit
# just to perform a new build.
GIT_REF := HEAD
ALLOW_DIRTY ?= YES
else
# PRODUCT_REVISION is non-emtpy so treat it as a git commit ref and pull files
# directly from git rather than the work tree.
GIT_REF := $(PRODUCT_REVISION)
ALLOW_DIRTY := NO
endif

# Determine the PACKAGE_SOURCE_ID.
ifeq ($(ALLOW_DIRTY),YES)
DIRTY := $(shell git diff --exit-code $(GIT_REF) -- $(ALWAYS_EXCLUDE_SOURCE_GIT) > /dev/null 2>&1 || echo "dirty_")
PACKAGE_SOURCE_ID := $(DIRTY)$(shell git rev-parse $(GIT_REF))
else
PACKAGE_SOURCE_ID := $(shell git rev-parse $(GIT_REF))
endif



# We rely on GNU touch and tar. On macOS, we assume they are installed as gtouch and gtar
# by homebrew.
ifeq ($(shell uname),Darwin)
TOUCH := gtouch
TAR := gtar
# List tool-name:brew package to search for installed tools.
TOOLS := gtouch:coreutils gtar:gnu-tar 
MISSING_PACKAGES := $(shell \
	for T in $(TOOLS); do \
		BIN=$$(echo $$T | cut -d':' -f1); \
		if ! command -v $$BIN > /dev/null 2>&1; then \
			echo $$T | cut -d':' -f2; \
		fi; \
	done)
ifneq ($(MISSING_PACKAGES),)
$(error You are missing required tools, please run 'brew install $(MISSING_PACKAGES)'.)
endif
else
TOUCH := touch
TAR := tar
TOOLS := touch tar
MISSING_PACKAGES := $(shell \
	for T in $(TOOLS); do \
		BIN=$$(echo $$T | cut -d':' -f1); \
		if ! command -v $$BIN > /dev/null 2>&1; then \
			echo $$T | cut -d':' -f2; \
		fi; \
	done)
ifneq ($(MISSING_PACKAGES),)
$(error You are missing required tools, please install: $(MISSING_PACKAGES).)
endif
endif

### Utilities and constants
GIT_EXCLUDE_PREFIX := :(exclude)
# SUM generates the sha1sum of its input.
SUM := sha1sum | cut -d' ' -f1
# QUOTE_LIST wraps a list of space-separated strings in quotes.
QUOTE := $(shell echo "'")
QUOTE_LIST = $(addprefix $(QUOTE),$(addsuffix $(QUOTE),$(1)))
GIT_EXCLUDE_LIST = $(call QUOTE_LIST,$(addprefix $(1)))
### End utilities and constants.





# End including config once only.
endif
