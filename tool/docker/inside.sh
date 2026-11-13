#!/usr/bin/env bash
# Runs inside the build container. The repo is mounted read-only at /repo;
# its files (tracked + untracked, minus .gitignore'd) are copied to a clean
# /work so host build output (.dart_tool, build/, local.properties with
# Windows paths) never leaks in, and the container never writes to the repo.
# Results go to /out (the host's dist/ folder).
set -euo pipefail

cmd="${1:-check}"

find /work -mindepth 1 -delete
cd /repo
git ls-files -z --cached --others --exclude-standard \
  | tar --null --ignore-failed-read -T - -cf - 2>/dev/null \
  | tar -xf - -C /work
cd /work

flutter --version | head -n 1
flutter pub get --enforce-lockfile

case "$cmd" in
  analyze) flutter analyze ;;
  test) flutter test ;;
  check)
    flutter analyze
    flutter test
    ;;
  apk)
    # shellcheck disable=SC2046 # build_args.sh prints separate flags
    flutter build apk --release --split-per-abi $(bash tool/ci/build_args.sh)
    for f in build/app/outputs/flutter-apk/app-*-release.apk; do
      name="$(basename "$f")"
      cp "$f" "/out/kurage-android-${name#app-}"
    done
    ls -1 /out/*.apk
    ;;
  shell) exec bash ;;
  *)
    echo "Unknown command: $cmd (use analyze, test, check, apk or shell)" >&2
    exit 2
    ;;
esac
