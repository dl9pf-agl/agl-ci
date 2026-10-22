#!/usr/bin/env bash
# Install syft (sha256-pinned) into BIN (default ~/.local/bin). cosign comes from the workflow's pinned installer.
set -euo pipefail
cd "$(dirname "$0")/.." || exit 1
. docker/pins.env
bin="${BIN:-$HOME/.local/bin}"; mkdir -p "$bin"; t="$(mktemp -d)"; trap 'rm -rf "$t"' EXIT
curl -fsSL --retry 3 -o "$t/s.tgz" "https://github.com/anchore/syft/releases/download/v${SYFT_VERSION}/syft_${SYFT_VERSION}_linux_amd64.tar.gz"
echo "${SYFT_SHA256}  $t/s.tgz" | sha256sum -c - >/dev/null
tar -xzf "$t/s.tgz" -C "$bin" syft
