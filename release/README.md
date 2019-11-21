# release/

This directory contains a build system for producing multiple different packages
from the same source code (i.e. a single git commit).

The build system allows the definition of *packages* which are near complete
descriptions of the build environment and build command used to produce each package.
This set of packages is used to generate CI configuration as well as a set of commands
you can run locally to produce each package.

Packages include a set of *layers* which are individually cacheable stages of the
build, expressed as Dockerfile templates and source definitions, and cached as Docker
images.

## Why?

HashiCorp ship software written in Go, which must be compiled for multiple
different platforms, and with different build tags and compiler flags etc.
For some of our software there are many tens of variations that must be
built for a single commit. Managing these by hand is too onerous a task
and one that may easily result in error. The usual solution is to write
iterative programs that directly output the various binaries, however this
itself can be difficult to understand, and difficult to observe clearly.

By separating the workflows of _defining_ packages and then _building_ them
we end up with an easy to understand intermediate representation of the
each package. Not only is it easy to understand, but also to
consume for other purposes, such as generating CI pipelines, or
programattically editing to further automation efforts.

## Workflow

The workflow is to edit `packages.yml` which is the human-editable description
of all the packages and build layers, and then to run `make packages` which
translates that definition into two artifacts: `packages.lock` and `layers.lock`.

Once these are updated, you can run `make commands` to generate a set of commands
that you can run locally to produce each package.

Each command in `.tmp/all-commands.sh` builds one of tha packages by calling
`build.mk` which orchestrates composing the build layers implied by that
package command, and finally building and then outputting the package file to
your local filesystem.

The convenience command `make build` selects the first of these packages that
matches your local GOOS and GOARCH and builds that one.

## Implementation

There are two separate workflows: defining packages (implemented in packages.mk)
and building packages (build.mk). For conveninience the main Makefile exposes targets
that invoke those files on your behalf, which you should always use unless debugging
the system.

### packages.mk

packages.mk reads packages.yml and outputs two artifacts:

`packages.lock` is a YAML file containing the fully expanded definition of
each package, as well as links to generated Dockerfiles in `layers.lock`.

`layers.lock` is a directory containing Dockerfiles rendered from the definitions
in `packages.yml`.

### build.mk

build.mk assumes a set of environment variables defined in packages.lock and
a set of dockerfiles defined in layers.lock, and from them produces package
files for distribution. By reusing, or building, Docker containers in the
relevant order for that package, and then using that generated builder
image to compile the final packagees.

### layer.mk

layer.mk contains all the code for _building_ the layers defined in `layers.lock`.
