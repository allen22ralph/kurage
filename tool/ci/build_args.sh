#!/usr/bin/env bash
# Prints extra `flutter build` flags for CI.
# On a version tag (v1.2.3), the app version comes from the tag; otherwise
# pubspec.yaml's version is kept. The build number is the CI run number plus
# BUILD_NUMBER_OFFSET (100 unless set), so every build installs over the
# previous one, and over those made before this repository's runs began. MAL_CLIENT_ID
# (CI's repository variable) is built in when set.
set -euo pipefail

args=()
if [[ "${GITHUB_REF:-}" == refs/tags/v* ]]; then
  args+=("--build-name=${GITHUB_REF_NAME#v}")
fi
if [[ -n "${GITHUB_RUN_NUMBER:-}" ]]; then
  args+=("--build-number=$(( GITHUB_RUN_NUMBER + ${BUILD_NUMBER_OFFSET:-100} ))")
fi
if [[ -n "${MAL_CLIENT_ID:-}" ]]; then
  args+=("--dart-define=MAL_CLIENT_ID=${MAL_CLIENT_ID}")
fi
echo "${args[@]}"
