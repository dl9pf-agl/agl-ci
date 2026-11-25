#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Finish a nightly run on the builder: rename the partial directory to its final name once every build job of the run is
# done, so the download-server pull never sees a half-written nightly. Same idea as release-finalize.sh, much smaller: no
# signing, no per-image sums, nobody downstream verifies a nightly.
#
#   nightly-finalize.sh
#
# Environment (all required):
#   NIGHTLY_STAGING   the nightly area of the cache directory, e.g. /srv/agl-cache/nightly
#   NIGHTLY_DATE      the date-time key of this run (nightly-collect.sh)
#   NIGHTLY_RUN_ID    id of this run: the partial directory must carry the same id (written by nightly-collect.sh)
#
# Flow:
#   1. check the environment and the state of the directory (partial exists and is ours; the final name does not exist yet)
#   2. rename .{date}.partial to {date}   (atomic; from now on the download-server pull offers it)
set -euo pipefail

die() { echo "nightly-finalize: $*" >&2; exit 1; }

staging="${NIGHTLY_STAGING:?NIGHTLY_STAGING is not set}"
date="${NIGHTLY_DATE:?NIGHTLY_DATE is not set}"
run_id="${NIGHTLY_RUN_ID:?NIGHTLY_RUN_ID is not set}"
[[ "$date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{4}$ ]] || die "bad NIGHTLY_DATE (want YYYY-MM-DD-HHMM): '$date'"
part="$staging/.$date.partial"
final="$staging/$date"
[ -d "$part" ] || die "no partial directory $part (did the collect step run? did any build job in the matrix succeed?)"
[ ! -e "$final" ] || die "nightly $date already exists in $staging (finalize already ran for it)"
[ "$(cat "$part/.run-id" 2>/dev/null || true)" = "$run_id" ] || die "$part does not carry run id $run_id"

mv "$part" "$final"
echo "nightly-finalize: $date is final: $final"
