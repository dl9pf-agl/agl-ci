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
# shellcheck disable=SC2046
KAS_TARGET="$TARGET" kas_run build "$KASFILES"

if [ "$ENTRY_SDK" = "True" ] && [ "$SDK_ALLOWED" = "true" ]; then
  echo "build.sh: populating SDK for $TARGET"
  # shellcheck disable=SC2046
  kas_run shell "$KASFILES" -c "bitbake -c populate_sdk $TARGET"
fi

ARTIFACT_DIR="${ARTIFACT_DIR:-$TREE/build/artifacts/$MACHINE-$TARGET}"
mkdir -p "$ARTIFACT_DIR"
DEPLOY_DIR="$TREE/build/tmp/deploy"
[ -d "$DEPLOY_DIR/images/$MACHINE" ] && cp -a "$DEPLOY_DIR/images/$MACHINE/." "$ARTIFACT_DIR/" || true
[ -d "$DEPLOY_DIR/sdk" ] && cp -a "$DEPLOY_DIR/sdk/." "$ARTIFACT_DIR/sdk/" || true
echo "build.sh: artifacts in $ARTIFACT_DIR"
