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
run shellcheck -x scripts/*.sh kit/*.sh kit/release/*.sh kit/mirror/*.sh ci/scripts/*.sh docker/builder/entrypoint.sh docker/runner/*.sh
run ci/scripts/validate_test.sh   # quiet and --verbose output of validate.sh
run kit/run-loop_test.sh   # which slot gets which label and limits (the lint slots)
run kit/deploy_test.sh   # what a plain update keeps and how the old limit names become the RUNNER limits
run kit/release/promote_test.sh   # the download server verifies and promotes a release: every fault is refused, manual mode, idempotent (SKIPs without cosign)
run ci/scripts/premirror_test.sh   # the git mirror rewrite of kas: no backslash, survives kas-container's forwarding (needs python3)
run ci/scripts/kas-checkout_test.sh   # kas_checkout: from the original URLs when the git mirror cannot serve a repository (stubs, no kas)
run kit/prune-builder_test.sh   # the builder prune: old partials and finished nightlies/releases go, young, foreign and symlinked ones stay (fake tree)
run kit/mirror/git-refresh_test.sh   # the git mirror refresh of the download server: clones updated first, one failure does not stop the others (local repos, stubs)
run kit/release/run_test.sh   # the cron entry of the download server: which script each word calls and where it logs (stubs)
run docker/runner/job-started_test.sh   # the job-started hook that keeps fork pull requests off the trusted hosts (needs python3)
run python3 ci/scripts/_matrix_test.py   # the matrix of a pull request is untrusted input: the validation must hold (needs PyYAML)
run ci/scripts/release-collect_test.sh   # which files of an image go into a release, the sums file, and what is refused (release process)
run ci/scripts/release-build_test.sh   # the commands of a release build (kas flags, docker mounts) with stubs, and that a normal build is unchanged
run python3 ci/scripts/release-check_test.py   # the kas statement of a release image against the pins file: each fault must fail (needs PyYAML)
run ci/scripts/release-attest_test.sh   # check and sign with a throw-away key; SKIPs without cosign (the runner image has none)
run ci/scripts/release-pipeline_test.sh   # collect on two hosts, attest, merge, promote in a row on one fixture; SKIPs without cosign
if [ "$fail" = 1 ] && [ "$mode" = report ]; then echo "::warning::LINT_MODE=report, findings ignored (break-glass). Restore enforce."; exit 0; fi
exit "$fail"
