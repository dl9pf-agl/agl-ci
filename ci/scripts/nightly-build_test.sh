#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Test of collect.sh's "nightly collect step" block, same technique as release-build_test.sh: the block is cut out of
# collect.sh by its marker comments and run in a fresh bash, with a stub docker function - no kas, no real docker. Run:
# ci/scripts/nightly-build_test.sh      The temporary directory it makes is left in place (path printed); remove it yourself.
set -uo pipefail
f="${1:-$(dirname "$0")/collect.sh}"
t="$(mktemp -d "${TMPDIR:-/tmp}/nightly-build-test.XXXXXX")"
echo "test directory: $t"
fails=0
ok() { echo "ok:   $*"; }
bad() { echo "FAIL: $*"; fails=$((fails + 1)); }

nightly_step="$(sed -n '/^# --- begin nightly collect step/,/^# --- end nightly collect step/p' "$f")"
[ -n "$nightly_step" ] || { echo "FAIL: the marker comments of the nightly collect step are missing in $f" >&2; exit 1; }

# mkrepo TREE REPO: a checkout of REPO inside TREE (the step reads the commit of the image's repository); prints the commit.
mkrepo() {
  git init -q "$1/$2" && git -C "$1/$2" -c user.name=t -c user.email=t@example.org commit -q --allow-empty -m x && git -C "$1/$2" rev-parse HEAD
}

# run_nightly TREE [VAR=value ...]: run the block in a clean environment with a stub docker function (like release-build_test.sh).
run_nightly() {
  local tree="$1"; shift
  env -i PATH="$PATH" "$@" bash -c '
    set -euo pipefail
    docker() { printf "DOCKER %s\n" "$*"; }
    TARGET=agl-image-minimal; MACHINE=qemux86-64; AGL_SCOPE=meta-agl; ENGINE=/ci/scripts; TREE="'"$tree"'"
    '"$nightly_step"'
  ' 2>&1
}

# 1. AGL_NIGHTLY unset: the block does nothing.
tree="$t/noc"; mkdir -p "$tree"
out="$(run_nightly "$tree")"; rc=$?
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then ok "AGL_NIGHTLY unset never runs the collect step"; else bad "unexpected output with AGL_NIGHTLY unset: $out"; fi

# 2. AGL_NIGHTLY=1: docker run carries the mounts, the environment and the collect command (staging derived from AGL_SSTATE_DIR);
#    commit and run address come from the checkout and the GitHub variables.
tree="$t/nightly"; mkdir -p "$tree"; commit="$(mkrepo "$tree" meta-agl)"
out="$(run_nightly "$tree" AGL_NIGHTLY=1 IMAGE_REPO=meta-agl NIGHTLY_DATE=2026-11-26-0300 AGL_SSTATE_DIR=/srv/agl-cache/sstate KAS_CONTAINER_IMAGE=builder@sha256:abc \
  GITHUB_RUN_ID=77 GITHUB_SERVER_URL=https://github.com GITHUB_REPOSITORY=org/meta-agl)"; rc=$?
want_parts=("run --rm --user 0" "-v $tree:$tree:ro" "-v /ci/scripts:/ci/scripts:ro" "-v /srv/agl-cache/nightly:/srv/agl-cache/nightly"
  "-e AGL_TREE=$tree" "-e NIGHTLY_STAGING=/srv/agl-cache/nightly" "-e NIGHTLY_DATE" "-e NIGHTLY_COMMIT=$commit"
  "-e NIGHTLY_RUN_URL=https://github.com/org/meta-agl/actions/runs/77" "-e NIGHTLY_RUN_ID=77"
  "--entrypoint /bin/bash builder@sha256:abc /ci/scripts/nightly-collect.sh --machine qemux86-64 --target agl-image-minimal --repo meta-agl")
missing=""
for p in "${want_parts[@]}"; do case "$out" in *"$p"*) ;; *) missing="$missing [$p]" ;; esac; done
if [ "$rc" -eq 0 ] && [ -z "$missing" ]; then ok "AGL_NIGHTLY=1 docker run has the mounts, environment and collect command"; else bad "docker call lacks:$missing -- got: $out"; fi

# 3. IMAGE_REPO (the repo that owns the image) names folder and commit, not the calling repo (AGL_SCOPE=meta-agl in the stub).
tree="$t/repo"; mkdir -p "$tree"; commit="$(mkrepo "$tree" meta-agl-demo)"
out="$(run_nightly "$tree" AGL_NIGHTLY=1 IMAGE_REPO=meta-agl-demo NIGHTLY_DATE=2026-11-26-0300 AGL_SSTATE_DIR=/srv/agl-cache/sstate KAS_CONTAINER_IMAGE=b)"
case "$out" in *"-e NIGHTLY_COMMIT=$commit"*"--repo meta-agl-demo") ok "IMAGE_REPO names the folder and the commit";; *) bad "IMAGE_REPO ignored: $out";; esac

# 4. Without IMAGE_REPO: refused.
out="$(run_nightly "$tree" AGL_NIGHTLY=1 AGL_SSTATE_DIR=/srv/agl-cache/sstate KAS_CONTAINER_IMAGE=b)"; rc=$?
if [ "$rc" -ne 0 ] && grep -q 'IMAGE_REPO is not set' <<<"$out"; then ok "a nightly without IMAGE_REPO is refused"; else bad "missing IMAGE_REPO accepted: $out"; fi

if [ "$fails" -eq 0 ]; then echo "all tests passed"; else echo "$fails test(s) failed"; exit 1; fi
