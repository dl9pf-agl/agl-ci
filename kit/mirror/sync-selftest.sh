#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Exercise the whole sync chain on ONE host, so that it can be tried before the download server is a separate machine
# (agl-ci chapter 15): read-only rsync daemon (rsyncd.sh) -> pull (pull-sync.sh) into a scratch mirror tree -> nginx
# container (run.sh) serving that tree -> checks. Nothing of the real setup is touched: own container names (agl-rsyncd-test,
# agl-mirror-test), own ports, a scratch directory. Run it as the user who would run the pull, NOT as root (it asks sudo only
# where rsyncd.sh and run.sh do, to read the root-only CACHE_DIR).
#   kit/mirror/sync-selftest.sh [cleanup]
#
#   CACHE_DIR        cache to publish (default /srv/agl-cache)
#   WORK             scratch directory (default ~/agl-sync-selftest); needs space for the pulled files
#   RSYNC_EXTRA      what to pull; default "--max-size=200K" = only small files, so a 30 GB cache costs a few hundred MB.
#                    Use RSYNC_EXTRA= (empty) for everything.
#   SELFTEST_PORT / SELFTEST_WEB_PORT   defaults 18730 / 18080
#   SELFTEST_NETWORK=host   use host networking for both containers (where the docker bridge cannot be used)
# By default the daemon is published on 127.0.0.1 through docker's port mapping and "hosts allow" is the address of the
# docker bridge gateway, because that is the address the daemon sees for a connection from this host. That is the path a
# separate download server cannot test (it comes from another address), so check the daemon log line printed at the end.
set -euo pipefail
here="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
E=docker; CACHE_DIR="${CACHE_DIR:-/srv/agl-cache}"; WORK="${WORK:-$HOME/agl-sync-selftest}"
PORT="${SELFTEST_PORT:-18730}"; WEB="${SELFTEST_WEB_PORT:-18080}"; EXTRA="${RSYNC_EXTRA---max-size=200K}"
IMAGE="ghcr.io/dl9pf-agl/agl-ci/builder@$(tr -d '[:space:]' < "$here/../../ci/builder.digest")"
[ "$(id -u)" != 0 ] || { echo "run this as the normal user, not as root" >&2; exit 1; }
stop() { "$E" rm -f agl-rsyncd-test agl-mirror-test >/dev/null 2>&1 || true; }
if [ "${1:-}" = cleanup ]; then stop; rm -rf "$WORK"; echo "removed the test containers and $WORK"; exit 0; fi
trap stop EXIT
fails=0
chk() { local m="$1"; shift; if "$@"; then echo "ok:   $m"; else echo "FAIL: $m" >&2; fails=$((fails+1)); fi; }
mkdir -p "$WORK/mirror"
if [ -n "${SELFTEST_NETWORK:-}" ]; then allow=127.0.0.1; net=(RSYNCD_NETWORK="$SELFTEST_NETWORK"); webnet=(MIRROR_NETWORK="$SELFTEST_NETWORK"); webport=8080
else allow="$("$E" network inspect bridge -f '{{(index .IPAM.Config 0).Gateway}}')"; net=(); webnet=(); webport="$WEB"; fi

echo "== 1 daemon (published on 127.0.0.1:$PORT, allowed: $allow)"
env CACHE_DIR="$CACHE_DIR" RSYNCD_BIND=127.0.0.1 RSYNCD_ALLOW="$allow" RSYNCD_PORT="$PORT" RSYNCD_NAME=agl-rsyncd-test "${net[@]}" "$here/rsyncd.sh"
sleep 2

echo "== 2 pull as uid $(id -u) with the client from the builder image (RSYNC_EXTRA='$EXTRA')"
pull() { "$E" run --rm --network host --user "$(id -u):$(id -g)" -v "$WORK:/w" -v "$here/../..:/repo:ro" \
  -e SOURCES="rsync://127.0.0.1:$PORT/agl/" -e MIRROR_ROOT=/w/mirror -e RSYNC_EXTRA="$EXTRA" --entrypoint /repo/kit/mirror/pull-sync.sh "$IMAGE"; }
pull | tail -4
chk "LAST_SYNC written" test -s "$WORK/mirror/LAST_SYNC"
n1="$(find "$WORK/mirror" -type f | wc -l)"; chk "$n1 files pulled" test "$n1" -gt 1
leak="$(find "$WORK/mirror" \( -name '*.lock' -o -name '*.tmp' -o -name '*.done' -o -name 'hashserv.db*' -o -path '*/dl/git2/*' -o -name '.*' \) -type f ! -name LAST_SYNC | head -3)"
chk "no lock, tmp, done, hashserv.db, git2 or dotfile in the pulled tree${leak:+ (found: $leak)}" test -z "$leak"
echo "== 3 second pull must change nothing"
pull >/dev/null; n2="$(find "$WORK/mirror" -type f | wc -l)"
chk "second pull adds no file ($n1 -> $n2; a growing cache, e.g. a running nightly, can fail this)" test "$n2" = "$n1"
echo "== 4 the daemon refuses a write"
chk "write refused" bash -c "'$E' run --rm --network host --entrypoint bash '$IMAGE' -c 'echo x > /tmp/up; rsync /tmp/up rsync://127.0.0.1:$PORT/agl/dl/up' 2>&1 | grep -q 'read only'"

echo "== 5 nginx container serving the pulled tree (own name, port $webport)"
env CACHE_DIR="$WORK/mirror" PORT="$WEB" MIRROR_NAME=agl-mirror-test "${webnet[@]}" "$here/run.sh" | head -1
sleep 2
f="$(cd "$WORK/mirror/dl" && find . -maxdepth 1 -type f -name '*.tar.*' | head -1 | sed 's|^\./||')"
if [ -n "$f" ]; then
  chk "GET /dl/$f -> 200" test "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$webport/dl/$f")" = 200
  chk "served bytes equal the pulled file" test "$(curl -s "http://127.0.0.1:$webport/dl/$f" | sha256sum | cut -d' ' -f1)" = "$(sha256sum "$WORK/mirror/dl/$f" | cut -d' ' -f1)"
else echo "note: no small tarball in dl/ to fetch through nginx (raise RSYNC_EXTRA max-size)"; fi
chk "listing refused (403)" test "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$webport/dl/")" = 403

echo "== daemon log (what address did it see?)"; "$E" logs agl-rsyncd-test 2>&1 | tail -4
echo
if [ "$fails" != 0 ]; then echo "selftest: $fails check(s) failed" >&2; exit 1; fi
echo "selftest passed"
echo "scratch tree: $WORK (remove with: $0 cleanup)"
