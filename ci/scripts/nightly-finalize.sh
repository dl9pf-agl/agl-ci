#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Finish a nightly run on the builder: mark it complete once every build job of the run is done. The images are public already
# (nightly-collect.sh publishes each one when it is built); <date>/COMPLETE says that none is missing. A run with a failed build
# never gets the marker.
#
#   nightly-finalize.sh
#
# Environment (all required):
#   NIGHTLY_STAGING   the nightly area of the cache directory, e.g. /srv/agl-cache/nightly
#   NIGHTLY_DATE      the date-time key of this run (nightly-collect.sh)
#   NIGHTLY_RUN_ID    id of this run: the nightly directory must carry the same id (written by nightly-collect.sh)
#
# Flow:
#   1. check the environment and the state of the directory (it exists, is ours, and is not complete yet)
#   2. remove the empty work directory (anything left in it is reported and stays; kit/prune-builder.sh removes it later)
#   3. write <date>/COMPLETE (through a .tmp name, which the download-server pull never copies)
set -euo pipefail

die() { echo "nightly-finalize: $*" >&2; exit 1; }

staging="${NIGHTLY_STAGING:?NIGHTLY_STAGING is not set}"
date="${NIGHTLY_DATE:?NIGHTLY_DATE is not set}"
run_id="${NIGHTLY_RUN_ID:?NIGHTLY_RUN_ID is not set}"
[[ "$date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{4}$ ]] || die "bad NIGHTLY_DATE (want YYYY-MM-DD-HHMM): '$date'"
part="$staging/.$date.partial"
final="$staging/$date"
[ -d "$final" ] || die "no nightly directory $final (did the collect step run? did any build job in the matrix succeed?)"
[ "$(cat "$final/.run-id" 2>/dev/null || true)" = "$run_id" ] || die "$final does not carry run id $run_id"
[ ! -e "$final/COMPLETE" ] || die "nightly $date is already complete in $staging (finalize already ran for it)"

if [ -d "$part" ]; then
  find "$part" -mindepth 1 -depth -type d -empty -delete
  if [ -z "$(find "$part" -mindepth 1 ! -name .run-id -print -quit)" ]; then
    rm -f "$part/.run-id"; rmdir "$part"
  else
    echo "nightly-finalize: left over in $part (not published)"   # .run-id stays: the prune script needs it
  fi
fi

date -u +%Y-%m-%dT%H:%M:%SZ > "$final/COMPLETE.tmp"
mv "$final/COMPLETE.tmp" "$final/COMPLETE"
echo "nightly-finalize: $date is complete: $final"
