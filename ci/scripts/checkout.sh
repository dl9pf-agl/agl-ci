#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# kas checkout of agl-ucb's base config only (layers + externals), no machine/feature: lets the CI matrix job
# read <layer>/ci/build-matrix.yaml. Repo under test: AGL_PIN_REPO/AGL_PIN_URL/AGL_PIN_SHA (see _kas_runtime_args.sh).
set -euo pipefail
# shellcheck source=./_kas_runtime_args.sh disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/_kas_runtime_args.sh"
kas_run checkout "kas/base.yml$(kas_ci_includes)"
