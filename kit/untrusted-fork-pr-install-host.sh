#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# shellcheck disable=SC2329  # the have_ and make_ functions are called by step() of host-lib.sh
# UNTRUSTED build host (label agl-fork: pull requests from forks): bring a new or an existing host to the state of this checkout.
# Safe to run again; slots with a job are not restarted (agl-ci chapter 05, "Host scripts").
#
#   sudo kit/untrusted-fork-pr-install-host.sh --check              report only, change nothing
#   sudo kit/untrusted-fork-pr-install-host.sh --run [token-file]   apply
#
# A new host takes its settings from the environment (the variables of kit/deploy.sh), for example
#   sudo SLOTS=1 MIRROR_URL=https://mirror.example.org HASHSERV_UPSTREAM=<server>:9494 \
#        kit/untrusted-fork-pr-install-host.sh --run <token-file>
# An existing host keeps what it has; give a variable to change it. More: NODE_TUNING=1, SIDECAR_RUNTIME=sysbox-runc.
#
# Flow, in the order it runs:
#   1. update the checkout; refuse a host of another role, a read-write hash server and an rsync daemon (fork code must not
#      reach the cache that others use)
#   2. packages, Docker, SCTP block, optional tuning and Sysbox, runner kit (deploy.sh), restart of idle slots
#   3. report what a person has to look at
set -euo pipefail
# shellcheck source-path=SCRIPTDIR source=host-lib.sh
. "$(dirname "$(readlink -f "$0")")/host-lib.sh"
# shellcheck disable=SC2034  # read by host-lib.sh
PACKAGES="curl jq ca-certificates git"
pool=untrusted

host_init "$@"
update_checkout
guard_build_host "$pool"
[ -z "$(val HASHSERV_RW)" ] || die "an untrusted host never gets HASHSERV_RW (write access to the shared hash server)"
if docker inspect agl-rsyncd >/dev/null 2>&1; then die "an rsync daemon runs here: an untrusted host never offers its cache to others"; fi
[ ! -f "$R/etc/cron.d/agl-builder" ] || todo "/etc/cron.d/agl-builder is the cron of a trusted builder: look why it is here"
build_host_steps

[ -n "$(val MIRROR_URL)" ] || todo "no MIRROR_URL: fork builds start cold and fetch everything from upstream (chapter 15)"
exposure_note
finish
