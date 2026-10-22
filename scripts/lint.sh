#!/usr/bin/env bash
# Lint + security gate for this repo. Same script in CI and locally.
# LINT_MODE=enforce (default): any finding fails. LINT_MODE=report: print everything, exit 0 (break-glass).
# Needs: actionlint zizmor shellcheck hadolint (scripts/install-lint-tools.sh). GH_TOKEN optional (enables zizmor online audits).
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
mode="${LINT_MODE:-enforce}"; fail=0
run() { echo "::group::$*"; "$@" || { echo "FAILED: $1"; fail=1; }; echo "::endgroup::"; }
run actionlint -color
if [ -n "${GH_TOKEN:-}" ]; then run zizmor --format=github .; else run zizmor --offline --format=github .; fi
run shellcheck -x scripts/*.sh docker/builder/entrypoint.sh
run hadolint docker/builder/Dockerfile docker/runner/Dockerfile
if [ "$fail" = 1 ] && [ "$mode" = report ]; then echo "::warning::LINT_MODE=report, findings ignored (break-glass). Restore enforce."; exit 0; fi
exit "$fail"
