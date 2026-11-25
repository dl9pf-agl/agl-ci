#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Run trowl (github.com/corefense-security/trowl), a post-build security scanner for the built image, and write its report
# next to the image. Called from build.sh for nightly and release builds (AGL_TROWL=1); not yet wired into push-pr (the
# matrix entry would need `tiers: [push-pr, ...]` unchanged, build.sh has the call ready, the push-pr workflow just doesn't
# set AGL_TROWL yet - flip that on in layer-ci.yml's build job env when ready, no script change needed).
#
#   trowl-scan.sh --deploy-dir <dir> --target <target> --machine <machine>
#
# Environment:
#   TROWL_REF   the pinned release tag of ghcr.io/corefense-security/trowl; read from docker/pins.env when not set, required
#   COSIGN      cosign binary (default cosign)
#
# Flow:
#   1. pick the image's own rootfs/disk file in <deploy-dir>: the plain-named <target>-<machine>.<ext> file (same naming
#      release-collect.sh relies on), first match of a priority list of extensions trowl understands (wic beats a plain
#      filesystem image; compressed forms are accepted directly, no local decompression needed)
#   2. verify the pinned trowl image's cosign signature (keyless, trowl's own release workflow identity - see
#      trowl.dev/getting-started/docker) before running it; a third-party image we execute must not go unverified
#   3. run it against that file, writing <deploy-dir>/trowl-report/ (trowl's own default output folder name, so no
#      report/ nesting: index.html, report.json, openvex.json land directly there)
# SBOM enrichment (--sbom, --kernel-tree) is left out: no matrix entry carries the agl-create-spdx kas feature yet, so there
# is no SPDX file to pass. Add --sbom "$deploy/$target-$machine.spdx.json" here once that feature is turned on somewhere.
# Report-only by design: trowl has no --fail-on any more (removed upstream, preview.3), so a scan with findings exits 0
# anyway; the caller (build.sh) additionally never lets a non-zero exit here fail the build.
set -euo pipefail
die() { echo "trowl-scan: $*" >&2; exit 1; }

deploy=""; target=""; machine=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --deploy-dir) deploy="${2:-}"; shift 2 ;;
    --target) target="${2:-}"; shift 2 ;;
    --machine) machine="${2:-}"; shift 2 ;;
    *) die "unknown argument: $1 (usage: trowl-scan.sh --deploy-dir <dir> --target <target> --machine <machine>)" ;;
  esac
done
[ -d "$deploy" ] || die "no deploy directory: $deploy"
[[ "$target" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "bad or missing --target: '$target'"
[[ "$machine" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "bad or missing --machine: '$machine'"

# The pin lives in docker/pins.env, the one file of agl-ci's tool versions. No workflow puts it into the environment of a build job
# (the release and nightly builds ran without it and this script stopped at the first line below), so read it here unless the caller
# already set it. AGL_PINS_ENV points to another file (the tests use it to simulate a missing pin).
here="$(cd "$(dirname "$0")" && pwd)"
pins="${AGL_PINS_ENV:-$here/../../docker/pins.env}"
# shellcheck source=../../docker/pins.env disable=SC1091
[ -n "${TROWL_REF:-}" ] || [ ! -f "$pins" ] || . "$pins"
ref="${TROWL_REF:?TROWL_REF is not set (docker/pins.env)}"
cosign="${COSIGN:-cosign}"
image="ghcr.io/corefense-security/trowl"

# 1. Pick the rootfs/disk file.
rootfs=""
for ext in wic wic.xz wic.zst wic.gz wic.bz2 \
           ext4 ext4.xz ext4.zst ext4.gz ext4.bz2 \
           squashfs squashfs.xz squashfs.zst \
           tar.xz tar.zst tar.gz tar.bz2 \
           cpio.xz cpio.zst cpio.gz; do
  f="$deploy/$target-$machine.$ext"
  [ -f "$f" ] || continue
  rootfs="$f"; break
done
[ -n "$rootfs" ] || die "no $target-$machine.<wic|ext4|squashfs|tar|cpio>[.compression] in $deploy"

# 2. Verify the pinned image before running it.
digest="$(docker buildx imagetools inspect "$image:$ref" --format '{{.Manifest.Digest}}')" || die "could not inspect $image:$ref"
"$cosign" verify "$image@$digest" \
  --certificate-identity "https://github.com/corefense-security/trowl/.github/workflows/build-release-trowl.yml@refs/tags/$ref" \
  --certificate-oidc-issuer "https://token.actions.githubusercontent.com" >/dev/null \
  || die "cosign verify of $image@$digest failed"

# 3. Scan. The report folder is created fresh by trowl itself (it writes index.html/report.json/openvex.json there); an
#    existing trowl-report/ from an earlier run in the same workspace is left for trowl to overwrite file by file, never
#    removed by this script.
report="$deploy/trowl-report"
docker run --rm -v "$deploy:$deploy" "$image@$digest" scan "$rootfs" -o "$report"
echo "trowl-scan: report written to $report"
