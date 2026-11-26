#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Test of the two release blocks ("release kas step" of build.sh and "release collect step" of collect.sh) with stubs for kas_run and docker:
# it checks WHICH commands a release build issues (flags, mounts, environment) without running kas, bitbake or docker.
# Run: ci/scripts/release-build_test.sh      The temporary directory it makes is left in place (path printed); remove it yourself.
#
# How it works: the blocks are cut out of build.sh between their marker comments and run in a fresh bash, after the variables
# that build.sh has at that point (TARGET, MACHINE, KASFILES, TREE, ENGINE) and two stub functions that print their arguments.
set -uo pipefail
f="${1:-$(dirname "$0")/build.sh}"
c="${2:-$(dirname "$0")/collect.sh}"   # the collect blocks live in collect.sh, the kas block in build.sh
t="$(mktemp -d "${TMPDIR:-/tmp}/release-build-test.XXXXXX")"
echo "test directory: $t"
fails=0
ok() { echo "ok:   $*"; }
bad() { echo "FAIL: $*"; fails=$((fails + 1)); }

kas_step="$(sed -n '/^# --- begin release kas step/,/^# --- end release kas step/p' "$f")"
collect_step="$(sed -n '/^# --- begin release collect step/,/^# --- end release collect step/p' "$c")"
[ -n "$kas_step" ] && [ -n "$collect_step" ] || { echo "FAIL: the marker comments of the release blocks are missing in $f or $c" >&2; exit 1; }

# run_blocks TREE [VAR=value ...]: run both blocks in a clean environment with the given variables; prints what the stubs saw.
run_blocks() {
  local tree="$1"; shift
  env -i PATH="$PATH" "$@" bash -c '
    set -euo pipefail
    kas_run() { printf "KAS_RUN %s\n" "$*"; }        # stub: build.sh calls kas through this function
    docker() { printf "DOCKER %s\n" "$*"; }          # stub: the collect step calls docker run
    TARGET=agl-image-minimal; MACHINE=qemux86-64; KASFILES="kas/base.yml:kas/pins.yml"; ENGINE=/ci/scripts; TREE="'"$tree"'"
    '"$kas_step"'
    '"$collect_step"'
  ' 2>&1
}

# Case 1: a normal build (AGL_RELEASE unset) must be exactly what it was: one kas_run build, no provenance, no docker.
tree="$t/normal"; mkdir -p "$tree"
out="$(run_blocks "$tree")"; rc=$?
if [ "$rc" -eq 0 ] && [ "$out" = "KAS_RUN build kas/base.yml:kas/pins.yml" ]; then ok "a normal build issues only 'kas build <files>'"; else bad "normal build changed: rc=$rc out=$out"; fi

# Case 2: a release build. kas gets --provenance mode=min, --target and the extra fragment; docker runs the collect script.
tree="$t/release"; mkdir -p "$tree"
out="$(run_blocks "$tree" AGL_RELEASE=1 IMAGE_REPO=meta-agl RELEASE_BRANCH=vimba RELEASE_VERSION=22.0.2 AGL_SSTATE_DIR=/srv/agl-cache/sstate KAS_CONTAINER_IMAGE=builder@sha256:abc GITHUB_RUN_ID=77)"; rc=$?
if [ "$rc" -eq 0 ]; then ok "a release build runs"; else bad "release build failed: $out"; fi
kas_line="$(grep '^KAS_RUN' <<<"$out")"
if [ "$kas_line" = "KAS_RUN build --provenance mode=min --target agl-image-minimal kas/base.yml:kas/pins.yml:build/ci-kas/provenance.yml" ]; then ok "kas gets mode=min, --target and the provenance fragment"; else bad "wrong kas call: $kas_line"; fi
if grep -q '^  manifest: tmp/deploy/images/qemux86-64/agl-image-minimal-qemux86-64.manifest$' "$tree/build/ci-kas/provenance.yml" && grep -q '^artifacts:$' "$tree/build/ci-kas/provenance.yml"; then ok "the fragment names the image manifest as artifact"; else bad "wrong provenance fragment"; fi
docker_line="$(grep '^DOCKER' <<<"$out")"
want_parts=("run --rm --user 0" "-v $tree:$tree:ro" "-v /ci/scripts:/ci/scripts:ro" "-v /srv/agl-cache/staging/release:/srv/agl-cache/staging/release "
  "-v $tree/build/release-small:$tree/build/release-small" "-e AGL_TREE=$tree" "-e RELEASE_STAGING=/srv/agl-cache/staging/release" "-e RELEASE_BRANCH -e RELEASE_VERSION"
  "--entrypoint /bin/bash builder@sha256:abc /ci/scripts/release-collect.sh --machine qemux86-64 --target agl-image-minimal --repo meta-agl")
missing=""
for p in "${want_parts[@]}"; do case "$docker_line" in *"$p"*) ;; *) missing="$missing [$p]" ;; esac; done
if [ -z "$missing" ]; then ok "docker run has the mounts, the environment and the collect command (staging derived from AGL_SSTATE_DIR)"; else bad "docker call lacks:$missing -- got: $docker_line"; fi
if [ -d "$tree/build/release-small" ]; then ok "the small-file directory is created for the upload"; else bad "release-small directory missing"; fi

# Case 3: RELEASE_STAGING overrides the derived path.
tree="$t/staging"; mkdir -p "$tree"
out="$(run_blocks "$tree" AGL_RELEASE=1 IMAGE_REPO=meta-agl RELEASE_BRANCH=vimba RELEASE_VERSION=22.0.2 RELEASE_STAGING=/data/rel KAS_CONTAINER_IMAGE=b)"
if grep -q -e '-v /data/rel:/data/rel ' <<<"$out"; then ok "RELEASE_STAGING is honoured"; else bad "RELEASE_STAGING ignored: $out"; fi

# Case 4: refusals. Each must stop with a non-zero exit and say why.
tree="$t/refuse"; mkdir -p "$tree"
out="$(run_blocks "$tree" AGL_RELEASE=1 IMAGE_REPO=meta-agl RELEASE_BRANCH=vimba KAS_CONTAINER_IMAGE=b AGL_SSTATE_DIR=/c/sstate)"; rc=$?
if [ "$rc" -ne 0 ] && grep -q 'RELEASE_VERSION is not set' <<<"$out"; then ok "a release without RELEASE_VERSION is refused"; else bad "missing version accepted: $out"; fi
out="$(run_blocks "$tree" AGL_RELEASE=1 IMAGE_REPO=meta-agl RELEASE_BRANCH=vimba RELEASE_VERSION=22.0.2 KAS_EXEC=kas KAS_CONTAINER_IMAGE=b AGL_SSTATE_DIR=/c/sstate)"; rc=$?
if [ "$rc" -ne 0 ] && grep -q 'needs KAS_EXEC=kas-container' <<<"$out"; then ok "a release with KAS_EXEC=kas is refused"; else bad "KAS_EXEC=kas accepted: $out"; fi
out="$(run_blocks "$tree" AGL_RELEASE=1 IMAGE_REPO=meta-agl RELEASE_BRANCH=vimba RELEASE_VERSION=22.0.2 KAS_CONTAINER_IMAGE=b)"; rc=$?
if [ "$rc" -ne 0 ] && grep -q 'AGL_SSTATE_DIR is not set' <<<"$out"; then ok "a host without cache directory is refused"; else bad "missing cache directory accepted: $out"; fi
out="$(run_blocks "$tree" AGL_RELEASE=1 IMAGE_REPO=meta-agl RELEASE_BRANCH=vimba RELEASE_VERSION=22.0.2 AGL_SSTATE_DIR=/c/sstate)"; rc=$?
if [ "$rc" -ne 0 ] && grep -q 'KAS_CONTAINER_IMAGE is not set' <<<"$out"; then ok "a missing builder image is refused"; else bad "missing image accepted: $out"; fi
out="$(run_blocks "$tree" AGL_RELEASE=1 RELEASE_BRANCH=vimba RELEASE_VERSION=22.0.2 AGL_SSTATE_DIR=/c/sstate KAS_CONTAINER_IMAGE=b)"; rc=$?
if [ "$rc" -ne 0 ] && grep -q 'IMAGE_REPO is not set' <<<"$out"; then ok "a release without IMAGE_REPO is refused"; else bad "missing IMAGE_REPO accepted: $out"; fi

# Case 5: the flattened kas file. Release and nightly builds dump it next to the image: without the host fragments and the
# provenance fragment, with the target, never with --resolve-env. A normal build writes none.
flat_step="$(sed -n '/^# --- begin flattened kas file step/,/^# --- end flattened kas file step/p' "$f")"
[ -n "$flat_step" ] || { echo "FAIL: the marker comments of the flattened kas file step are missing in $f" >&2; exit 1; }
files="kas/base.yml:kas/machine/qemux86-64.yml:kas/pins.yml:kas/local/sstate-shared.yml:kas/local/dl-shared.yml:kas/local/mirrors.yml"
files="$files:kas/local/hashserv-rw.yml:kas/local/hashserv-upstream.yml:kas/local/vulnscout-sbom.yml:kas/feature/trowl.yml:build/ci-kas/ci-only.yml:build/ci-kas/provenance.yml"
# shellcheck disable=SC2016  # the single-quoted stub is meant to expand inside the inner bash
run_flat() {
  local tree="$1"; shift
  env -i PATH="$PATH" "$@" bash -c '
    set -euo pipefail
    kas_run() { printf "%s\n" "$*" >> "'"$tree"'/kas.args"; echo "flattened: yes"; return "${KAS_RC:-0}"; }
    TARGET=agl-image-minimal; MACHINE=qemux86-64; KASFILES="'"$files"'"; TREE="'"$tree"'"
    '"$flat_step"'
  ' 2>&1
}
want="dump --resolve-refs --resolve-local kas/base.yml:kas/machine/qemux86-64.yml:kas/pins.yml:kas/local/vulnscout-sbom.yml:kas/feature/trowl.yml:build/ci-kas/ci-only.yml:build/ci-kas/target.yml"
for mode in AGL_RELEASE AGL_NIGHTLY; do
  tree="$t/flat-$mode"; d="$tree/build/tmp/deploy/images/qemux86-64"; mkdir -p "$d"
  out="$(run_flat "$tree" "$mode=1")"; rc=$?
  if [ "$rc" -eq 0 ] && [ "$(cat "$tree/kas.args")" = "$want" ]; then ok "$mode: kas dumps the public fragments plus the target"; else bad "$mode: rc=$rc out=$out args=$(cat "$tree/kas.args")"; fi
  if grep -qx 'flattened: yes' "$d/agl-image-minimal-qemux86-64.kas.yml" && grep -qx '  - agl-image-minimal' "$tree/build/ci-kas/target.yml"; then ok "$mode: the file is next to the image, the target fragment names the image"; else bad "$mode: file or target fragment wrong"; fi
done
tree="$t/flat-normal"; mkdir -p "$tree/build/tmp/deploy/images/qemux86-64"
run_flat "$tree" > /dev/null; if [ ! -e "$tree/kas.args" ]; then ok "a normal build writes no flattened file"; else bad "a normal build dumped"; fi
tree="$t/flat-fail"; mkdir -p "$tree/build/tmp/deploy/images/qemux86-64"
out="$(run_flat "$tree" AGL_NIGHTLY=1 KAS_RC=1)"; rc=$?
if [ "$rc" -ne 0 ] && [ ! -e "$tree/build/tmp/deploy/images/qemux86-64/agl-image-minimal-qemux86-64.kas.yml" ]; then ok "a failed dump fails the step and leaves no file"; else bad "failed dump accepted: $out"; fi

if [ "$fails" -eq 0 ]; then echo "all tests passed"; else echo "$fails test(s) failed"; exit 1; fi
