#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# shellcheck disable=SC2329  # the have_ and make_ functions are called by step() of host-lib.sh
# TRUSTED build host (label agl-pr: same-repo pull requests, push, nightly, release): bring a new or an existing host to the state
# of this checkout. Safe to run again; slots with a job are not restarted (agl-ci chapter 05, "Host scripts").
#
#   sudo kit/trusted-pr-install-host.sh --check              report only, change nothing
#   sudo kit/trusted-pr-install-host.sh --run [token-file]   apply
#
# A new host takes its settings from the environment (the variables of kit/deploy.sh), for example
#   sudo SLOTS=2 MIRROR_URL=http://<server>:8080 HASHSERV_RW=<server>:9393 \
#        RSYNCD_BIND=<own private address> RSYNCD_ALLOW=<server private address> kit/trusted-pr-install-host.sh --run <token-file>
# An existing host keeps what it has; give a variable to change it. More: NODE_TUNING=1 (build node sysctl),
# SIDECAR_RUNTIME=sysbox-runc (Sysbox sidecar).
#
# Flow, in the order it runs:
#   1. update the checkout; refuse a host of another role
#   2. packages, Docker, SCTP block, optional tuning and Sysbox, runner kit (deploy.sh), restart of idle slots
#   3. the nightly and staging areas of the cache, the prune cron, the rsync daemon for the download server
#   4. report what a person has to look at
set -euo pipefail
# shellcheck source-path=SCRIPTDIR source=host-lib.sh
. "$(dirname "$(readlink -f "$0")")/host-lib.sh"
# shellcheck disable=SC2034  # read by host-lib.sh
PACKAGES="curl jq ca-certificates git rsync"
pool=trusted

host_init "$@"
update_checkout
guard_build_host "$pool"
[ -z "$(val HASHSERV_UPSTREAM)" ] || die "a trusted host uses HASHSERV_RW, not HASHSERV_UPSTREAM"
build_host_steps

# --- the areas that releases and nightlies are collected into; the rsync daemon offers them only when they exist
have_areas() {
  local d
  for d in nightly staging; do [ -d "$(cache_dir)/$d" ] || { why="missing folder: $(cache_dir)/$d"; return 1; }; done
}
make_areas() { install -d -m 0755 "$(cache_dir)/nightly" "$(cache_dir)/staging"; }
step "nightly and staging areas in the cache" areas

cron_dst="$R/etc/cron.d/agl-builder"
have_cron() { same_file <(cron_text builder.cron) "$cron_dst"; }
make_cron() { install -d -m 0755 "$(dirname "$cron_dst")"; cron_text builder.cron > "$cron_dst"; chmod 0644 "$cron_dst"; }
step "builder cron (/etc/cron.d/agl-builder)" cron

# --- the rsync daemon: its settings come from the environment or from the running container (they are in no file)
rs() { docker inspect agl-rsyncd --format "$1" 2>/dev/null || true; }
rs_bind="${RSYNCD_BIND:-$(rs '{{range index .HostConfig.PortBindings "873/tcp"}}{{.HostIp}}{{end}}')}"
rs_port="${RSYNCD_PORT:-$(rs '{{range index .HostConfig.PortBindings "873/tcp"}}{{.HostPort}}{{end}}')}"
rs_allow="${RSYNCD_ALLOW:-$(rs '{{range .Config.Env}}{{println .}}{{end}}' | sed -n 's/^ALLOW=//p')}"
have_rsyncd() {
  local areas a
  [ "$(rs '{{.State.Running}}')" = true ] || { why="the container agl-rsyncd is not running"; return 1; }
  [[ "$(rs '{{.Config.Image}}')" == *"@$(tr -d '[:space:]' < "$repo/ci/builder.digest")" ]] ||
    { why="its image is not the digest of ci/builder.digest"; return 1; }
  docker exec agl-rsyncd cat /etc/rsyncd.conf 2>/dev/null | cmp -s - "$repo/kit/mirror/rsyncd.conf" ||
    { why="its rsyncd.conf is not kit/mirror/rsyncd.conf"; return 1; }
  areas="$(rs '{{range .Mounts}}{{println .Destination}}{{end}}')"
  for a in dl sstate staging nightly; do grep -qx "/srv/agl/$a" <<<"$areas" || { why="the area $a is not mounted"; return 1; }; done
  [ "$(rs '{{range index .HostConfig.PortBindings "873/tcp"}}{{.HostIp}}{{end}}')" = "$rs_bind" ] ||
    { why="it is bound to another address than RSYNCD_BIND"; return 1; }
  [ "$(rs '{{range index .HostConfig.PortBindings "873/tcp"}}{{.HostPort}}{{end}}')" = "${rs_port:-873}" ] ||
    { why="it is not published on port ${rs_port:-873}"; return 1; }
  [ "$(rs '{{range .Config.Env}}{{println .}}{{end}}' | sed -n 's/^ALLOW=//p')" = "$rs_allow" ] ||
    { why="it allows other addresses than RSYNCD_ALLOW"; return 1; }
}
make_rsyncd() {
  local old
  old="$(rs '{{range index .HostConfig.PortBindings "873/tcp"}}{{.HostPort}}{{end}}')"
  [ -z "$old" ] || [ "$old" = "${rs_port:-873}" ] ||
    line note "rsync port $old becomes ${rs_port:-873}: change it in BUILD_RSYNC (/etc/agl-release/promote.env, download server)"
  RSYNCD_BIND="$rs_bind" RSYNCD_ALLOW="$rs_allow" RSYNCD_PORT="${rs_port:-873}" CACHE_DIR="$(cache_dir)" "$repo/kit/mirror/rsyncd.sh"
}
if [ -z "$rs_bind" ] || [ -z "$rs_allow" ]; then
  todo "no rsync daemon: run again with RSYNCD_BIND and RSYNCD_ALLOW, or the download server gets nothing from this host"
elif ! grep -qF " $rs_bind/" <<<"$(ip -o addr show)"; then
  todo "the address for the rsync daemon is on no interface of this host: is the tunnel up? (daemon left as it is)"
else
  step "rsync daemon for the download server" rsyncd
fi

exposure_note
finish
