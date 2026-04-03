#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

if [[ "${SKIP_LOCAL_CHECKS:-0}" == "1" ]]; then
  echo "Skipping local checks because SKIP_LOCAL_CHECKS=1"
  exit 0
fi

staged_files="$(git diff --cached --name-only --diff-filter=ACMR)"

if [[ -z "$staged_files" ]]; then
  exit 0
fi

needs_swift_checks=0
while IFS= read -r path; do
  [[ -z "$path" ]] && continue
  case "$path" in
    *.swift|Package.swift|build-app.sh)
      needs_swift_checks=1
      break
      ;;
  esac
done <<< "$staged_files"

if [[ "$needs_swift_checks" -eq 0 ]]; then
  echo "Skipping Swift checks for docs/config-only commit."
  exit 0
fi

echo "Running local Swift checks before commit..."
swift test
