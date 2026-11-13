#!/usr/bin/env bash
# Reproducible builds in the pinned Docker image (tool/docker/Dockerfile).
#
#   ./build.sh check     analyze + test (default)
#   ./build.sh analyze
#   ./build.sh test
#   ./build.sh apk       Android APKs -> dist/
#   ./build.sh shell     shell inside the build container
#   ./build.sh image     only build the image, print its tag
#   ./build.sh tag       print the image tag without building
#
# Windows .exe builds can't run in Linux containers: use build.ps1 windows.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cmd="${1:-check}"
versions="$root/tool/versions.env"
dockerfile="$root/tool/docker/Dockerfile"

# Tag = hash of the Dockerfile + pinned versions (line endings ignored, so
# Windows and Linux checkouts agree). Changing either builds a new image.
hash="$(cat "$dockerfile" "$versions" | tr -d '\r' | sha256sum | cut -c1-12)"
image="jellyfin-client-build:$hash"

# CI builds the image itself (with layer caching) under this tag.
if [[ "$cmd" == tag ]]; then
  echo "$image"
  exit 0
fi

if ! docker image inspect "$image" > /dev/null 2>&1; then
  build_args=()
  while IFS='=' read -r key value; do
    [[ -z "$key" ]] && continue
    build_args+=(--build-arg "$key=${value%$'\r'}")
  done < "$versions"
  docker build "${build_args[@]}" -t "$image" -f "$dockerfile" "$root/tool/docker" >&2
fi

if [[ "$cmd" == image ]]; then
  echo "$image"
  exit 0
fi

mkdir -p "$root/dist"
run_args=(--rm)
[[ -t 0 && -t 1 ]] && run_args+=(-it)
# On Linux, write dist/ as the calling user rather than root.
[[ "$(uname -s)" == Linux ]] && run_args+=(--user "$(id -u):$(id -g)")
# CI passes these so tagged builds get the tag's version (and the MAL
# client ID).
for var in GITHUB_REF GITHUB_REF_NAME GITHUB_RUN_NUMBER BUILD_NUMBER_OFFSET MAL_CLIENT_ID; do
  run_args+=(-e "$var")
done

exec docker run "${run_args[@]}" \
  -v "$root:/repo:ro" \
  -v "$root/dist:/out" \
  -v jellyfin-client-cache:/cache \
  "$image" bash /repo/tool/docker/inside.sh "$cmd"
