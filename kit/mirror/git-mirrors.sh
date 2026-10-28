#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Keep bare mirrors of the git repositories that kas clones (the layers), below CACHE_DIR/git, so that a clean checkout works
# when github.com, git.yoctoproject.org or git.openembedded.org are down (outage tier T2/T3, agl-ci chapter 15).
#
#   CACHE_DIR=/srv/agl-cache kit/mirror/git-mirrors.sh URL [URL ...]       (or the URLs on stdin, one per line)
#   kit/mirror/git-repos-from-kas.py <dir> ... | kit/mirror/git-mirrors.sh        (URLs from the kas files below the directories)
#
# Layout: CACHE_DIR/git/<host>/<path of the URL>, e.g. https://github.com/org/repo.git -> git/github.com/org/repo.git. The
# web server (kit/mirror/nginx.conf) serves it read-only as /git/ over plain "dumb" HTTP, which is why every run ends with
# `git update-server-info`. A consumer maps the URL with KAS_PREMIRRORS (AGL_GIT_MIRROR=1, chapter 15).
# Run it as root on the trusted host (CACHE_DIR is root-only), from cron or after the nightly. First run clones, later runs update.
# Integrity: kas pins the layers by commit, and a commit hash cannot be forged, so a damaged mirror fails the checkout instead of
# changing the build. Only repositories with `branch:` and no `commit:` depend on the mirror being current.
set -euo pipefail
cache="${CACHE_DIR:-/srv/agl-cache}"
[ -d "$cache" ] || { echo "$cache not found (run as root; CACHE_DIR=...)" >&2; exit 1; }
if [ $# -gt 0 ]; then urls=("$@"); else mapfile -t urls; fi
fail=0
for url in "${urls[@]}"; do
  [ -n "$url" ] || continue
  # the URL becomes a path below $cache/git: allow only a plain http(s) URL without "..", userinfo, query or fragment
  if ! [[ "$url" =~ ^https?://[A-Za-z0-9.-]+(:[0-9]+)?/[A-Za-z0-9._/-]+$ ]] || [[ "$url" == *..* ]]; then
    echo "git-mirrors: refusing URL: $url" >&2; fail=1; continue
  fi
  dest="$cache/git/${url#*://}"
  if [ -d "$dest" ]; then
    echo "git-mirrors: update $url"; git -C "$dest" remote update --prune >/dev/null || { echo "git-mirrors: FAILED to update $url" >&2; fail=1; continue; }
  else
    echo "git-mirrors: clone $url"; mkdir -p "$(dirname "$dest")"
    git clone -q --mirror "$url" "$dest" || { echo "git-mirrors: FAILED to clone $url" >&2; rm -rf "$dest"; fail=1; continue; }
  fi
  git -C "$dest" update-server-info
done
exit "$fail"
