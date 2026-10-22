#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Checkout kas repos for a (machine, features) combination. Runs identically in CI (via
# kas-container) and locally for developers (via `make setup`).
set -euo pipefail

# shellcheck source=./_kas_runtime_args.sh
# shellcheck source=./_kas_runtime_args.sh disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/_kas_runtime_args.sh"
cd "$TREE" || exit 1

parse_common_args "$@"

matrix_fields kasfiles
KASFILES="${_MATRIX_FIELDS[0]}$(kas_extra_includes)$(kas_ci_includes)"

run_machine_setup_hooks "$MACHINE"

echo "setup.sh: kas checkout $KASFILES"
# shellcheck disable=SC2046
kas_run checkout "$KASFILES"
