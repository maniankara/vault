# build-layers.mk contains the machinery to incrementally build the builder image
# as separate layers, so each can be cached both locally and in CI. This serves
# both to speed up builds by avoiding unnecessary repetition of work already done,
# as well as to ehnance the reliability of builds by downloading external
# dependencies only once per build.
#
# The build layers themselves can be individually exported as tarballs (by calling
# make <layer-name>-save) for later inspection, for sharing, or for implementing
# on-host caching without recourse to external docker registries.
#
# To use this file, include it in another makefile, and from there you must eval
# calls to the LAYER macro with this syntax:
#
#   $(eval $(call LAYER,<name>,<parent-name>,<source-include>,<source-exclude>))
#
# Each layer assumes the existence of a Dockerfile named <name>.Dockerfile.
# It uses the <parent-name> to set a Docker build arg called BASE_IMAGE to the
# resultant docker image ref of the named parent layer. You should use this BASE_IMAGE
# in the FROM line in your image.
#
# There must also be a base image, which has no parent, and that Dockerfile should
# use a FROM line from an explicit docker image, e.g. debian:buster.
#
# Each image is provided only the source code identified by <source-include>, minus
# any source code matched by <source-exclude>. Source code is any files which are
# present and not ignored by Git. This includes cached files, modified files and new,
# untracked files. The Dockerfile belonging to this layer is ALWAYS included in the
# source, so you don't need to manually specify that.
#
# The set of source code identified by a single image layer is used to produce its
# SOURCE_ID. The SOURCE_ID, when all the files are tracked by Git and are not modified
# equals the latest Git commit SHA that affected any of those files or directories.
# When there are any new or modified files, we take a SHA 256 sum of the latest Git
# commit affecting those files concatenated with the output of git diff and the contents
# of any untracked files, and prefix this with "dirty_". The SOURCE_ID is used as the
# cache key for that layer, as well as the Docker image tag for that layer, and in a few
# other places to track things that belong to it.
#
# Example:
#
#   # The base layer has no base layer, and only its own Dockerfile as source code.
#   $(eval $(call LAYER,base,,,)) 
#
#   # The UI deps layer depends on the base layer and includes some other source.
#   # but does not explicitly exclude anything.
#   $(eval $(call LAYER,ui-deps,base,ui/package.json,)) 
#
#   # The static and finaly layer includes all the source code, and can be used to
#   # build the final software packages. It includes all the source code (.), apart from
#   # the release/ directory. By keeping the release directory separate, we can iterate
#   # on it quickly by maintaining caches.
#   $(eval $(call LAYER,static,ui-deps,.,release/)
#
# Once the above is configured, you can refer to any of the layers' docker images that
# relate to the current state of your working tree by their name:
#
#   $(<layer-name>_IMAGE_NAME)
#
# e.g. for the "static" image above we refer to it as $(static_IMAGE_NAME). You can then
# use this image for anything you like, usually for building release packages.

# Include config.mk relative to this file (this allows us to invoke this file
# from different directories safely.
include $(dir $(lastword $(MAKEFILE_LIST)))config.mk

DOCKERFILES_DIR := $(LOCKDIR)/layers

### END BUILDER IMAGE LAYERS

## LAYER

# The LAYER macro defines all the targets for each image defined above.
#
# The phony targets are the ones we typically run ourselves or in CI, they are:
#
#   <name>-debug     : dump debug info for this image layer
#   <name>-image     : build the image for this image layer
#   <name>-save      : save the docker image for this layer as a tar.gz
#   <name>-load      : load this image from the saved tar.gz

define LAYER
LAYERS += $(1)
$(1)_NAME           = $(1)
$(1)_BASE           = $(2)
$(1)_SOURCE_INCLUDE = $(3)
$(1)_SOURCE_EXCLUDE = $(4) $(ALWAYS_EXCLUDE_SOURCE)
$(1)_CACHE_KEY_FILE = $(REPO_ROOT)/$(5)
$(1)_IMAGE_ARCHIVE  = $(REPO_ROOT)/$(6)

$(1)_CURRENT_LINK                                     = $(CACHE_ROOT)/layers/$$($(1)_NAME)/current
$(1)_IMAGE_LINK                                       = $(CACHE_ROOT)/layers/$$($(1)_NAME)/current/image.marker
$(1)_CACHE                                            = $(CACHE_ROOT)/layers/$$($(1)_NAME)/$$($(1)_SOURCE_ID)
$(1)_BASE_IMAGE = $$(shell [ -z $$($(1)_BASE) ] || echo $(CACHE_ROOT)/layers/$$($(1)_BASE)/current/image.marker)

LAYER_CACHES += $$($(1)_CACHE)

$(1)_SOURCE_LIST = $$($(1)_CACHE)/source.list
$(1)_DOCKERFILE = $(DOCKERFILES_DIR)/$$($(1)_NAME).Dockerfile
$(1)_IMAGE_NAME = vault-builder-$$($(1)_NAME):$$($(1)_SOURCE_ID)

# If no source is included, set source ID to none.
# Note that we include the checksum of the generated Dockerfile as part of cache IDs
# so we still invalidate the cache appropriately.
ifeq ($$($(1)_SOURCE_INCLUDE),)

$(1)_SOURCE_ID = none

else

$(1)_SOURCE_GIT = $$($(1)_SOURCE_INCLUDE) $$(call QUOTE_LIST,$$(addprefix $(GIT_EXCLUDE_PREFIX),$$($(1)_SOURCE_EXCLUDE)))
$(1)_SOURCE_COMMIT       = $$(shell git rev-list -n1 $(GIT_REF) -- $$($(1)_SOURCE_GIT))

# If we allow dirty builds, generate the source ID as a function of the
# source in in the current work tree. Where the source all happens to match a Git commit,
# that commit's SHA will be the source ID.
ifeq ($(ALLOW_DIRTY),YES)

$(1)_SOURCE_CMD = { \
					  git ls-files -- $$($(1)_SOURCE_GIT); \
			 		  git ls-files -m --exclude-standard -- $$($(1)_SOURCE_GIT); \
			 	  } | sort | uniq
$(1)_SOURCE_MODIFIED     = $$(shell if git diff -s --exit-code -- $$($(1)_SOURCE_GIT); then echo NO; else echo YES; fi)
$(1)_SOURCE_MODIFIED_SUM = $$(shell git diff -- $$($(1)_SOURCE_GIT) | $(SUM))
$(1)_SOURCE_NEW          = $$(shell git ls-files -o --exclude-standard -- $$($(1)_SOURCE_GIT))
$(1)_SOURCE_NEW_SUM      = $$(shell git ls-files -o --exclude-standard -- $$($(1)_SOURCE_GIT) | $(SUM))
$(1)_SOURCE_DIRTY        = $$(shell if [ $$($(1)_SOURCE_MODIFIED) == NO ] && [ -z "$$($(1)_SOURCE_NEW)" ]; then echo NO; else echo YES; fi)

$(1)_SOURCE_ID           = $$(shell if [ $$($(1)_SOURCE_MODIFIED) == NO ] && [ -z "$$($(1)_SOURCE_NEW)" ]; then \
								   echo $$($(1)_SOURCE_COMMIT); \
				      		   else \
								   echo -n dirty_; echo $$($(1)_SOURCE_MODIFIED_SUM) $$($(1)_SOURCE_NEW_SUM) | $(SUM); \
							   fi)

# No dirty builds allowed, so the SOURCE_ID is the git commit SHA,
# and we list files using git ls-tree.
else

$(1)_SOURCE_ID  = $$($(1)_SOURCE_COMMIT)
$(1)_SOURCE_CMD = git ls-tree -r --name-only $(GIT_REF) -- $$($(1)_SOURCE_GIT)

endif
endif

# Ensure cache dir exists.
_ := $$(shell mkdir -p $$($(1)_CACHE)) 

$(1)_PHONY_TARGET_NAMES := debug id image save load

$(1)_PHONY_TARGETS := $$(addprefix $$($(1)_NAME)-,$$($(1)_PHONY_TARGET_NAMES))

.PHONY: $$($(1)_PHONY_TARGETS)

# File targets.
$(1)_IMAGE             := $$($(1)_CACHE)/image.marker
$(1)_LAYER_REFS        := $$($(1)_CACHE)/image.layer_refs
$(1)_IMAGE_TIMESTAMP   := $$($(1)_CACHE)/image.created_time
$(1)_SOURCE_ARCHIVE    := $$($(1)_CACHE)/source.tar.gz

$(1)_TARGETS = $$($(1)_PHONY_TARGETS)

# UPDATE_MARKER_FILE ensures the image marker file has the same timestamp as the
# docker image creation date it represents. This enables make to only rebuild it when
# it has really changed, especially after loading the image from an archive.
# It also writes a list of all the layers in this docker image's history, for use
# when saving layers out to archives for use in pre-populating Docker build caches.
define $(1)_UPDATE_MARKER_FILE
	export MARKER=$$($(1)_IMAGE); \
	export LAYER_REFS=$$($(1)_LAYER_REFS); \
	export IMAGE=$$($(1)_IMAGE_NAME); \
	export IMAGE_CREATED; \
	if ! IMAGE_CREATED=$$$$(docker inspect -f '{{.Created}}' $$$$IMAGE 2>/dev/null); then \
		if [ -f $$$$MARKER ]; then \
			echo "==> Removing stale marker file for $$$$IMAGE"; \
			rm -f $$$$MARKER; \
		fi; \
		exit 0; \
	fi; \
	if [ ! -f $$$$MARKER ]; then \
		echo "==> Writing marker file for $$$$IMAGE (created $$$$IMAGE_CREATED)"; \
	fi; \
	echo $$$$IMAGE > $$$$MARKER; \
	$(TOUCH) -m -d $$$$IMAGE_CREATED $$$$MARKER; \
	echo "$$$$IMAGE" > $$$$LAYER_REFS; \
	docker history --no-trunc -q $$$$IMAGE | grep -Fv '<missing>' >> $$$$LAYER_REFS; 
endef

## PHONY targets
$(1)-debug:
	@echo "==> Debug info: $$($(1)_NAME) depends on $$($(1)_BASE)"
	@echo "$(1)_TARGETS               = $$($(1)_TARGETS)"
	@echo "$(1)_SOURCE_CMD            = $$($(1)_SOURCE_CMD)"
	@echo "$(1)_SOURCE_LIST           = $$($(1)_SOURCE_LIST)"
	@echo "$(1)_CACHE                 = $$($(1)_CACHE)"
	@echo "$(1)_DOCKERFILE            = $$($(1)_DOCKERFILE)"
	@echo "$(1)_SOURCE_COMMIT         = $$($(1)_SOURCE_COMMIT)"
	@echo "$(1)_SOURCE_ID             = $$($(1)_SOURCE_ID)"
	@echo "$(1)_SOURCE_MODIFIED       = $$($(1)_SOURCE_MODIFIED)"
	@echo "$(1)_SOURCE_DIRTY          = $$($(1)_SOURCE_DIRTY)"
	@echo "$(1)_SOURCE_NEW            = $$($(1)_SOURCE_NEW)"
	@echo "$(1)_IMAGE_LINK            = $$($(1)_IMAGE_LINK)"
	@echo "$(1)_IMAGE                 = $$($(1)_IMAGE)"
	@echo "$(1)_IMAGE_TIMESTAMP       = $$($(1)_IMAGE_TIMESTAMP)"
	@echo "$(1)_IMAGE_ARCHIVE         = $$($(1)_IMAGE_ARCHIVE)"
	@echo "$(1)_BASE_IMAGE            = $$($(1)_BASE_IMAGE)"
	@cat $$($(1)_SOURCE_LIST) | wc -l
	@echo

$(1)-id:
	@echo $(1)-$$($(1)_SOURCE_ID)

$(1)-write-cache-key:
	@FILE=$$($(1)_CACHE_KEY_FILE); \
		mkdir -p $$(dir $$($(1)_CACHE_KEY_FILE)); \
		echo $(1)-$$($(1)_SOURCE_ID) > $$$$FILE; \
		echo "==> Cache key for $(1) written to $$$$FILE:"; \
		cat $$$$FILE


$(1)-image: $$($(1)_IMAGE_LINK)
	@cat $$<

$(1)-layer-refs: $$($(1)_LAYER_REFS)
	@echo $$<

$(1)-save: $$($(1)_IMAGE_ARCHIVE)
	@echo $$<

$(1)-load:
	@\
		ARCHIVE=$$($(1)_IMAGE_ARCHIVE); \
		IMAGE=$$($(1)_IMAGE_NAME); \
		MARKER=$$($(1)_IMAGE); \
		rm -f $$$$MARKER; \
		echo "==> Loading $$$$IMAGE image from $$$$ARCHIVE"; \
		docker load < $$$$ARCHIVE
	@$$(call $(1)_UPDATE_MARKER_FILE)

## END PHONY targets

# Update the 'current' link to point to this container.
$$($(1)_IMAGE_LINK): | $$($(1)_IMAGE)
	@echo "==> Linking $$($(1)_NAME) cache dir as $$@"
	@ln -fns $$($(1)_SOURCE_ID) $$($(1)_CURRENT_LINK)

# Set the BASE_IMAGE build arg to reference the appropriate base image,
# unless there is no referenced base image.
$(1)_DOCKER_BUILD_ARGS=$$(shell [ -z "$$($(1)_BASE)" ] || echo --build-arg BASE_IMAGE=$$$$(cat $$($(1)_BASE_IMAGE)))

# Build the docker image.
$$($(1)_IMAGE): $$($(1)_BASE_IMAGE) $$($(1)_SOURCE_ARCHIVE)
	@echo "==> Building Docker image: $$($(1)_NAME); $$($(1)_SOURCE_ID)"
	docker build -t $$($(1)_IMAGE_NAME) $$($(1)_DOCKER_BUILD_ARGS) -f $$($(1)_DOCKERFILE) - < $$($(1)_SOURCE_ARCHIVE)
	@$$(call $(1)_UPDATE_MARKER_FILE)

# Build the source archive used as docker context for this image.
ifeq ($(ALLOW_DIRTY),YES)
# For dirty builds, generate a source list file and use that to build
# the source archive. We --ignore-failed-read so that deleted files that are not
# committed do not cause problems. This should be OK for dirty builds.
$$($(1)_SOURCE_LIST):
	@$$($(1)_SOURCE_CMD) > $$@
$$($(1)_SOURCE_ARCHIVE): $$($(1)_SOURCE_LIST)
	@echo "==> Building source archive: $$($(1)_NAME); $$($(1)_SOURCE_ID)"
	@{ echo $$($(1)_DOCKERFILE); cat $$<; } | $(TAR) --create -z --file $$@ --ignore-failed-read -T -
else
# For non-dirty builds, ask Git directly for a source archive, then append the
# dockerfile to it.
$$($(1)_SOURCE_ARCHIVE):
	@echo "==> Building source archive: $$($(1)_NAME); $$($(1)_SOURCE_ID)"
	@git archive $(GIT_REF) $$($(1)_SOURCE_GIT) > $$@.tar
	@$(TAR) -rf $$@.tar $$($(1)_DOCKERFILE)
	@gzip < $$@.tar > $$@
	@rm -f $$@.tar
endif

# Save the docker image as a tar.gz.
$$($(1)_IMAGE_ARCHIVE): | $$($(1)_IMAGE)
	@mkdir -p $$(dir $$@); \
	IMAGE=$$$$(cat $$($(1)_IMAGE)); \
		echo "==> Saving $(1) image to $$@"; \
		docker save $$$$IMAGE \
			$$$$(docker history -q --no-trunc $$$$IMAGE | grep -v missing) \
			| gzip > $$@

$$($(1)_LAYER_REFS):
	@echo "$$($(1)_IMAGE_NAME)" > $$@
	@docker history --no-trunc -q $$($(1)_IMAGE_NAME) | grep -Fv '<missing>' >> $$@

endef

### END LAYER

# Include the generated instructions to build each layer.
include $(shell find $(DOCKERFILES_DIR) -name '*.mk')

# Eagerly update the docker image marker files.
UPDATE_MARKERS_OUTPUT := $(strip $(foreach L,$(LAYERS),$(shell $(call $(L)_UPDATE_MARKER_FILE))))
ifneq ($(UPDATE_MARKERS_OUTPUT),)
$(info $(UPDATE_MARKERS_OUTPUT))
endif

# DOCKER_LAYER_LIST is used to dump the name of every docker ref in use
# by all of the current builder images. By running 'docker save' against
# this list, we end up with a tarball that can pre-populate the docker
# cache to avoid unnecessary rebuilds.
DOCKER_LAYER_LIST := $(CACHE_ROOT)/docker-layer-list
DOCKER_BUILDER_CACHE := $(CACHE_ROOT)/docker-builder-cache.tar.gz

write-cache-keys: $(addsuffix -write-cache-key,$(LAYERS))
	@echo "==> All cache keys written."

build-all-layers: $(addsuffix -image,$(LAYERS))
	@echo "==> All builder layers built."

save-builder-cache: $(DOCKER_BUILDER_CACHE)
	@ls -lh $<

load-builder-cache:
	docker load -i $(DOCKER_BUILDER_CACHE)

$(DOCKER_BUILDER_CACHE): $(addsuffix -layer-refs,$(LAYERS))
	@cat $(addsuffix /image.layer_refs,$(LAYER_CACHES)) | sort | uniq > $(DOCKER_LAYER_LIST)
	@cat $(DOCKER_LAYER_LIST) | xargs docker save | gzip > $(DOCKER_BUILDER_CACHE)

.PHONY: debug
debug: $(addsuffix -debug,$(LAYERS))

