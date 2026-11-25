#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Test of vulnscout-scan.sh with a stub `docker` on PATH (no real image pull, no real scan, no network).
# Run: ci/scripts/vulnscout-scan_test.sh      The temporary directory it makes is left in place (path printed); remove it yourself.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
tool="$here/vulnscout-scan.sh"
t="$(mktemp -d "${TMPDIR:-/tmp}/vulnscout-scan-test.XXXXXX")"
echo "test directory: $t"
fails=0
ok() { echo "ok:   $*"; }
bad() { echo "FAIL: $*"; fails=$((fails + 1)); }

M=qemux86-64
# stubbin NAME: a fake PATH entry with an executable `docker` that echoes what it was called with.
stubbin() {
  local d="$t/$1/bin"; mkdir -p "$d"
  cat > "$d/docker" <<'SH'
#!/usr/bin/env bash
echo "DOCKER $*"
[ -z "${DOCKER_RUN_FAIL:-}" ] || exit 1
SH
  chmod +x "$d/docker"
  echo "$d"
}
run() {   # run NAME [extra env assignments...]
  local n="$1"; shift
  local bin; bin="$(stubbin "$n")"
  env PATH="$bin:$PATH" VULNSCOUT_IMAGE=sflinux/vulnscout@sha256:fake "$@" \
    "$tool" --deploy-dir "$t/$n/deploy" --target img --machine "$M" 2>&1
}

# 1. No deploy directory at all: refused before anything else.
out="$(VULNSCOUT_IMAGE=sflinux/vulnscout@sha256:fake "$tool" --deploy-dir "$t/missing" --target img --machine "$M" 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && echo "$out" | grep -q 'no deploy directory'; then ok "a missing deploy directory is refused"; else bad "missing deploy directory accepted: $out"; fi

# 2. A deploy directory with no SPDX file: refused, names the expected file.
mkdir -p "$t/none/deploy"
out="$(run none)"; rc=$?
if [ "$rc" -ne 0 ] && echo "$out" | grep -q 'no img-qemux86-64.spdx.json'; then ok "a missing SPDX file is refused"; else bad "missing SPDX file accepted: $out"; fi

# 3. A real SPDX file: the scan runs, mounts and arguments are right, report dir is created.
mkdir -p "$t/ok/deploy"; echo '{"spdx":1}' > "$t/ok/deploy/img-$M.spdx.json"
out="$(run ok)"; rc=$?
if [ "$rc" -eq 0 ]; then ok "a scan with a real SPDX file succeeds"; else bad "scan failed: $out"; fi
if [ -d "$t/ok/deploy/vulnscout-report" ]; then ok "the report directory is created"; else bad "report directory missing"; fi
if echo "$out" | grep -q -- "DOCKER run --rm -v $t/ok/deploy:$t/ok/deploy:ro -v $t/ok/deploy/vulnscout-report:/scan/outputs sflinux/vulnscout@sha256:fake /scan/src/entrypoint.sh --project agl --variant img-$M --add-spdx $t/ok/deploy/img-$M.spdx.json --match-condition cvss >= 11"; then
  ok "docker run has the mounts, the SPDX file and the default match condition"
else bad "wrong docker call: $out"; fi
if echo "$out" | grep -q -- '--report all_assessments.adoc' && echo "$out" | grep -q -- '--report vulnerability_summary.txt'; then
  ok "every built-in report template is requested"
else bad "report templates missing: $out"; fi

# 4. A custom VULNSCOUT_MATCH_CONDITION is passed through verbatim.
out="$(run cond VULNSCOUT_MATCH_CONDITION="cvss >= 9.0 and affected == true")"
mkdir -p "$t/cond/deploy"; echo '{"spdx":1}' > "$t/cond/deploy/img-$M.spdx.json"
out="$(run cond VULNSCOUT_MATCH_CONDITION="cvss >= 9.0 and affected == true")"
if echo "$out" | grep -q -- '--match-condition cvss >= 9.0 and affected == true'; then ok "a custom match condition is passed through"; else bad "custom match condition lost: $out"; fi

# 5. docker fails: the script's own exit code reflects it (report-only is build.sh's decision, not this script's).
mkdir -p "$t/fail/deploy"; echo '{"spdx":1}' > "$t/fail/deploy/img-$M.spdx.json"
out="$(run fail DOCKER_RUN_FAIL=1)"; rc=$?
if [ "$rc" -ne 0 ]; then ok "a docker failure makes the script exit non-zero"; else bad "docker failure not propagated: $out"; fi

# 6. Missing env / bad names.
out="$(AGL_PINS_ENV=/dev/null "$tool" --deploy-dir "$t/ok/deploy" --target img --machine "$M" 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && echo "$out" | grep -q 'VULNSCOUT_IMAGE is not set'; then ok "a missing VULNSCOUT_IMAGE is refused"; else bad "missing VULNSCOUT_IMAGE accepted: $out"; fi
out="$(VULNSCOUT_IMAGE=x "$tool" --deploy-dir "$t/ok/deploy" --target '../x' --machine "$M" 2>&1)"; rc=$?
if [ "$rc" -ne 0 ]; then ok "a path in --target is refused"; else bad "path in --target accepted"; fi

# 7. Not set by the caller: the image is read from docker/pins.env (the case of the release and nightly builds, which set nothing).
printf 'VULNSCOUT_IMAGE=sflinux/vulnscout@sha256:fromfile\n' > "$t/pins.env"
bin="$(stubbin ok)"
out="$(env -u VULNSCOUT_IMAGE PATH="$bin:$PATH" AGL_PINS_ENV="$t/pins.env" "$tool" --deploy-dir "$t/ok/deploy" --target img --machine "$M" 2>&1)"
if echo "$out" | grep -q 'sha256:fromfile'; then ok "the image is read from the pins file when the environment has none"; else bad "pins file not used: $out"; fi
out="$(env -u VULNSCOUT_IMAGE PATH="$bin:$PATH" "$tool" --deploy-dir "$t/ok/deploy" --target img --machine "$M" 2>&1)"
if echo "$out" | grep -q 'VULNSCOUT_IMAGE is not set'; then bad "the docker/pins.env of this checkout was not read: $out"; else ok "the docker/pins.env of this checkout provides VULNSCOUT_IMAGE"; fi

if [ "$fails" -eq 0 ]; then echo "all tests passed"; else echo "$fails test(s) failed"; exit 1; fi
