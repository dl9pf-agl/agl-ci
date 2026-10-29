#!/usr/bin/env bash
# Lint + security gate for this repo. Same script in CI and locally.
# LINT_MODE=enforce (default): any finding fails. LINT_MODE=report: print everything, exit 0 (break-glass).
# Needs: actionlint zizmor shellcheck (scripts/install-lint-tools.sh). GH_TOKEN optional (enables zizmor online audits).
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
mode="${LINT_MODE:-enforce}"; fail=0
run() { echo "::group::$*"; "$@" || { echo "FAILED: $1"; fail=1; }; echo "::endgroup::"; }
run actionlint -color
if [ -n "${GH_TOKEN:-}" ]; then run zizmor --format=github .; else run zizmor --offline --format=github .; fi
run shellcheck -x scripts/*.sh kit/*.sh ci/scripts/*.sh docker/builder/entrypoint.sh docker/runner/*.sh
run docker/runner/job-started_test.sh   # the job-started hook that keeps fork pull requests off the trusted hosts (needs python3)
run python3 ci/scripts/_matrix_test.py   # the matrix of a pull request is untrusted input: the validation must hold (needs PyYAML)
if [ "$fail" = 1 ] && [ "$mode" = report ]; then echo "::warning::LINT_MODE=report, findings ignored (break-glass). Restore enforce."; exit 0; fi
exit "$fail"
