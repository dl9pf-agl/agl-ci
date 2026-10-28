#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Print the commit of every repo of the kas tree as a kas fragment in the format of agl-ucb's kas/pins.yml, so that a run (or a
# release) can be reproduced: meta-agl, meta-agl-demo and meta-agl-devel float on their branch, and this is their written-out pin.
# Run it after the checkout, with the same environment as checkout.sh (AGL_TREE, KAS_EXEC, AGL_PIN_*). Offline: it only asks the
# repos that are already there.
#   resolved-pins.sh > resolved-pins.yml      # use as the pins file of a release: kas/base.yml:...:resolved-pins.yml
set -euo pipefail
# shellcheck source=./_kas_runtime_args.sh disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/_kas_runtime_args.sh"
# shellcheck disable=SC2016  # the single-quoted command is meant to expand inside kas
list="$(kas_run for-all-repos "kas/base.yml:kas/pins.yml$(kas_ci_includes)" 'echo "KAS_PIN $KAS_REPO_NAME $(git rev-parse HEAD)"' 2>/dev/null \
        | sed -n 's/^KAS_PIN //p' | grep -E '^[A-Za-z0-9._-]+ [0-9a-f]{40}$' | sort -u)"
[ -n "$list" ] || { echo "resolved-pins.sh: no repo found in $TREE (run checkout.sh first)" >&2; exit 1; }
printf '# SPDX-License-Identifier: MIT\n# Written out by agl-ci ci/scripts/resolved-pins.sh: the commit every repo of the tree resolved to.\nheader:\n  version: 22\noverrides:\n  repos:\n'
while read -r name commit; do printf '    %s:\n      commit: %s\n' "$name" "$commit"; done <<<"$list"
