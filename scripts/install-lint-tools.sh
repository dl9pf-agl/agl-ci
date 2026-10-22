#!/usr/bin/env bash
# Install the pinned lint/security tools (sha256-verified) into BIN (default ~/.local/bin). Linux x86_64.
set -euo pipefail
cd "$(dirname "$0")/.." || exit 1
. docker/pins.env
bin="${BIN:-$HOME/.local/bin}"; mkdir -p "$bin"; t="$(mktemp -d)"; trap 'rm -rf "$t"' EXIT
get() { curl -fsSL --retry 3 -o "$t/$2" "$1" && echo "$3  $t/$2" | sha256sum -c - >/dev/null; }
get "https://github.com/rhysd/actionlint/releases/download/v${ACTIONLINT_VERSION}/actionlint_${ACTIONLINT_VERSION}_linux_amd64.tar.gz" al.tgz "$ACTIONLINT_SHA256"
tar -xzf "$t/al.tgz" -C "$bin" actionlint
get "https://github.com/zizmorcore/zizmor/releases/download/v${ZIZMOR_VERSION}/zizmor-x86_64-unknown-linux-gnu.tar.gz" zz.tgz "$ZIZMOR_SHA256"
tar -xzf "$t/zz.tgz" -C "$bin" zizmor
get "https://github.com/koalaman/shellcheck/releases/download/v${SHELLCHECK_VERSION}/shellcheck-v${SHELLCHECK_VERSION}.linux.x86_64.tar.xz" sc.txz "$SHELLCHECK_SHA256"
tar -xJf "$t/sc.txz" -C "$t" && install -m 0755 "$t/shellcheck-v${SHELLCHECK_VERSION}/shellcheck" "$bin/shellcheck"
echo "installed to $bin: actionlint zizmor shellcheck"
