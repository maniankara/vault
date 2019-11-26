{{$packages := (datasource "package-list" ).packages }}
{{$layers := (datasource "package-list" ).layers -}}
# Any change to $cacheVersion invalidates all build layer and package caches.
{{$cacheVersion := "buildcache-v0" -}}
# Current $cacheVersion: {{$cacheVersion}}

workflows:
  build-release:
    jobs:
      - cache-builder-images:
          filters:
            branches:
              only:
                - /build-.*/
                - /ci.*/
      {{- range $packages}}
      - {{.inputs.BUILD_JOB_NAME}}: { requires: [ cache-builder-images ] }{{end}}
      - bundle-releases:
          requires:
            {{- range $packages}}
            - {{.inputs.BUILD_JOB_NAME}}{{end}}
jobs:
  cache-builder-images:
    executor: releaser
    steps:
      - setup_remote_docker
      - checkout
      - write-cache-keys
      {{- range $layers}}{{if eq .type "static"}}
      - restore_cache:
          keys:
            {{- range .circlecicacheprefixes}}
            - {{$cacheVersion}}-{{.}}
            {{- end}}
      - run: make -f release/layer.mk {{.name}}-load || echo "No cached builder image to load."
      - run: make -f release/layer.mk {{.name}}-image
      - run: make -f release/layer.mk {{.name}}-save
      - save_cache:
          key: {{$cacheVersion}}-{{index .circlecicacheprefixes 0}}
          paths:
            - .buildcache/docker-builder-cache.tar.gz
      {{- end}}{{end}}

  bundle-releases:
    executor: releaser
    steps:
      - checkout
      - write-cache-keys
      {{- range $packages}}
      - "load-{{.inputs.BUILD_JOB_NAME}}"{{end}}
      - run: ls -lahR dist/

{{- range $packages}}
  {{.inputs.BUILD_JOB_NAME}}:
    executor: releaser
    environment:
      - PACKAGE_SPEC_ID: {{.packagespecid}}
      {{- range $NAME, $VALUE := .inputs -}}
        {{- $type := (printf "%T" $VALUE)  -}}
        {{- if or (eq $type "string") (eq $type "int") }}
      - {{$NAME}}: '{{conv.ToString $VALUE}}'
        {{- end}}
      {{- end}}
    steps:
      - setup_remote_docker
      - checkout
      - write-cache-keys
      - restore_cache:
          keys:
          {{- range .meta.CIRCLECI_CACHE_KEY_PREFIXES}}
          - {{$cacheVersion}}-{{.}}
          {{- end}}
      - load-builder-cache
      - run: make -C release package
      - run: ls -lahR dist/
      - store_artifacts:
          path: {{.inputs.PACKAGE_OUT_ROOT}}
          destination: {{.inputs.PACKAGE_OUT_ROOT}}
      - save_cache:
          key: '{{.meta.PACKAGE_CACHE_KEY}}'
          paths:
            - {{.inputs.PACKAGE_OUT_ROOT}}
{{end}}

