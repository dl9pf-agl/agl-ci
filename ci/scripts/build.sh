#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Build a matrix entry's target image, optionally populate_sdk (gated by both the
# entry's sdk flag and the caller-resolved --sdk-allowed), and copy deploy artifacts.
set -euo pipefail

# shellcheck source=./_kas_runtime_args.sh
# shellcheck source=./_kas_runtime_args.sh disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/_kas_runtime_args.sh"
cd "$TREE" || exit 1

parse_common_args "$@"

matrix_fields kasfiles,target,sdk
KASFILES="${_MATRIX_FIELDS[0]}$(kas_extra_includes)$(kas_ci_includes)"
TARGET="${_MATRIX_FIELDS[1]}"
ENTRY_SDK="${_MATRIX_FIELDS[2]}"

echo "build.sh: kas build $KASFILES (target=$TARGET)"
# --- begin release kas step (release-build_test.sh runs this block with stubs for kas_run and docker)
if [ "${AGL_RELEASE:-}" = 1 ]; then
  # --- Release build (agl-ci release.yml sets AGL_RELEASE=1; every other caller leaves it unset and takes the else branch) -------
  # What differs from a normal build:
  #   - kas writes a SLSA provenance statement (--provenance mode=min: mode=max would put values of the environment, such as
  #     mirror and hash-server addresses, into a public file) to $TREE/build/attestation/kas-build.provenance.json;
  #   - the target is given with --target, so that the statement records it (the environment variable KAS_TARGET is not recorded);
  #   - kas needs at least one `artifacts:` entry in provenance mode (else it exits non-zero); the image manifest is always there,
  #     and its sha256 becomes the subject of kas's statement. The files of the release are collected separately, below.
  # The files are collected after the SDK step, by release-collect.sh, which runs in a container (see there).
  : "${RELEASE_BRANCH:?RELEASE_BRANCH is not set}" "${RELEASE_VERSION:?RELEASE_VERSION is not set}"
  [ "${KAS_EXEC:-kas-container}" = kas-container ] || { echo "build.sh: a release build needs KAS_EXEC=kas-container" >&2; exit 1; }
  mkdir -p "$TREE/build/ci-kas"
  cat > "$TREE/build/ci-kas/provenance.yml" <<YAML
header:
  version: 22
artifacts:
  manifest: tmp/deploy/images/$MACHINE/$TARGET-$MACHINE.manifest
YAML
  KASFILES="$KASFILES:build/ci-kas/provenance.yml"
  # shellcheck disable=SC2046
  KAS_TARGET="$TARGET" kas_run build --provenance mode=min --target "$TARGET" "$KASFILES"
else
  # shellcheck disable=SC2046
  KAS_TARGET="$TARGET" kas_run build "$KASFILES"
fi
# --- end release kas step

# --- begin trowl scan step (trowl-build_test.sh runs this block with a stub trowl-scan.sh)
if [ "${AGL_TROWL:-}" = 1 ]; then
  # Report-only: a scan failure (tool bug, unsupported image) must not fail the build (trowl-scan.sh explains why/where it writes).
  # shellcheck disable=SC2153  # ENGINE is assigned in _kas_runtime_args.sh, which this script sources
  "$ENGINE/trowl-scan.sh" --deploy-dir "$TREE/build/tmp/deploy/images/$MACHINE" --target "$TARGET" --machine "$MACHINE" \
    || echo "build.sh: WARNING: trowl scan failed or found nothing to scan (report-only, build continues)" >&2
fi
# --- end trowl scan step

if [ "$ENTRY_SDK" = "True" ] && [ "$SDK_ALLOWED" = "true" ]; then
  echo "build.sh: populating SDK for $TARGET"
  # shellcheck disable=SC2046
  kas_run shell "$KASFILES" -c "bitbake -c populate_sdk $TARGET"
fi

# --- begin release collect step (release-build_test.sh runs this block with stubs for kas_run and docker)
if [ "${AGL_RELEASE:-}" = 1 ]; then
  # Collect the release files of this image (release-collect.sh explains what and why). It must run in a container: this script
  # runs in the runner container, which cannot enter the cache directory (root:root 0700), while the sidecar's Docker daemon
  # sees it. So: docker run on that daemon, as root, with the builder image (it has bash and coreutils), mounting
  #   the build tree (read-only), this ci/scripts directory (read-only), the release staging area (read-write) and the small-file
  #   directory (read-write; the workflow uploads it). The workspace has the same path in the runner and in the sidecar, and the
  #   cache directory is mounted at the same path in both, so the same paths work on both sides.
  # shellcheck disable=SC2153  # ENGINE is assigned in _kas_runtime_args.sh, which this script sources
  engine="$ENGINE"   # this ci/scripts directory
  staging="${RELEASE_STAGING:-$(dirname "${AGL_SSTATE_DIR:?AGL_SSTATE_DIR is not set: this host has no cache directory}")/staging/release}"
  small="$TREE/build/release-small"
  mkdir -p "$small"
  docker run --rm --user 0 \
    -v "$TREE:$TREE:ro" -v "$engine:$engine:ro" -v "$staging:$staging" -v "$small:$small" \
    -e AGL_TREE="$TREE" -e RELEASE_STAGING="$staging" -e RELEASE_BRANCH -e RELEASE_VERSION \
    -e RELEASE_SMALL_DIR="$small" \
    --entrypoint /bin/bash "${KAS_CONTAINER_IMAGE:?KAS_CONTAINER_IMAGE is not set}" \
    "$engine/release-collect.sh" --machine "$MACHINE" --target "$TARGET"
fi
# --- end release collect step

# --- begin nightly collect step (nightly-build_test.sh runs this block with a stub for docker)
if [ "${AGL_NIGHTLY:-}" = 1 ]; then
  # Same reason as the release collect step above: nightly-collect.sh must run as root, inside a container, on the sidecar's
  # Docker daemon, because this job cannot enter the cache directory itself.
  # shellcheck disable=SC2153
  engine="$ENGINE"
  nightly="${NIGHTLY_STAGING:-$(dirname "${AGL_SSTATE_DIR:?AGL_SSTATE_DIR is not set: this host has no cache directory}")/nightly}"
  docker run --rm --user 0 \
    -v "$TREE:$TREE:ro" -v "$engine:$engine:ro" -v "$nightly:$nightly" \
    -e AGL_TREE="$TREE" -e NIGHTLY_STAGING="$nightly" -e NIGHTLY_DATE -e AGL_SCOPE \
    -e NIGHTLY_RUN_ID="${GITHUB_RUN_ID:-local}" \
    --entrypoint /bin/bash "${KAS_CONTAINER_IMAGE:?KAS_CONTAINER_IMAGE is not set}" \
    "$engine/nightly-collect.sh" --machine "$MACHINE" --target "$TARGET" --repo "$AGL_SCOPE"
fi
# --- end nightly collect step

# --- Collecting the build output for the artifact upload: OFF (2026-11-18) ---------------------------------------------------------
# Why off: the images made about 232 GB of Actions storage in 18 days (chapter 13, "Build artifacts are off"). The upload step in
# .github/workflows/layer-ci.yml is off too; the two belong together. To revive both, remove the '# ' prefix of the lines below
# and of that step (the step also names the retention: 7 days for pull requests and nightlies).
#
# What the lines do, variable by variable:
#   TREE          the agl-ucb checkout of the job (AGL_TREE, set by the workflow); bitbake's build directory is $TREE/build.
#   MACHINE, TARGET   the matrix entry being built (--machine, and the image name from the matrix); they only name the directory.
#   ARTIFACT_DIR  where the output is collected, default $TREE/build/artifacts/$MACHINE-$TARGET. The upload step picks up
#                 tree/build/artifacts/**, so the directory has to be below build/artifacts. Set ARTIFACT_DIR in the environment to
#                 collect somewhere else (a local run); the upload then finds nothing.
#   DEPLOY_DIR    bitbake's deploy output, $TREE/build/tmp/deploy (DEPLOY_DIR of the kas build: TMPDIR is build/tmp).
#   images/$MACHINE   the images of the machine: wic and rootfs files, kernel, device trees, manifests. This is the large part
#                 (Flutter and Qt demo images are about 2 GB each).
#   sdk           only exists when the populate_sdk step above ran, i.e. for a matrix entry with sdk set on a release
#                 (SDK_ALLOWED=true). Copied into $ARTIFACT_DIR/sdk/.
#   '|| true'     a missing directory (no images, no SDK) is not an error; a failing copy does not fail the build job either.
#   cp -a         copies with modes and timestamps and keeps symlinks as symlinks (the deploy directory is full of them).
#
# Example, a gate of meta-agl: MACHINE=qemux86-64, TARGET=agl-image-minimal, AGL_TREE=/home/runner/work/meta-agl/meta-agl/tree
#   copies  /home/runner/work/meta-agl/meta-agl/tree/build/tmp/deploy/images/qemux86-64/.
#   into    /home/runner/work/meta-agl/meta-agl/tree/build/artifacts/qemux86-64-agl-image-minimal/
#   and the upload step publishes that directory as the workflow artifact 'meta-agl-qemux86-64-agl-image-minimal'. With
#   SDK_ALLOWED=true and a populated SDK, tmp/deploy/sdk/. lands in .../qemux86-64-agl-image-minimal/sdk/ as well.
#   (The file names inside depend on IMAGE_FSTYPES of the image, e.g. a .wic file and the kernel; they are not listed here.)
#
# ARTIFACT_DIR="${ARTIFACT_DIR:-$TREE/build/artifacts/$MACHINE-$TARGET}"
# mkdir -p "$ARTIFACT_DIR"
# DEPLOY_DIR="$TREE/build/tmp/deploy"
# [ -d "$DEPLOY_DIR/images/$MACHINE" ] && cp -a "$DEPLOY_DIR/images/$MACHINE/." "$ARTIFACT_DIR/" || true
# [ -d "$DEPLOY_DIR/sdk" ] && cp -a "$DEPLOY_DIR/sdk/." "$ARTIFACT_DIR/sdk/" || true
# echo "build.sh: artifacts in $ARTIFACT_DIR"
