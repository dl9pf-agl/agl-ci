#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Test of trowl-scan.sh with stub `docker` and `cosign` on PATH (no real image pull, no real scan, no network).
# Run: ci/scripts/trowl-scan_test.sh      The temporary directory it makes is left in place (path printed); remove it yourself.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
tool="$here/trowl-scan.sh"
t="$(mktemp -d "${TMPDIR:-/tmp}/trowl-scan-test.XXXXXX")"
echo "test directory: $t"
fails=0
ok() { echo "ok:   $*"; }
bad() { echo "FAIL: $*"; fails=$((fails + 1)); }

M=qemux86-64
# stubbin NAME: a fake PATH entry with executable `docker` and `cosign`, each echoing what they were called with.
#   docker buildx imagetools inspect ... --format ...   -> prints a fake digest line
#   docker run ...                                        -> just reports the call (the "scan")
#   cosign verify ...                                      -> succeeds unless COSIGN_FAIL is set in the environment
stubbin() {
  local d="$t/$1/bin"; mkdir -p "$d"
  cat > "$d/docker" <<'SH'
#!/usr/bin/env bash
case "$1 $2 $3" in
  "buildx imagetools inspect") echo "sha256:fakedigest0000000000000000000000000000000000000000000000000000"; exit 0 ;;
  *) echo "DOCKER $*"; exit 0 ;;
esac
SH
  cat > "$d/cosign" <<'SH'
#!/usr/bin/env bash
echo "COSIGN $*" >&2
[ -z "${COSIGN_FAIL:-}" ] || exit 1
exit 0
SH
  chmod +x "$d/docker" "$d/cosign"
  echo "$d"
}
run() {   # run NAME [extra env assignments...] -- args...
  local n="$1"; shift
  local bin; bin="$(stubbin "$n")"
  env PATH="$bin:$PATH" TROWL_REF=v0.1.0-preview.5 "$@" "$tool" --deploy-dir "$t/$n/deploy" --target img --machine "$M" 2>&1
}

# 1. No deploy directory at all: refused before anything else.
out="$(TROWL_REF=v0.1.0-preview.5 "$tool" --deploy-dir "$t/missing" --target img --machine "$M" 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && echo "$out" | grep -q 'no deploy directory'; then ok "a missing deploy directory is refused"; else bad "missing deploy directory accepted: $out"; fi

# 2. A deploy directory with no matching rootfs file: refused, names the expected pattern.
mkdir -p "$t/none/deploy"
out="$(run none)"; rc=$?
if [ "$rc" -ne 0 ] && echo "$out" | grep -q 'no img-qemux86-64'; then ok "no rootfs file is refused"; else bad "missing rootfs accepted: $out"; fi

# 3. A plain ext4.xz file: picked up, cosign verify runs, docker run (the scan) is issued with -o <deploy>/trowl-report.
mkdir -p "$t/ext4/deploy"; echo rootfs > "$t/ext4/deploy/img-$M.ext4.xz"
out="$(run ext4)"; rc=$?
if [ "$rc" -eq 0 ]; then ok "a scan with a matching rootfs file succeeds"; else bad "scan failed: $out"; fi
if echo "$out" | grep -q "COSIGN verify ghcr.io/corefense-security/trowl@sha256:fakedigest"; then ok "cosign verify runs against the inspected digest"; else bad "cosign verify missing: $out"; fi
if echo "$out" | grep -q "DOCKER run --rm -v $t/ext4/deploy:$t/ext4/deploy ghcr.io/corefense-security/trowl@sha256:fakedigest.* scan $t/ext4/deploy/img-$M.ext4.xz -o $t/ext4/deploy/trowl-report"; then
  ok "trowl runs on the right file, writing trowl-report next to it"
else bad "scan call wrong: $out"; fi

# 4. Priority: both a .wic and an .ext4.xz exist - wic wins (first match in the extension list).
mkdir -p "$t/prio/deploy"; echo rootfs > "$t/prio/deploy/img-$M.ext4.xz"; echo rootfs > "$t/prio/deploy/img-$M.wic"
out="$(run prio)"
if echo "$out" | grep -q "scan $t/prio/deploy/img-$M.wic "; then ok "a .wic file is preferred over .ext4.xz"; else bad "wrong file picked: $out"; fi

# 5. cosign verify fails: the scan must not run, and the script exits non-zero.
mkdir -p "$t/badsig/deploy"; echo rootfs > "$t/badsig/deploy/img-$M.ext4.xz"
out="$(run badsig COSIGN_FAIL=1)"; rc=$?
if [ "$rc" -ne 0 ] && echo "$out" | grep -q 'cosign verify .* failed'; then ok "a failed cosign verify is refused"; else bad "failed verify accepted: $out"; fi
if ! echo "$out" | grep -q '^DOCKER run'; then ok "the scan does not run when verify fails"; else bad "scan ran despite a failed verify: $out"; fi

# 6. Bad names/missing env are refused.
out="$(TROWL_REF=v0.1.0-preview.5 "$tool" --deploy-dir "$t/ext4/deploy" --target '../x' --machine "$M" 2>&1)"; rc=$?
if [ "$rc" -ne 0 ]; then ok "a path in --target is refused"; else bad "path in --target accepted"; fi
out="$("$tool" --deploy-dir "$t/ext4/deploy" --target img --machine "$M" 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && echo "$out" | grep -q 'TROWL_REF is not set'; then ok "a missing TROWL_REF is refused"; else bad "missing TROWL_REF accepted: $out"; fi

if [ "$fails" -eq 0 ]; then echo "all tests passed"; else echo "$fails test(s) failed"; exit 1; fi
