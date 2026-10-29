#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Full layer QA suite: bitbake world-parse, yocto-check-layer, license/patch checks, lint.
# Each sub-check logs separately to $RESULTS_DIR for the PR/MR summary step.
#   validate.sh --machine M --features F --target T [--verbose]
# --verbose: print the configuration, show every check's output live in a collapsible log group together with its command and
# duration (so yocto-check-layer prints all its own output into the job log), annotate failures, repeat the last lines of a failed
# check outside its group and end with a summary table. Without it only "running/PASSED/FAILED" lines are printed and the output goes to the log files only.
# The job log of a public repository is public: addresses are shown as "set"/"unset".
set -uo pipefail  # not -e: run every check, collect all results, report at the end

# shellcheck source=./_kas_runtime_args.sh
# shellcheck source=./_kas_runtime_args.sh disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/_kas_runtime_args.sh"
cd "$TREE" || exit 1

verbose=0; _args=()
for _a in "$@"; do if [ "$_a" = --verbose ]; then verbose=1; else _args+=("$_a"); fi; done
parse_common_args "${_args[@]}"

matrix_fields kasfiles,target
KASFILES="${_MATRIX_FIELDS[0]}$(kas_extra_includes)$(kas_ci_includes)"
MATRIX_ENTRY_TARGET="${_MATRIX_FIELDS[1]}"
RESULTS_DIR="${RESULTS_DIR:-$TREE/build/validate-results}"
mkdir -p "$RESULTS_DIR"

status=0; summary=()
if [ "$verbose" = 1 ]; then
  echo "validate.sh: verbose: machine=$MACHINE features=$FEATURES target=$MATRIX_TARGET kas_exec=${KAS_EXEC:-kas-container}"
  echo "validate.sh: verbose: tree=$TREE results=$RESULTS_DIR python=$PY"
  echo "validate.sh: verbose: kasfiles=$KASFILES"
  _su() { if [ -n "${!1:-}" ]; then echo set; else echo unset; fi; }   # never print the value
  echo "validate.sh: verbose: sstate=${AGL_SSTATE_DIR:-unset} dl=${AGL_DL_DIR:-unset} mirror=$(_su AGL_MIRROR_URL) git_mirror=${AGL_GIT_MIRROR:-unset}" \
       "hashserv_rw=$(_su AGL_HASHSERV_RW) hashserv_upstream=$(_su AGL_HASHSERV_UPSTREAM)"
fi
# --- begin check helper (kept in step with ci/scripts/validate_test.sh, which runs this block)
# Runs "$@" as the check named $1, logs to $RESULTS_DIR/$name.log, and records PASSED/FAILED.
run_host_check() {
  local name="$1" t0 rc log; shift; log="$RESULTS_DIR/$name.log"; t0=$(date +%s)
  echo "validate.sh: running $name"
  if [ "$verbose" = 1 ]; then
    echo "::group::validate.sh: $name"; echo "validate.sh: command: $*"
    "$@" 2>&1 | tee "$log"; rc=${PIPESTATUS[0]}
    echo "::endgroup::"
  else
    "$@" >"$log" 2>&1; rc=$?
  fi
  summary+=("$(printf '%-20s %-7s %4ss' "$name" "$([ "$rc" = 0 ] && echo PASSED || echo FAILED)" "$(($(date +%s) - t0))")")
  if [ "$rc" = 0 ]; then
    echo "validate.sh: $name PASSED"
  else
    echo "validate.sh: $name FAILED (see $log)"
    if [ "$verbose" = 1 ]; then   # the group above is collapsed in the GitHub UI: show the end of it where it is seen
      echo "::error title=validate.sh $name::$name FAILED, output above (group validate.sh: $name)"
      echo "validate.sh: last 40 lines of $name:"; tail -n 40 "$log"
    fi
    status=1
  fi
}
# --- end check helper

# In-container check: same PASSED/FAILED bookkeeping as run_host_check, just run inside
# kas-container instead of directly on the host.
run_check() {
  local name="$1" kasfiles="$2"; shift 2
  # shellcheck disable=SC2046
  run_host_check "$name" kas_run shell "$kasfiles" -c "$*"
}

run_host_check "matrix-validate" "$PY" "$ENGINE/_matrix.py"

run_check "bitbake-parse" "$KASFILES" "bitbake -p"

# yocto-check-layer needs actual bitbake layer roots (dirs with their own conf/layer.conf) -
# ci/build-matrix.yaml's check_layers.layers names them exactly, so CHECK_LAYERS entries are
# used directly, no more searching for them. Paths are hardcoded to /work (kas-container's
# fixed mount point for the repo root - $KAS_WORK_DIR is NOT propagated into the
# bitbake-sourced shell env, confirmed empty there) since `kas shell -c` runs from
# /work/build, not the repo root. Runs against the bare _validate-base combo (no AGL layers
# pre-loaded) since yocto-check-layer manages its own layer-under-test additions and errors
# on duplicate BBFILE_COLLECTIONS otherwise.
#
# CHECK_LAYERS (space-separated paths matching ci/build-matrix.yaml's check_layers.layers;
# set via `make validate CHECK_LAYERS="..."` - see Makefile) defaults to just meta-agl-core:
# checking every vendored sublayer is slow and most of them aren't what's actively being
# changed here. `CHECK_LAYERS=all` checks every curated layer. Each layer's dependencies
# (yocto-check-layer's --dependency/--additional-layers) come from
# ci/build-matrix.yaml's check_layers: key via _matrix.py - add a newly-vendored layer's
# dependency info there, not here.
# check_layers.default of a repo in scope adds its layers to the default; none does today (the layers of meta-agl-demo and
# meta-agl-devel are prepared but not yet checked by default, agl-ci chapter 13).
CHECK_LAYERS="${CHECK_LAYERS:-meta-agl/meta-agl-core $("$PY" "$ENGINE/_matrix.py" --default-check-layers | tr '\n' ' ')}"
if [ "$CHECK_LAYERS" = "all" ]; then
  CHECK_LAYERS="$("$PY" "$ENGINE/_matrix.py" --list-check-layers | tr '\n' ' ')"
fi
# shellcheck disable=SC2086
CHECK_LAYER_ARGS="$("$PY" "$ENGINE/_matrix.py" --check-layer-args $CHECK_LAYERS)"
CHECK_LAYER_PATHS=""
for l in $CHECK_LAYERS; do
  CHECK_LAYER_PATHS="$CHECK_LAYER_PATHS $AGL_WORKDIR/$l"
done
# dl-shared: this is the first bitbake run of a job, so it fetches the uninative tarball; without the shared
# downloads it lands in the throw-away build/downloads and never reaches the cache.
run_check "yocto-check-layer" "build/ci-kas/_validate-base.yml:kas/pins.yml$(kas_dl_include)" \
  "yocto-check-layer$CHECK_LAYER_PATHS $CHECK_LAYER_ARGS"

run_check "license-manifest" "$KASFILES" \
  "bitbake -e $MATRIX_ENTRY_TARGET | grep -E '^LICENSE='"

# patchtest needs the separate patchtest-oe metadata/results-parser wired up against a
# concrete PR diff range - not yet set up (TODO, see WIP.md deferred items). Skipped for
# now rather than faked as passing.
if [ "${SKIP_PATCHTEST:-1}" != "1" ]; then
  run_check "patchtest" "$KASFILES" "patchtest --repo meta-agl --base-ref ${PATCHTEST_BASE_REF:-HEAD~20}"
fi

# /usr/local/bin (where pip --break-system-packages installs system-wide) is pruned from
# PATH once bitbake's build environment is sourced (only /usr/{,s}bin and /{,s}bin survive)
# - call oelint-adv by absolute path rather than relying on PATH resolution.
LINT_PATHS=""
for r in $("$PY" "$ENGINE/_matrix.py" --repos); do LINT_PATHS="$LINT_PATHS $AGL_WORKDIR/$r"; done
run_check "recipe-lint" "$KASFILES" "/usr/local/bin/oelint-adv$LINT_PATHS"

if [ "$verbose" = 1 ]; then echo "validate.sh: summary"; printf '  %s\n' "${summary[@]}"; fi
exit $status
