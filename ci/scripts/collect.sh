#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Collect the files of a built matrix entry on the builder: the release files (AGL_RELEASE=1, release-collect.sh) and the nightly
# files (AGL_NIGHTLY=1, nightly-collect.sh). The step after build.sh and the scan step in the workflows, so that the reports of the
# scan steps (report-trowl/, report-vulnscout/ below tmp/deploy/images/<machine>/) are in the deploy directory when it runs.
#
#   collect.sh --machine <m> --features <f> --target <t>      (the same arguments as build.sh)
#
# Flow, in the order it runs:
#   1. read the matrix entry (machine, target) the same way build.sh does
#   2. release collect step   (AGL_RELEASE=1)   docker run of release-collect.sh as root on the sidecar's Docker daemon
#   3. nightly collect step   (AGL_NIGHTLY=1)   docker run of nightly-collect.sh, same reason
# Without AGL_RELEASE and AGL_NIGHTLY it does nothing. A failure fails the job, like it did inside build.sh.
set -euo pipefail

# shellcheck source=./_kas_runtime_args.sh disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/_kas_runtime_args.sh"
cd "$TREE" || exit 1

parse_common_args "$@"

# 1. The matrix entry: only the target is needed here (MACHINE comes from parse_common_args).
matrix_fields target
TARGET="${_MATRIX_FIELDS[0]}"

# --- begin release collect step (release-build_test.sh runs this block with a stub for docker)
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
  # --repo: the repository that owns the image (NIGHTLY_REPO, the matrix entry's repo). The nightly of meta-agl builds the images of meta-agl,
  # meta-agl-demo and meta-agl-devel; with the calling repo (AGL_SCOPE) for all of them, two images of one machine met in one folder and
  # the shared kernel files disagreed (first scheduled nightly, 2026-11-26). AGL_SCOPE stays the fallback for a run without the variable.
  # shellcheck disable=SC2153
  engine="$ENGINE"
  nightly="${NIGHTLY_STAGING:-$(dirname "${AGL_SSTATE_DIR:?AGL_SSTATE_DIR is not set: this host has no cache directory}")/nightly}"
  docker run --rm --user 0 \
    -v "$TREE:$TREE:ro" -v "$engine:$engine:ro" -v "$nightly:$nightly" \
    -e AGL_TREE="$TREE" -e NIGHTLY_STAGING="$nightly" -e NIGHTLY_DATE -e AGL_SCOPE \
    -e NIGHTLY_RUN_ID="${GITHUB_RUN_ID:-local}" \
    --entrypoint /bin/bash "${KAS_CONTAINER_IMAGE:?KAS_CONTAINER_IMAGE is not set}" \
    "$engine/nightly-collect.sh" --machine "$MACHINE" --target "$TARGET" --repo "${NIGHTLY_REPO:-$AGL_SCOPE}"
fi
# --- end nightly collect step
