#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Test of git-refresh.sh with local git repositories and a stub for git-mirrors.sh (no network, no root).
# Run: kit/mirror/git-refresh_test.sh      The temporary directory it makes is left in place (path printed); remove it yourself.
set -uo pipefail
tool="$(dirname "$0")/git-refresh.sh"
lister="$(dirname "$0")/git-repos-from-kas.py"
t="$(mktemp -d "${TMPDIR:-/tmp}/git-refresh-test.XXXXXX")"
echo "test directory: $t"
fails=0
ok() { echo "ok:   $*"; }
bad() { echo "FAIL: $*"; fails=$((fails + 1)); }
G="git -c user.name=t -c user.email=t@example.org"
# an upstream repository with one kas file, and a clone of it (a "layer clone" of the server)
mkclone() { # name url-in-kas-file
  git init -q --bare "$t/up-$1.git"
  git clone -q "$t/up-$1.git" "$t/w-$1" 2>/dev/null
  mkdir -p "$t/w-$1/kas/feature"
  printf 'header:\n  version: 22\nrepos:\n  x:\n    url: %s\n' "$2" > "$t/w-$1/kas/feature/f.yml"
  ( cd "$t/w-$1" && git add -A && $G commit -q -m init && git push -q origin HEAD 2>/dev/null )
  git clone -q "$t/up-$1.git" "$t/c-$1" 2>/dev/null
}
mkclone ucb https://github.com/o/ucb-layer.git
mkclone one https://github.com/o/one-layer.git
mkclone two https://git.example.org/two/layer
# the stub of git-mirrors.sh: prints the URLs it gets and the CACHE_DIR it was told
cat > "$t/mirrors-stub.sh" <<'SH'
#!/usr/bin/env bash
echo "MIRRORS CACHE_DIR=$CACHE_DIR"; while read -r u; do echo "URL $u"; done
SH
chmod +x "$t/mirrors-stub.sh"
run() { env -i PATH="$PATH" MIRROR_ROOT="$t/permanent" UCB_CLONE="$t/c-ucb" LAYER_CLONES="$t/c-one $t/c-two" MIRRORS_CMD="$t/mirrors-stub.sh" "$@" "$tool" 2>&1; }

# 1. the clones are listed with their kas files, the stub gets sorted unique URLs and the tree as CACHE_DIR
out="$(run)"; rc=$?
if [ "$rc" -eq 0 ] && grep -q "MIRRORS CACHE_DIR=$t/permanent" <<<"$out" && grep -q 'URL https://github.com/o/one-layer.git' <<<"$out" \
   && grep -q 'URL https://git.example.org/two/layer' <<<"$out" && grep -q 'URL https://github.com/o/ucb-layer.git' <<<"$out"; then ok "the repositories of all clones go to git-mirrors.sh with the server tree"
else bad "list or tree wrong (rc=$rc): $out"; fi

# 2. a new commit upstream is pulled before the list is made (a new kas file shows its repository)
printf 'header:\n  version: 22\nrepos:\n  y:\n    url: https://github.com/o/new-layer.git\n' > "$t/w-one/kas/feature/g.yml"
( cd "$t/w-one" && git add -A && $G commit -q -m more && git push -q origin HEAD 2>/dev/null )
out="$(run)"
if grep -q 'URL https://github.com/o/new-layer.git' <<<"$out"; then ok "a clone is updated first, so a new kas file is seen"; else bad "new repository not listed: $out"; fi

# 3. a clone that cannot be fast-forwarded: reported, the others go on, exit status 1
( cd "$t/c-two" && echo local > l && git add -A && $G commit -q -m local )
( cd "$t/w-two" && echo up > u && git add -A && $G commit -q -m up && git push -q origin HEAD 2>/dev/null )
out="$(run)"; rc=$?
if [ "$rc" -eq 1 ] && grep -q 'could not update .*c-two' <<<"$out" && grep -q 'URL https://github.com/o/one-layer.git' <<<"$out"; then ok "a clone that diverged is reported, the refresh goes on, exit status 1"
else bad "diverged clone not handled (rc=$rc): $out"; fi

# 4. a missing clone is reported and skipped
out="$(run LAYER_CLONES="$t/c-one $t/none")"; rc=$?
if [ "$rc" -eq 1 ] && grep -q "none is not a git clone" <<<"$out"; then ok "a missing clone is reported"; else bad "missing clone: rc=$rc $out"; fi

# 5. an empty list is an error and git-mirrors.sh is not called
mkdir -p "$t/empty/.git"
out="$(run UCB_CLONE="$t/empty" LAYER_CLONES="")"; rc=$?
if [ "$rc" -ne 0 ] && ! grep -q MIRRORS <<<"$out"; then ok "an empty list stops before git-mirrors.sh"; else bad "empty list accepted: rc=$rc $out"; fi
[ -x "$lister" ] || bad "the lister is not executable"

if [ "$fails" -eq 0 ]; then echo "all tests passed"; else echo "$fails test(s) failed"; exit 1; fi
