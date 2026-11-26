#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Test of the dispatch of run.sh (the cron entry of the download server) with stubs for the scripts it calls. No network, no root.
# Run: kit/release/run_test.sh      The temporary directory it makes is left in place (path printed); remove it yourself.
# shellcheck disable=SC2016,SC2015  # intentional: the stub text is single-quoted, the ok/bad lines are not an if-then-else
set -uo pipefail
src="$(cd "$(dirname "$0")" && pwd)"
t="$(mktemp -d "${TMPDIR:-/tmp}/run-test.XXXXXX")"
echo "test directory: $t"
fails=0
ok() { echo "ok:   $*"; }
bad() { echo "FAIL: $*"; fails=$((fails + 1)); }
# a copy of run.sh next to stubs: run.sh calls its neighbours by relative path
mkdir -p "$t/kit/release" "$t/kit/mirror" "$t/root"
cp "$src/run.sh" "$t/kit/release/run.sh"
for s in pull-sync git-refresh; do
  printf '#!/usr/bin/env bash\necho "%s SOURCES=${SOURCES:-} MIRROR_ROOT=${MIRROR_ROOT:-} AREAS=${AREAS:-} EXTRA=${RSYNC_EXTRA:-}"\n' "$s" > "$t/kit/mirror/$s.sh"
done
for s in cleanup-staging cleanup-nightly promote; do printf '#!/usr/bin/env bash\necho "%s called"\n' "$s" > "$t/kit/release/$s.sh"; done
chmod +x "$t"/kit/mirror/*.sh "$t"/kit/release/*.sh
cat > "$t/promote.env" <<EOF2
export RELEASE_ROOT=$t/root
export RELEASE_UCB_DIR=$t/ucb
export BUILD_RSYNC="rsync://builder.example/agl/"
EOF2
git init -q "$t/ucb"
run() { env -i PATH="$PATH" RELEASE_ENV="$t/promote.env" RELEASE_LOG="$t/release.log" MIRROR_LOG="$t/mirror.log" "$t/kit/release/run.sh" "$@" 2>&1; }
: > "$t/release.log"; : > "$t/mirror.log"

# 1. mirror: pulls dl, sstate and git (no AREAS) of the build hosts into RELEASE_ROOT, logs to the mirror log
run mirror; rc=$?
if [ "$rc" -eq 0 ] && grep -q "pull-sync SOURCES=rsync://builder.example/agl/ MIRROR_ROOT=$t/root AREAS= EXTRA=" "$t/mirror.log"; then ok "mirror: pull-sync with the build hosts and the server tree"; else bad "mirror: rc=$rc $(cat "$t/mirror.log")"; fi
[ ! -s "$t/release.log" ] && ok "mirror: nothing in the release log" || bad "mirror wrote to the release log"

# 2. git: the refresh with the server tree, in the mirror log
: > "$t/mirror.log"; run git; rc=$?
if [ "$rc" -eq 0 ] && grep -q "git-refresh SOURCES= MIRROR_ROOT=$t/root" "$t/mirror.log"; then ok "git: git-refresh with the server tree"; else bad "git: rc=$rc $(cat "$t/mirror.log")"; fi

# 3. the nightly pull runs every minute and logs to the mirror log; the cleanups go to the release log
: > "$t/release.log"; : > "$t/mirror.log"; run nightly; run nightly cleanup; run cleanup
if grep -q 'pull-sync SOURCES=rsync://builder.example/agl/ MIRROR_ROOT=.* AREAS=nightly' "$t/mirror.log"; then ok "nightly: pulls the nightly area, in the mirror log"; else bad "mirror log: $(cat "$t/mirror.log")"; fi
if grep -q 'cleanup-nightly called' "$t/release.log" && grep -q 'cleanup-staging called' "$t/release.log"; then ok "both cleanups log to the release log"; else bad "release log: $(cat "$t/release.log")"; fi

# 4. an unknown word is refused with the usage text
run bogus > "$t/out" 2>&1; rc=$?
if [ "$rc" -ne 0 ] && grep -q 'mirror|git' "$t/release.log"; then ok "an unknown word is refused and the usage names mirror and git"; else bad "bogus accepted: rc=$rc"; fi

if [ "$fails" -eq 0 ]; then echo "all tests passed"; else echo "$fails test(s) failed"; exit 1; fi
