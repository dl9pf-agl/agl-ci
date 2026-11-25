#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# shellcheck disable=SC2016,SC2015  # intentional: the forwarding script is single-quoted, and the ok/bad lines are not an if-then-else
# Checks agl_premirrors() of _kas_runtime_args.sh (the git mirror rewrite of kas): the value has no backslash, because kas-container
# forwards KAS_PREMIRRORS with `eval echo` under sh (dash on Debian and Ubuntu) and the first proof build (2026-11-16) got a control character
# in the clone URL where "\1" stood; the value must also survive
# that forwarding unchanged; and it rewrites URLs the way kas/repos.py applies it. Usage: ci/scripts/premirror_test.sh [file] (needs python3)
set -u
f="${1:-$(dirname "$0")/_kas_runtime_args.sh}"; fail=0
blk="$(sed -n '/^# --- begin premirrors/,/^# --- end premirrors/p' "$f")"
[ -n "$blk" ] || { echo "FAIL  no premirrors block in $f" >&2; exit 1; }
ok() { echo "ok    $1"; }; bad() { echo "FAIL  $1" >&2; fail=1; }
val="$(env -i PATH="$PATH" AGL_MIRROR_URL=http://m:8080 AGL_PIN_URL=https://github.com/o/r.git GITHUB_REPOSITORY_OWNER=dl9pf-agl bash -c "$blk"$'\nagl_premirrors')"
case "$val" in *\\*) bad "the value contains a backslash" ;; *) ok "no backslash in the value" ;; esac
# the forwarding of kas-container (-e "VAR=$(eval echo \"\$VAR\")"), run by dash where it exists (Debian and Ubuntu: it is sh)
sh_bin="$(command -v dash || command -v sh)"
fwd="$(KAS_PREMIRRORS="$val" "$sh_bin" -c 'eval echo \"\$KAS_PREMIRRORS\"')"
[ "$fwd" = "$val" ] && ok "the value survives the forwarding by $sh_bin" || bad "the forwarding by $sh_bin changed the value"
# kas/repos.py effective_url: the first line whose expression matches, then re.sub
rewrite() { python3 -c 'import re,sys
url=sys.argv[2]
for m in sys.argv[1].split("\n"):
    expr,subst=m.split()
    if re.match(expr,url):
        url=re.sub(expr,subst,url); break
print(url)' "$fwd" "$1"; }
chk() { local got; got="$(rewrite "$1")"; [ "$got" = "$2" ] && ok "$1 -> $2" || bad "$1: got $got, want $2"; }
chk https://github.com/openembedded/meta-openembedded http://m:8080/git/github.com/openembedded/meta-openembedded
chk https://git.yoctoproject.org/meta-arm http://m:8080/git/git.yoctoproject.org/meta-arm
chk https://code.qt.io/yocto/meta-qt6 http://m:8080/git/code.qt.io/yocto/meta-qt6
chk https://github.com/dl9pf-agl/meta-agl-demo.git https://github.com/dl9pf-agl/meta-agl-demo.git   # our own organisation floats: never the mirror
chk https://github.com/dl9pf-agl/meta-agl.git https://github.com/dl9pf-agl/meta-agl.git
chk https://github.com/dl9pf-agl-other/x.git http://m:8080/git/github.com/dl9pf-agl-other/x.git   # another organisation with the same start is mirrored
chk https://github.com/o/r.git https://github.com/o/r.git   # the repo under test stays where it is
chk https://example.org/x/y https://example.org/x/y   # a host that is not mirrored is cloned from its origin
# fetch.sh keeps the layer rewrite (and only that) while it unsets the source and sstate mirror
grep -q 'KAS_PREMIRRORS="$(agl_premirrors)"' "$(dirname "$f")/fetch.sh" && ok "fetch.sh sets the layer premirrors" || bad "fetch.sh does not set the layer premirrors"
# AGL_GIT_DIRECT replaces the default prefix; a value that is not a prefix ending in / is refused
v2="$(env -i PATH="$PATH" AGL_MIRROR_URL=http://m:8080 AGL_GIT_DIRECT=https://github.com/o2/ bash -c "$blk"$'\nagl_premirrors')"
case "$v2" in *"^https://github[.]com/o2/ https://github.com/o2/"*) ok "AGL_GIT_DIRECT adds its prefix";; *) bad "AGL_GIT_DIRECT ignored: $v2";; esac
case "$v2" in *dl9pf-agl*) bad "AGL_GIT_DIRECT did not replace the default";; *) ok "AGL_GIT_DIRECT replaces the default prefix";; esac
if env -i PATH="$PATH" AGL_MIRROR_URL=http://m:8080 AGL_GIT_DIRECT=https://github.com/o2 bash -c "$blk"$'\nagl_premirrors' >/dev/null 2>&1; then bad "a prefix without a final / was accepted"; else ok "a prefix without a final / is refused"; fi
# no owner and no AGL_GIT_DIRECT: only the host rules (and the repo under test)
v3="$(env -i PATH="$PATH" AGL_MIRROR_URL=http://m:8080 bash -c "$blk"$'\nagl_premirrors')"
case "$v3" in *"github.com/ https://github.com/"*) bad "a direct rule without an owner: $v3";; *) ok "without an owner there is no direct rule";; esac
exit "$fail"
