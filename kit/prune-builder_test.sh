#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Test of prune-builder.sh on a fake cache directory (no root, no network). Run: kit/prune-builder_test.sh
# The temporary directory it makes is left in place (path printed); remove it yourself.
# shellcheck disable=SC2015  # intentional: the ok/bad lines are not an if-then-else
set -uo pipefail
tool="$(dirname "$0")/prune-builder.sh"
t="$(mktemp -d "${TMPDIR:-/tmp}/prune-builder-test.XXXXXX")"
echo "test directory: $t"
fails=0
ok() { echo "ok:   $*"; }
bad() { echo "FAIL: $*"; fails=$((fails + 1)); }
c="$t/cache"
# mk <dir> <days old> [file...]: a directory with the given files, everything made <days> days ago
mk() { local d="$1" days="$2"; shift 2; mkdir -p "$d"; for f in "$@"; do mkdir -p "$d/$(dirname "$f")"; echo x > "$d/$f"; done
       find "$d" -exec touch -d "$days days ago" {} +; }

mk "$c/nightly/.2026-11-01-0100.partial" 6 .run-id a/file          # abandoned partial: removed
mk "$c/nightly/.2026-11-20-0100.partial" 1 .run-id a/file          # young partial: kept
mk "$c/nightly/.2026-11-02-0100.partial" 6 a/file                  # old, but no .run-id (not ours): kept
mk "$c/nightly/.2026-11-03-0100.partial" 6 .run-id a/file          # old directory, but a file changed 1 day ago: kept
touch -d "1 days ago" "$c/nightly/.2026-11-03-0100.partial/a/file"
mk "$c/nightly/2026-11-10-0100" 8 m/file                           # finished, old: removed
mk "$c/nightly/2026-11-24-0100" 3 m/file                           # finished, young: kept
mk "$c/nightly/junk" 30 file                                       # not a nightly name: kept
mk "$c/staging/release/vimba/.22.0.9.partial" 6 .run-id img        # abandoned release partial: removed
mk "$c/staging/release/vimba/22.0.1" 9 img                         # finished release, old: removed
mk "$c/staging/release/vimba/22.0.2" 2 img                         # finished release, young: kept
mk "$c/staging/release/vimba/notes" 30 img                         # not a version name: kept
mk "$c/staging/release/BAD/22.0.3" 30 img                          # branch name not lower case: kept
mk "$c/sstate/old" 90 file; mk "$c/dl/old" 90 file; mk "$c/git/old" 90 file   # never touched
ln -s "$c/dl/old" "$c/nightly/2026-11-05-0100"; touch -h -d "30 days ago" "$c/nightly/2026-11-05-0100"   # a symlink: kept
echo x > "$c/staging/release/STAGING.txt"
exists() { [ -e "$1" ]; }
run() { env -i PATH="$PATH" CACHE_DIR="$c" "$tool" ${APPLY:+--apply} 2>&1; }

# 1. dry run: says what it would do, deletes nothing
out="$(run)"; rc=$?
before="$(find "$c" | wc -l)"
if [ "$rc" -eq 0 ] && grep -q 'would remove: .*/.2026-11-01-0100.partial' <<<"$out" && grep -q 'dry run' <<<"$out"; then ok "a dry run lists what it would remove"; else bad "dry run output: $out"; fi
if [ "$(find "$c" | wc -l)" = "$before" ] && exists "$c/nightly/.2026-11-01-0100.partial"; then ok "a dry run removes nothing"; else bad "dry run changed the tree"; fi

# 2. --apply: exactly the old ones go
out="$(APPLY=1 run)"; rc=$?
[ "$rc" -eq 0 ] && ok "apply succeeds" || bad "apply failed: $out"
for gone in "$c/nightly/.2026-11-01-0100.partial" "$c/nightly/2026-11-10-0100" "$c/staging/release/vimba/.22.0.9.partial" "$c/staging/release/vimba/22.0.1"; do
  exists "$gone" && bad "not removed: $gone" || ok "removed: ${gone#"$c"/}"
done
for kept in "$c/nightly/.2026-11-20-0100.partial" "$c/nightly/.2026-11-02-0100.partial" "$c/nightly/.2026-11-03-0100.partial" \
            "$c/nightly/2026-11-24-0100" "$c/nightly/junk" "$c/staging/release/vimba/22.0.2" "$c/staging/release/vimba/notes" \
            "$c/staging/release/BAD/22.0.3" "$c/staging/release/STAGING.txt" "$c/sstate/old" "$c/dl/old" "$c/git/old"; do
  exists "$kept" && ok "kept: ${kept#"$c"/}" || bad "removed by mistake: $kept"
done
[ -L "$c/nightly/2026-11-05-0100" ] && exists "$c/dl/old/file" && ok "a symlink is not followed and its target survives" || bad "symlink handling"

# 3. the limits can be changed, bad values are refused, a missing cache directory is refused
out="$(env -i PATH="$PATH" CACHE_DIR="$c" KEEP_DAYS=1 "$tool" 2>&1)"
grep -q 'would remove: .*/22.0.2' <<<"$out" && ok "KEEP_DAYS=1 would also take the 2 day old release" || bad "KEEP_DAYS ignored: $out"
out="$(env -i PATH="$PATH" CACHE_DIR="$c" KEEP_DAYS=x "$tool" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && ok "a bad KEEP_DAYS is refused" || bad "bad KEEP_DAYS accepted"
out="$(env -i PATH="$PATH" CACHE_DIR="$t/none" "$tool" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && ok "a missing cache directory is refused" || bad "missing cache directory accepted"
out="$(env -i PATH="$PATH" CACHE_DIR="$c" "$tool" --wrong 2>&1)"; rc=$?
[ "$rc" -eq 2 ] && ok "an unknown argument is refused" || bad "unknown argument accepted"

if [ "$fails" -eq 0 ]; then echo "all tests passed"; else echo "$fails test(s) failed"; exit 1; fi
