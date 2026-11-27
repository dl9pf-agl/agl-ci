#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# shellcheck disable=SC2329  # the have_ and make_ functions are called by step() of host-lib.sh
# DOWNLOAD SERVER (mirror, releases, nightlies; no runner): bring a new or an existing host to the state of this checkout. Safe to
# run again (agl-ci chapter 05, "Host scripts"; chapter 19, "Setting up a download server").
#
#   sudo kit/download-server-install-host.sh --check     report only, change nothing
#   sudo kit/download-server-install-host.sh --run       apply
#
# The settings are in /etc/agl-release/promote.env. On a new host the first run writes the example and asks you to fill it
# (BUILD_RSYNC, the private rsync addresses of the build hosts); run again afterwards.
#
# Flow, in the order it runs:
#   1. update the checkout; refuse a host with active runner slots or with the prune cron of a builder
#   2. packages, Docker, SCTP block, the pinned cosign
#   3. the published tree, promote.env, the clones of agl-ucb and the layer repositories
#   4. the cron file (it replaces the three files of an older install, which are moved aside) and the mirror web server
#   5. report what a person has to look at: release keys, hash server, firewall. These are never changed here
# A new PORT or TLS_PORT recreates the mirror. A MIRROR_NETWORK, TLS_CERT or TLS_KEY that differs from the running mirror
# stops the script before it changes anything and says what to do by hand.
set -euo pipefail
# shellcheck source-path=SCRIPTDIR source=host-lib.sh
. "$(dirname "$(readlink -f "$0")")/host-lib.sh"
# shellcheck disable=SC2034  # read by host-lib.sh
PACKAGES="curl jq ca-certificates git rsync tar util-linux"

host_init "$@"
update_checkout
if [ -n "$(systemctl list-units --state=active --plain --no-legend 'agl-runner@*.service')" ]; then
  die "runner slots are active here: a download server runs no jobs (systemctl disable --now them first)"
fi
[ ! -f "$R/etc/cron.d/agl-builder" ] || die "/etc/cron.d/agl-builder is installed: it prunes staged releases that wait for a signature"

# --- the mirror's network and TLS files are not changed by this script: a wrong value takes the public mirror off the net.
# A given value that differs from what the running mirror has stops the script here, before anything is changed.
mi() { docker inspect agl-mirror --format "$1" 2>/dev/null || true; }
net_name() { case "$1" in default|bridge) echo "" ;; *) echo "$1" ;; esac; }   # empty: Docker's bridge with a published port
guard_mirror() {
  local have want tls pair given copy root port env run
  have="$(mi '{{.HostConfig.NetworkMode}}')"
  [ -n "$have" ] || return 0   # no mirror yet: the given values are simply used
  # the printed commands carry the values of this host: without MIRROR_ROOT, run.sh would serve the builder's cache directory
  root="$(sed -n 's/^export RELEASE_ROOT=\([^ #]*\).*/\1/p' "$R/etc/agl-release/promote.env" 2>/dev/null)"
  port="$(mi '{{range index .HostConfig.PortBindings "8080/tcp"}}{{.HostPort}}{{end}}')"
  env="MIRROR_ROOT=${root:-/srv/agl-permanent} PORT=${port:-8080}"; run="$env $repo/kit/mirror/run.sh"
  if [ -n "${MIRROR_NETWORK+x}" ]; then
    want="$(net_name "$MIRROR_NETWORK")"; have="$(net_name "$have")"
    [ "$want" = "$have" ] || die "the mirror uses the network '${have:-bridge}', MIRROR_NETWORK asks for '${want:-bridge}'.
  Not changed here. To keep it: run without MIRROR_NETWORK. To change it, on this host:
    1. MIRROR_NETWORK=$want $run    (with TLS_CERT and TLS_KEY when it serves TLS)
    2. check ufw and the published ports, IPv4 and IPv6 (host networking listens on 8080 and 8443)
    3. if the address or port of the mirror changes: MIRROR_URL in /etc/agl-runner/runner.env of the build hosts"
  fi
  [ -n "${TLS_CERT:-}${TLS_KEY:-}" ] || return 0
  [ -r "${TLS_CERT:-}" ] && [ -r "${TLS_KEY:-}" ] || die "TLS_CERT and TLS_KEY must both be given and readable"
  tls="$R/etc/agl-runner/mirror-tls"   # the copy kit/mirror/run.sh made for the container
  for pair in "$TLS_CERT:fullchain.pem" "$TLS_KEY:privkey.pem"; do
    given="${pair%:*}"; copy="$tls/${pair##*:}"
    cmp -s "$given" "$copy" || die "the TLS file $given is not what the mirror serves (its copy: $copy).
  Not changed here. To keep the served one: run without TLS_CERT and TLS_KEY. To change it, on this host:
    1. TLS_CERT=$TLS_CERT TLS_KEY=$TLS_KEY $run
    2. with Let's Encrypt instead: $env TLS_NAME=<dns name> $repo/kit/mirror/certbot.sh renew (restarts the mirror itself)
    3. add the same renewal to cron if the files are renewed by something else (chapter 15)"
  done
}
guard_mirror
step "packages" packages
docker_step
step "SCTP module blocked" sctp

# --- cosign, the version of docker/pins.env (promote.sh verifies the builder's signatures with it)
cosign_bin="$R/usr/local/bin/cosign"
have_cosign() { [ -x "$cosign_bin" ] && echo "$COSIGN_LINUX_AMD64_SHA256  $cosign_bin" | sha256sum -c --status -; }
make_cosign() {
  local t; t="$(mktemp)"
  curl -fsSL -o "$t" "https://github.com/sigstore/cosign/releases/download/${COSIGN_RELEASE}/cosign-linux-amd64"
  echo "$COSIGN_LINUX_AMD64_SHA256  $t" | sha256sum -c --status - || die "wrong sha256 for cosign"
  install -D -m 0755 "$t" "$cosign_bin"; rm -f "$t"
}
step "cosign $COSIGN_RELEASE" cosign

# --- settings and tree
promote="$R/etc/agl-release/promote.env"
have_promote() { [ -f "$promote" ]; }
make_promote() { install -D -m 0600 "$repo/kit/release/promote.env.example" "$promote"; }
step "/etc/agl-release/promote.env exists" promote
# setting KEY DEFAULT: the value of "export KEY=value  # comment" in promote.env
setting() {
  local v; v="$(sed -n "s/^export $1=//p" "$promote" 2>/dev/null | head -1 | sed 's/[[:space:]]*#.*//; s/^"//; s/"$//')"
  echo "${v:-$2}"
}
tree="$R$(setting RELEASE_ROOT /srv/agl-permanent)"
have_tree() {
  local d
  for d in dl sstate git staging release nightly; do [ -d "$tree/$d" ] || { why="missing folder: ${tree#"$R"}/$d"; return 1; }; done
}
make_tree() { local d; for d in dl sstate git staging release nightly; do install -d -m 0755 "$tree/$d"; done; }
step "published tree ${tree#"$R"}" tree

# --- clones: promote.sh reads the signatures from agl-ucb, the git mirror refresh reads the kas files of all of them
owner="${PROJECT_REPO%%/*}"
clones() {
  printf '%s %s\n' agl-ucb "$R$(setting RELEASE_UCB_DIR /srv/agl-ucb)" agl-ucb "$R/root/agl-ucb" \
    meta-agl "$R/root/src-meta-agl" meta-agl-demo "$R/root/src-meta-agl-demo" meta-agl-devel "$R/root/src-meta-agl-devel" | sort -u
}
have_clones() {
  local n d
  while read -r n d; do [ -d "$d/.git" ] || { why="no clone of $n in ${d#"$R"}"; return 1; }; done < <(clones)
}
make_clones() {
  local n d
  while read -r n d; do [ -d "$d/.git" ] || git clone -q "https://github.com/$owner/$n" "$d" </dev/null; done < <(clones)
}
step "clones of agl-ucb and the layer repositories" clones

# --- cron: only with real settings, or every job would fail each minute
old_crons=(agl-release agl-pull-sync agl-git-mirrors)
cron_dst="$R/etc/cron.d/agl-server"
have_cron() {
  local o
  for o in "${old_crons[@]}"; do
    [ ! -e "$R/etc/cron.d/$o" ] || { why="an older cron file is still there: /etc/cron.d/$o"; return 1; }
  done
  same_file <(cron_text server.cron) "$cron_dst"
}
make_cron() {
  local o aside; aside="$R/var/backups/agl-cron.$(date +%Y%m%d-%H%M%S)"
  install -d -m 0755 "$(dirname "$cron_dst")"; cron_text server.cron > "$cron_dst"; chmod 0644 "$cron_dst"
  for o in "${old_crons[@]}"; do
    [ -e "$R/etc/cron.d/$o" ] || continue
    install -d -m 0700 "$aside"; mv "$R/etc/cron.d/$o" "$aside/"; line note "old cron file $o moved to ${aside#"$R"}/"
  done
}
if [ ! -f "$promote" ] || grep -q 'PRIVATE-ADDRESS' "$promote"; then
  todo "fill BUILD_RSYNC in /etc/agl-release/promote.env, then run again (the cron is not installed before that)"
else
  step "server cron (/etc/cron.d/agl-server)" cron
fi

# --- the mirror web server
port_of() { mi "{{range index .HostConfig.PortBindings \"$1/tcp\"}}{{.HostPort}}{{end}}"; }   # published port of $1, if any
# shellcheck disable=SC2016  # the text of run.sh is searched, nothing is to expand here
mirror_image="$(sed -n 's/^IMAGE="${MIRROR_IMAGE:-\(.*\)}"$/\1/p' "$repo/kit/mirror/run.sh")"
mounts="$(mi '{{range .Mounts}}{{println .Destination}}{{end}}')"
have_mirror() {
  local pair d now
  [ "$(mi '{{.State.Running}}')" = true ] || { why="the container agl-mirror is not running"; return 1; }
  [ "$(mi '{{.Config.Image}}')" = "$mirror_image" ] || { why="its image is not the one pinned in kit/mirror/run.sh"; return 1; }
  for pair in nginx.conf:/etc/nginx/nginx.conf locations.conf:/etc/nginx/mirror/locations.conf index.html:/srv/mirror/index.html; do
    docker exec agl-mirror cat "${pair#*:}" 2>/dev/null | cmp -s - "$repo/kit/mirror/${pair%%:*}" ||
      { why="its ${pair%%:*} is not kit/mirror/${pair%%:*} (a container keeps the old file after a git pull)"; return 1; }
  done
  now="$(mi '{{range .Mounts}}{{println .Destination}}{{end}}')"
  # a given port that is not the published one (with host networking nothing is published and the ports are fixed)
  if [ "$(mi '{{.HostConfig.NetworkMode}}')" != host ]; then
    [ -z "${PORT:-}" ] || [ "$(port_of 8080)" = "$PORT" ] || { why="it is not published on PORT $PORT"; return 1; }
    [ -z "${TLS_PORT:-}" ] || ! grep -qx /etc/nginx/mirror/tls/server.conf <<<"$now" || [ "$(port_of 8443)" = "$TLS_PORT" ] ||
      { why="it is not published on TLS_PORT $TLS_PORT"; return 1; }
  fi
  for d in dl sstate git staging release nightly; do
    grep -qx "/srv/mirror/$d" <<<"$now" || { why="the folder $d is not mounted"; return 1; }
  done
}
make_mirror() {
  local port tls_port net old old_tls
  old="$(port_of 8080)"; old_tls="$(port_of 8443)"
  port="${PORT:-$old}"; tls_port="${TLS_PORT:-$old_tls}"
  net="${MIRROR_NETWORK:-}"; [ -n "$net" ] || [ "$(mi '{{.HostConfig.NetworkMode}}')" != host ] || net=host
  if { [ -n "$old" ] && [ "$old" != "$port" ]; } || { [ -n "$old_tls" ] && [ "$old_tls" != "$tls_port" ]; }; then
    line note "a mirror port changes: change ufw on this host and MIRROR_URL in /etc/agl-runner/runner.env of the build hosts"
  fi
  MIRROR_ROOT="$tree" PORT="${port:-8080}" TLS_PORT="${tls_port:-8443}" MIRROR_NETWORK="$net" "$repo/kit/mirror/run.sh"
}
if grep -qx /etc/nginx/mirror/tls/server.conf <<<"$mounts" && [ -z "${TLS_CERT:-}" ] && ! have_mirror; then
  todo "the mirror serves TLS and is not current: run again with TLS_CERT and TLS_KEY (kit/mirror/certbot.sh); left as it is"
  show_why
else
  step "mirror web server (agl-mirror)" mirror
fi

# --- only reported
keys="$(setting RELEASE_KEYS_DIR "")"; if [ -n "$keys" ]; then keys="$R$keys"; else keys="$repo/keys/release"; fi
[ -n "$(find "$keys" -type f ! -name .gitkeep -print -quit 2>/dev/null)" ] || todo "no release engineer keys in the keys directory of promote.env (chapter 19)"
hs="$(docker ps -a --format '{{.Names}} {{.Image}}' | awk '$2 ~ /prhashserv/ {print $1}')"
if [ -z "$hs" ]; then
  todo "no hash server container (chapter 14)"
else
  for c in $hs; do
    case "$(docker inspect "$c" --format '{{.State.Running}} {{.HostConfig.RestartPolicy.Name}}')" in
      "true unless-stopped"|"true always") line ok "hash server $c runs and restarts after a reboot" ;;
      *) todo "hash server $c is stopped or has no restart policy: it will be gone after a reboot (chapter 14)" ;;
    esac
  done
  rules="$(iptables -S DOCKER-USER 2>/dev/null || true)"
  grep -q '9393.*DROP' <<<"$rules" ||
    todo "no DOCKER-USER drop rule for the read-write hash ports (IPv4); fine only if they are bound to a private address (chapter 14)"
fi
exposure_note
finish
