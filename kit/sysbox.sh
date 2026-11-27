#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Install the Sysbox runtime beside runc on a build host, or check an installed one (agl-ci chapter 05, "Sysbox sidecar"). Docker is
# not restarted and no container is removed. It does not switch the runner slots: SIDECAR_RUNTIME of deploy.sh does that.
# deploy.sh runs this script for SIDECAR_RUNTIME=sysbox-runc; it can also be run alone, before the slots are switched.
#   sudo kit/sysbox.sh
#
# Flow, in the order it runs:
#   1. Docker lists sysbox-runc already: skip to the checks (7)
#   2. refuse: not amd64, no docker0, or a job is running in a runner slot
#   3. download the package pinned in docker/pins.env into a new directory and check its sha256
#   4. ask apt what it would do: it may add packages, never remove or upgrade one
#   5. daemon.json: add "bip" (what docker0 has now) and Docker's own default address pools where they are missing. With both
#      present the package asks for no Docker restart. Validate the file, keep a copy of the old one
#   6. install (on failure the old daemon.json comes back), then compare containers, networks, firewall and ports with before
#   7. check: services, runtime, subordinate id ranges, and a throw-away container in which root is not root on the host
set -euo pipefail
[ "$(id -u)" = 0 ] || exec sudo -E "$0" "$@"
here="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
# shellcheck source=../docker/pins.env disable=SC1091
. "$here/../docker/pins.env"
etc="${ETC:-/etc}"   # ETC is for kit/sysbox_test.sh only
cfg="$etc/docker/daemon.json"; keep="$cfg.agl-before-sysbox"
deb="sysbox-ce_${SYSBOX_VERSION}.linux_amd64.deb"

die() { echo "sysbox: $*" >&2; exit 1; }
runtime_listed() { local r; r="$(docker info --format '{{range $n, $_ := .Runtimes}}{{println $n}}{{end}}')" && grep -qx sysbox-runc <<<"$r"; }

# What must look the same before and after the installation.
snapshot() {
  docker ps -aq --no-trunc | sort | while read -r c; do docker inspect "$c" --format 'container {{.Name}} {{.State.StartedAt}}'; done
  docker network ls -q | sort | while read -r n; do docker network inspect "$n" --format 'network {{.Name}} {{range .IPAM.Config}}{{.Subnet}} {{end}}'; done
  docker info --format 'default={{.DefaultRuntime}} root={{.DockerRootDir}}'
  iptables -S 2>&1 || true
  ip6tables -S 2>&1 || true
  ss -Hltn | awk '{print "listen", $4}' | sort
}

# No two accounts may share a subordinate id range: Sysbox maps container root into the range of the user "sysbox".
ranges_ok() {
  sort -t: -k2,2n "$1" | awk -F: '$2 < end { print "overlapping range: " $0; bad = 1 } $2 + $3 > end { end = $2 + $3 } END { exit bad }'
}

install_sysbox() {
  # 2. Refuse what cannot work, and do not touch a host while a job runs.
  [ "$(dpkg --print-architecture)" = amd64 ] || die "only amd64 is pinned"
  local bip n work snap
  bip="$(ip -4 -o addr show docker0 | awk '{print $4; exit}')" || bip=""
  [ -n "$bip" ] || die "no address on docker0: is Docker running?"
  for n in $(docker ps --format '{{.Names}}' | grep '^agl-r[0-9]' || true); do
    ! docker top "$n" | grep -q Runner.Worker || die "a job is running in $n, try again later"
  done

  # 3. The pinned package.
  work="$(mktemp -d)"; chmod 0755 "$work"
  curl -fsSL -o "$work/$deb" "https://github.com/nestybox/sysbox/releases/download/v${SYSBOX_VERSION}/$deb"
  echo "$SYSBOX_AMD64_SHA256  $work/$deb" | sha256sum -c - || die "wrong sha256 for $deb"

  # 4. Nothing may be removed or upgraded.
  apt-get update -qq
  apt-get install -s --no-install-recommends "$work/$deb" > "$work/plan.txt" || die "apt cannot install the package (see above)"
  grep -E '^(Inst|Remv) ' "$work/plan.txt" || true
  ! grep -qE '^Remv |^Inst [^ ]+ \[' "$work/plan.txt" || die "apt would remove or upgrade packages (list above)"

  # 5. The network settings Docker uses already, written down. jq's indented output matters: the package looks for it.
  if [ -f "$cfg" ]; then cp "$cfg" "$work/old.json"; else echo '{}' > "$work/old.json"; fi
  jq --arg bip "$bip" '
    .bip //= $bip |
    ."default-address-pools" //= [
      {"base": "172.17.0.0/16", "size": 16},
      {"base": "172.18.0.0/16", "size": 16},
      {"base": "172.19.0.0/16", "size": 16},
      {"base": "172.20.0.0/14", "size": 16},
      {"base": "172.24.0.0/14", "size": 16},
      {"base": "172.28.0.0/14", "size": 16},
      {"base": "192.168.0.0/16", "size": 20}]' "$work/old.json" > "$work/new.json" || die "cannot read $cfg"
  dockerd --validate --config-file="$work/new.json" || die "dockerd rejects the new daemon.json"

  # 6. Install and compare.
  snapshot > "$work/before.txt"
  [ ! -f "$cfg" ] || [ -f "$keep" ] || cp -p "$cfg" "$keep"
  install -d -m 0755 "$etc/docker"
  install -m 0644 "$work/new.json" "$cfg"
  if ! DEBIAN_FRONTEND=noninteractive NEEDRESTART_SUSPEND=1 apt-get install -y --no-install-recommends "$work/$deb"; then
    install -m 0644 "$work/old.json" "$cfg"
    die "installation failed, daemon.json restored (package log above)"
  fi
  sleep 5   # Docker reads the new runtime on the package's SIGHUP
  snap="$work/after.txt"; snapshot > "$snap"
  diff "$work/before.txt" "$snap" || die "the host changed (< before, > after); look at it. Work files: $work"
  echo "sysbox: installed $SYSBOX_VERSION; work files $work; old daemon.json (if there was one): $keep"
}

# 1. Install only where the runtime is missing.
if ! runtime_listed; then install_sysbox; fi

# 7. The checks run every time. To undo an installation: apt-get purge sysbox-ce, then copy the old daemon.json back.
for s in sysbox-mgr sysbox-fs sysbox docker; do systemctl is-active --quiet "$s" || die "service $s is not active"; done
runtime_listed || die "Docker does not list the runtime sysbox-runc"
ranges_ok "$etc/subuid" || die "overlapping ranges in $etc/subuid"
ranges_ok "$etc/subgid" || die "overlapping ranges in $etc/subgid"
map="$(docker run --rm --runtime=sysbox-runc --network none --entrypoint cat "$DIND_IMAGE" /proc/self/uid_map)" ||
  die "a container with sysbox-runc does not start"
awk 'NF == 3 && $1 == 0 && $2 != 0 { ok = 1 } END { exit !ok }' <<<"$map" || die "root in a Sysbox container is root on the host: $map"
echo "sysbox: OK (uid_map: $(awk '{$1 = $1; print}' <<<"$map")); the runner slots use it with SIDECAR_RUNTIME=sysbox-runc"
