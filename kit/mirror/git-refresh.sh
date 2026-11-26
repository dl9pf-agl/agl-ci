#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Keep the bare git mirrors of the DOWNLOAD SERVER current (agl-ci chapter 15): update the clones whose kas files say which
# repositories builds clone, list those repositories, and let git-mirrors.sh clone or update their mirrors. Run it from cron on the
# download server (kit/server.cron, every 30 minutes); it needs no privilege beyond writing MIRROR_ROOT/git.
#
#   kit/mirror/git-refresh.sh
#
#   MIRROR_ROOT   the tree the web server serves (default /srv/agl-permanent); the mirrors go to MIRROR_ROOT/git
#   UCB_CLONE     a clone of agl-ucb (default /root/agl-ucb): its kas files name the external layers
#   LAYER_CLONES  clones of the layer repositories, space separated (default /root/src-meta-agl /root/src-meta-agl-demo
#                 /root/src-meta-agl-devel): their kas/feature files name more repositories (meta-agl has the trowl feature)
#   Both are updated with `git pull --ff-only` first.
#
# Flow, in the order it runs:
#   1. update every clone; one that cannot be fast-forwarded is reported and skipped, the others go on (a lagging clone only
#      means an older repository list, not a failed refresh); the exit status is 1 at the end if any update failed
#   2. list the repositories of all kas files below the clones (kit/mirror/git-repos-from-kas.py)
#   3. clone or update their mirrors (kit/mirror/git-mirrors.sh)
set -uo pipefail
here="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
root="${MIRROR_ROOT:-/srv/agl-permanent}"
ucb="${UCB_CLONE:-/root/agl-ucb}"
layers="${LAYER_CLONES:-/root/src-meta-agl /root/src-meta-agl-demo /root/src-meta-agl-devel}"
lister="${REPOS_CMD:-$here/git-repos-from-kas.py}"
mirrorer="${MIRRORS_CMD:-$here/git-mirrors.sh}"
rc=0

# 1. update the clones
for c in $ucb $layers; do
  if [ ! -d "$c/.git" ]; then echo "git-refresh: $c is not a git clone, skipped" >&2; rc=1; continue; fi
  git -C "$c" pull -q --ff-only || { echo "git-refresh: could not update $c (kept as it is)" >&2; rc=1; }
done

# 2. and 3. the list, then the mirrors (an empty list is an error: nothing would be mirrored)
# shellcheck disable=SC2086
urls="$("$lister" $ucb $layers)" || { echo "git-refresh: listing the repositories failed" >&2; exit 1; }
[ -n "$urls" ] || { echo "git-refresh: the list of repositories is empty" >&2; exit 1; }
printf '%s\n' "$urls" | sort -u | CACHE_DIR="$root" "$mirrorer" || rc=1
exit "$rc"
