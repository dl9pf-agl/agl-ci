#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Pull the cache of one or more TRUSTED build hosts into the mirror tree of a SEPARATE download server (agl-ci chapter 15).
# Run it on the download server, from cron, every few minutes and after the nightly. The download server initiates the
# transfer; the build hosts offer their cache read-only through kit/mirror/rsyncd.sh on a private network, so there is no
# account, key or password on either side.
#
#   SOURCES="rsync://10.0.0.5/agl/ rsync://10.0.0.6/agl/" MIRROR_ROOT=/srv/mirror kit/mirror/pull-sync.sh [-n]
#
#   SOURCES      rsync daemon URLs of the build hosts (module "agl", ending in "/"); the script appends dl/, sstate/ and git/.
#   MIRROR_ROOT  where the mirror tree lives (default /srv/mirror); the web server serves MIRROR_ROOT/dl, sstate and git.
#   AREAS        default "dl sstate git". A missing area on a source is skipped with a note (git/ exists only after
#                git-mirrors.sh ran); dl and sstate missing is an error.
#   -n           dry run: show what would be copied, change nothing.
#
# What it does NOT copy (the daemon refuses them too): *.lock, *.tmp, *.done, hashserv.db*, dotfiles, dl/git2/.
# Existing files are never replaced (--ignore-existing): objects are content-addressed, so a file that exists is the right
# one, and a damaged or tampered copy on a build host cannot overwrite a good one. Files appear atomically (--delay-updates).
# After a successful run MIRROR_ROOT/LAST_SYNC holds the time; a monitor should alert when it gets old. Runs as any user that
# may write MIRROR_ROOT; it needs no privilege.
set -euo pipefail
mirror="${MIRROR_ROOT:-/srv/mirror}"
sources="${SOURCES:?set SOURCES to the rsync URLs of the trusted build hosts, e.g. \"rsync://10.0.0.5/agl/\"}"
areas="${AREAS:-dl sstate git}"
dry=(); [ "${1:-}" != -n ] || dry=(--dry-run)
common=(-a --ignore-existing --delay-updates --partial --timeout=300 --exclude='*.lock' --exclude='*.tmp' --exclude='*.done' --exclude='hashserv.db*' --exclude='.*')
for base in $sources; do
  [[ "$base" =~ ^rsync://[][A-Za-z0-9.:-]+/[A-Za-z0-9._-]+/$ ]] || { echo "pull-sync: SOURCES entries must look like rsync://host/module/ : $base" >&2; exit 1; }
  for area in $areas; do
    if ! rsync --timeout=60 --list-only "$base$area/" >/dev/null 2>&1; then
      case "$area" in dl|sstate) echo "pull-sync: ERROR: $base$area/ is not readable" >&2; exit 1 ;; *) echo "pull-sync: $base$area/ not offered, skipped"; continue ;; esac
    fi
    [ "${#dry[@]}" -gt 0 ] || mkdir -p "$mirror/$area"
    extra=(); [ "$area" != dl ] || extra=(--exclude='/git2/')
    echo "pull-sync: $base$area/ -> $mirror/$area/"
    rsync "${common[@]}" "${extra[@]}" "${dry[@]}" "$base$area/" "$mirror/$area/"
  done
done
[ "${#dry[@]}" -gt 0 ] || date -u +%Y-%m-%dT%H:%M:%SZ > "$mirror/LAST_SYNC"
