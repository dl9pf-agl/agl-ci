#!/usr/bin/env bash
# Sign an image digest keyless and attach SBOM + SLSA provenance, all with cosign.
# Usage: sign-image.sh IMAGE@sha256:... ARCHIVE.tar
# Provenance inputs come from the forge adapter (workflow) via env, so this script stays forge-independent:
#   BUILDER_ID    URL identifying the builder/workflow (e.g. https://github.com/OWNER/REPO/.github/workflows/images.yml@REF)
#   SOURCE_URI    git URL of the source        SOURCE_COMMIT  commit sha
#   RUN_URL       URL of this run
# Needs: cosign (pins.env COSIGN_RELEASE), syft (SYFT_VERSION), an OIDC identity for keyless signing.
set -euo pipefail
cd "$(dirname "$0")/.." || exit 1
ref="${1:?image@digest}"; archive="${2:?archive}"
: "${BUILDER_ID:?}" "${SOURCE_URI:?}" "${SOURCE_COMMIT:?}" "${RUN_URL:?}"
. docker/pins.env
export COSIGN_YES=true
w="$(mktemp -d)"; trap 'rm -rf "$w"' EXIT

syft "oci-archive:$archive" -o spdx-json="$w/sbom.spdx.json" -q
python3 -I - "$w/prov.json" "$BUILDER_ID" "$SOURCE_URI" "$SOURCE_COMMIT" "$RUN_URL" docker/pins.env <<'PY'
import json, sys
out, builder, uri, commit, run, pins = sys.argv[1:7]
pinned = dict(l.strip().split("=", 1) for l in open(pins) if "=" in l and not l.startswith("#"))
json.dump({
    "buildDefinition": {
        "buildType": "agl-ci/image-build/v1",
        "externalParameters": {"source": uri, "commit": commit},
        "internalParameters": {"pins": pinned},
        "resolvedDependencies": [{"uri": "git+" + uri, "digest": {"gitCommit": commit}}],
    },
    "runDetails": {"builder": {"id": builder}, "metadata": {"invocationId": run}},
}, open(out, "w"))
PY

cosign sign "$ref"
cosign attest --type spdxjson --predicate "$w/sbom.spdx.json" "$ref"
cosign attest --type slsaprovenance1 --predicate "$w/prov.json" "$ref"
