#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Test of kas_checkout() of _kas_runtime_args.sh: the checkout falls back to the original URLs when the git mirror cannot serve it.
# kas_run is a stub that fails while the mirror is on (KAS_PREMIRRORS set) and works without it; no kas, no network.
# Run: ci/scripts/kas-checkout_test.sh      (it makes no files)
# shellcheck disable=SC2016  # intentional: the stub script is single-quoted, the block is spliced in
set -uo pipefail
f="${1:-$(dirname "$0")/_kas_runtime_args.sh}"
blk="$(sed -n '/^# --- begin kas_checkout/,/^# --- end kas_checkout/p' "$f")"
[ -n "$blk" ] || { echo "FAIL: the marker comments of kas_checkout are missing in $f" >&2; exit 1; }
fails=0
ok() { echo "ok:   $*"; }
bad() { echo "FAIL: $*"; fails=$((fails + 1)); }

# run [VAR=value ...]: run kas_checkout in a clean environment with the stub; prints one CALL line per kas_run call
# (mirror=yes when KAS_PREMIRRORS was set) and the warning; STUB_FAIL=always makes every call fail, STUB_FAIL=mirror only the mirrored one.
run() {
  env -i PATH="$PATH" "$@" bash -c '
    kas_run() {
      printf "CALL %s mirror=%s\n" "$*" "$([ -n "${KAS_PREMIRRORS:-}" ] && echo yes || echo no)"
      case "${STUB_FAIL:-}" in always) return 1 ;; mirror) [ -z "${KAS_PREMIRRORS:-}" ] || return 1 ;; esac
    }
    '"$blk"'
    kas_checkout "kas/base.yml:kas/pins.yml"
    echo "rc=$?"
  ' 2>&1
}

# 1. No mirror, success: one call, no warning.
out="$(run)"
if [ "$out" = $'CALL checkout kas/base.yml:kas/pins.yml mirror=no\nrc=0' ]; then ok "without the mirror: one checkout"; else bad "no mirror: $out"; fi

# 2. Mirror on and working: one call, no warning.
out="$(run AGL_GIT_MIRROR=1 KAS_PREMIRRORS=x)"
if [ "$out" = $'CALL checkout kas/base.yml:kas/pins.yml mirror=yes\nrc=0' ]; then ok "with a working mirror: one checkout, no warning"; else bad "working mirror: $out"; fi

# 3. Mirror on, the mirrored checkout fails: a warning, then the same checkout without the mirror, which works.
out="$(run AGL_GIT_MIRROR=1 KAS_PREMIRRORS=x STUB_FAIL=mirror)"
if grep -q '^::warning title=git mirror miss' <<<"$out" && grep -q 'mirror=yes' <<<"$out" && grep -q 'mirror=no' <<<"$out" && grep -q '^rc=0$' <<<"$out"; then
  ok "a mirror miss: warning, second checkout without the mirror, success"
else bad "mirror miss not handled: $out"; fi

# 4. Both fail: the failure is reported (rc=1), after exactly two calls.
out="$(run AGL_GIT_MIRROR=1 KAS_PREMIRRORS=x STUB_FAIL=always)"
if [ "$(grep -c '^CALL' <<<"$out")" = 2 ] && grep -q '^rc=1$' <<<"$out"; then ok "a failure without the mirror too is reported, after two tries"; else bad "double failure: $out"; fi

# 5. No mirror and a failure: one call only, rc=1 (nothing to fall back to).
out="$(run STUB_FAIL=always)"
if [ "$(grep -c '^CALL' <<<"$out")" = 1 ] && grep -q '^rc=1$' <<<"$out"; then ok "without the mirror a failure is not retried"; else bad "no-mirror failure: $out"; fi

if [ "$fails" -eq 0 ]; then echo "all tests passed"; else echo "$fails test(s) failed"; exit 1; fi
