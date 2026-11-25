#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Run VulnScout (github.com/savoirfairelinux/meta-vulnscout) against the SPDX file the build already produced
# (kas/local/vulnscout-sbom.yml, AGL_VULNSCOUT=1: INHERIT += "create-spdx", no docker inside the build), and write its
# report next to the image. Deliberately NOT a `bitbake -c vulnscout_ci` call: that task calls docker itself, from
# inside the bitbake task, which would hand the untrusted build environment access to the privileged sidecar Docker
# daemon only the trusted runner is meant to reach (manual chapter 05) - this script runs in the runner instead, same
# arrangement as the other CI steps that need docker, and talks to VulnScout's container directly, one-shot, without bitbake's long-running
# named container.
#
#   vulnscout-scan.sh --deploy-dir <dir> --target <target> --machine <machine>
#
# Environment:
#   VULNSCOUT_IMAGE            the pinned image@digest of ghcr.io/sflinux/vulnscout; read from docker/pins.env when not set, required
#   VULNSCOUT_MATCH_CONDITION  the severity bar passed to VulnScout's own --match-condition (default "cvss >= 11":
#                               CVSS caps at 10.0, so this never matches - the scan still runs and writes every report)
#
# Flow:
#   1. find the SPDX file create-spdx wrote: <deploy-dir>/<target>-<machine>.spdx.json
#   2. run the pinned VulnScout image once, non-interactively, against that file, with every built-in report template
#      and the match condition, writing <deploy-dir>/report-vulnscout/ (mounted at the container's fixed /scan/outputs)
# No cosign verify: sflinux/vulnscout is a plain Docker Hub image, no keyless-signing identity to check (docker/pins.env
# explains why digest-pin alone is the accepted trust level here, same as DIND_IMAGE).
# Report-only by design: a match or a tool failure here is for the caller to decide about. The workflow step `scan (vulnscout)`
# has continue-on-error: true, so nothing here fails a build; this script just reports its real exit code.
set -euo pipefail
die() { echo "vulnscout-scan: $*" >&2; exit 1; }

deploy=""; target=""; machine=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --deploy-dir) deploy="${2:-}"; shift 2 ;;
    --target) target="${2:-}"; shift 2 ;;
    --machine) machine="${2:-}"; shift 2 ;;
    *) die "unknown argument: $1 (usage: vulnscout-scan.sh --deploy-dir <dir> --target <target> --machine <machine>)" ;;
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
[ -n "${VULNSCOUT_IMAGE:-}" ] || [ ! -f "$pins" ] || . "$pins"
image="${VULNSCOUT_IMAGE:?VULNSCOUT_IMAGE is not set (docker/pins.env)}"
condition="${VULNSCOUT_MATCH_CONDITION:-cvss >= 11}"

# 1. The SPDX file create-spdx wrote (plain name, same convention release-collect.sh relies on).
spdx="$deploy/$target-$machine.spdx.json"
[ -f "$spdx" ] || die "no $target-$machine.spdx.json in $deploy (enable create-spdx for this image: kas/local/vulnscout-sbom.yml)"

# 2. Scan. All six built-in report templates (no custom template folder, so --report <name> resolves inside the
#    container); outputs mounted at the container's fixed /scan/outputs, never removed, VulnScout overwrites in place.
report="$deploy/report-vulnscout"
mkdir -p "$report"
reports=(all_assessments.adoc match_condition.adoc summary.adoc time_estimate.csv vulnerabilities.csv vulnerability_summary.txt)
report_args=()
for r in "${reports[@]}"; do report_args+=(--report "$r"); done
# The image's ENTRYPOINT is /scan/src/entrypoint.sh, so the arguments below go to it directly. Writing the path here again made the
# script run `entrypoint.sh /scan/src/entrypoint.sh ...` and stop with "Unknown command" (nightly test, 2026-11-25).
docker run --rm -v "$deploy:$deploy:ro" -v "$report:/scan/outputs" "$image" \
  --project agl --variant "$target-$machine" --add-spdx "$spdx" \
  --match-condition "$condition" "${report_args[@]}"
echo "vulnscout-scan: report written to $report"
