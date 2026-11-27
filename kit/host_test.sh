#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# shellcheck disable=SC2015,SC2012  # PASS/FAIL lines, not an if-then-else; ls only counts files with names the test made
# Checks the three host scripts (one per role) with stubs: a copy of the kit whose deploy.sh, sysbox.sh, rsyncd.sh and mirror
# run.sh only record the call and change a fake host below AGL_ROOT; docker, systemctl, apt and friends are stubs. No host is
# touched. For each role: --check changes nothing, apply converges, a second run does nothing, and what must be refused is.
# Usage: kit/host_test.sh
set -u
src="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"; fail=0; t="$(mktemp -d)"; trap 'rm -rf "$t"' EXIT
repo="$t/repo"; mkdir -p "$repo/kit/mirror" "$repo/kit/release" "$repo/kit/sysctl" "$repo/ci" "$repo/docker" "$repo/policy" "$repo/keys/release" "$t/bin"
for f in host-lib.sh trusted-pr-install-host.sh untrusted-fork-pr-install-host.sh download-server-install-host.sh run-loop.sh \
         agl-runner@.service runner.digest builder.cron server.cron mirror/nginx.conf mirror/locations.conf mirror/index.html \
         mirror/rsyncd.conf release/promote.env.example sysctl/90-agl-ci-cache.conf; do cp "$src/kit/$f" "$repo/kit/$f"; done
cp "$src/ci/builder.digest" "$repo/ci/"; cp "$src/docker/pins.env" "$repo/docker/"; cp "$src/policy/project.env" "$repo/policy/"
mirror_image_line="$(grep '^IMAGE=' "$src/kit/mirror/run.sh")"

# the fake sub-scripts: record the call, then leave the fake host as the real script would
cat > "$repo/kit/deploy.sh" <<'EOS'
#!/bin/bash
echo "deploy POOL=$POOL ${1:-}" >> "$AGL_ROOT/calls"
here="$(dirname "$0")"; . "$here/../docker/pins.env"
mkdir -p "$AGL_ROOT/etc/agl-runner" "$AGL_ROOT/opt/agl-runner" "$AGL_ROOT/etc/systemd/system" "$AGL_ROOT/units"
old() { sed -n "s/^$1=//p" "$AGL_ROOT/etc/agl-runner/runner.env" 2>/dev/null; }
new="$(for k in SLOTS LINT_SLOTS MIRROR_URL SIDECAR_RUNTIME HASHSERV_RW HASHSERV_UPSTREAM CACHE_DIR; do
  if [ -n "${!k+x}" ]; then v="${!k}"; else v="$(old $k)"; [ -n "$v" ] || case $k in SLOTS|LINT_SLOTS) v=1 ;; esac; fi; echo "$k=$v"; done)"
{ echo "$new"; echo "POOL=$POOL"; echo "RUNNER_IMAGE=ghcr.io/x/runner@$(cat "$here/runner.digest")"; echo "DIND_IMAGE=$DIND_IMAGE"; } > "$AGL_ROOT/etc/agl-runner/runner.env"
cp "$here/run-loop.sh" "$AGL_ROOT/opt/agl-runner/"; cp "$here/agl-runner@.service" "$AGL_ROOT/etc/systemd/system/"
mkdir -p "$AGL_ROOT/srv/agl-cache"
for i in 1 2; do [ -f "$AGL_ROOT/units/agl-runner@$i.service" ] || date +%s > "$AGL_ROOT/units/agl-runner@$i.service"; done
EOS
cat > "$repo/kit/sysbox.sh" <<'EOS'
#!/bin/bash
echo sysbox >> "$AGL_ROOT/calls"; touch "$AGL_ROOT/sysbox"
EOS
cat > "$repo/kit/mirror/rsyncd.sh" <<'EOS'
#!/bin/bash
echo rsyncd >> "$AGL_ROOT/calls"; c="$AGL_ROOT/ctr/agl-rsyncd"; mkdir -p "$c"; here="$(dirname "$0")"
echo true > "$c/running"; echo "ghcr.io/x/builder@$(cat "$here/../../ci/builder.digest")" > "$c/image"
echo "$RSYNCD_BIND" > "$c/bind"; echo "${RSYNCD_PORT:-873}" > "$c/port"; echo "ALLOW=$RSYNCD_ALLOW" > "$c/env"
printf '/srv/agl/%s\n' dl sstate staging nightly > "$c/mounts"; mkdir -p "$c/files/etc"; cp "$here/rsyncd.conf" "$c/files/etc/rsyncd.conf"
EOS
{ echo '#!/bin/bash'; echo "$mirror_image_line"; cat <<'EOS'; } > "$repo/kit/mirror/run.sh"
echo "mirror PORT=$PORT" >> "$AGL_ROOT/calls"; c="$AGL_ROOT/ctr/agl-mirror"; here="$(dirname "$0")"; mkdir -p "$c/files/etc/nginx/mirror" "$c/files/srv/mirror"
echo true > "$c/running"; echo "$IMAGE" > "$c/image"; echo "$PORT" > "$c/port"
cp "$here/nginx.conf" "$c/files/etc/nginx/"; cp "$here/locations.conf" "$c/files/etc/nginx/mirror/"; cp "$here/index.html" "$c/files/srv/mirror/"
printf '/srv/mirror/%s\n' dl sstate git staging release nightly > "$c/mounts"
EOS
chmod +x "$repo"/kit/*.sh "$repo"/kit/mirror/*.sh

cat > "$t/bin/stub" <<'EOS'
#!/bin/bash
S="$AGL_ROOT"
case "${0##*/}" in
  id) echo 0 ;;
  dpkg-query) [ -f "$S/packages" ] && echo installed ;;
  apt-get) echo "apt-get $1" >> "$S/calls"; case "$1" in install) touch "$S/packages" ;; esac ;;
  sha256sum) [[ "$*" == *--status* ]] && { f="${*: -1}"; [ "$f" = - ] && f="$(awk '{print $2}')"; grep -q good "$f" 2>/dev/null; } ;;
  curl) while [ "$1" != -o ]; do shift; done; echo good > "$2" ;;
  git) echo "git $*" >> "$S/calls"; mkdir -p "${*: -1}/.git" ;;
  ip) case "$*" in *global*) ;; *) echo "2: wg0    inet 10.9.0.2/24 scope global wg0" ;; esac ;;
  ss) echo "LISTEN 0 1 ${LISTEN:-0.0.0.0:22} 0.0.0.0:*" ;;
  iptables) echo "-N DOCKER-USER" ;;
  sysctl) ;;
  systemctl) case "$1" in
      is-active) [ "${STOPPED_SLOT:-}" != "${*: -1}" ] && { [ -f "$S/sysbox" ] || [[ "$*" != *sysbox* ]]; } ;;
      is-enabled) [ -f "$S/units/${*: -1}" ] ;;
      show) f="$S/units/${*: -1}"; [ ! -f "$f" ] || date -u -d "@$(cat "$f")" '+%a %Y-%m-%d %H:%M:%S UTC' ;;
      restart) echo "restart ${*: -1}" >> "$S/calls"; date +%s > "$S/units/${*: -1}" ;;
      list-units) [ -z "${ACTIVE_RUNNERS:-}" ] || echo agl-runner@1.service ;;
      enable) touch "$S/docker" ;;
    esac ;;
  docker) case "$1" in
      info) [ -f "$S/docker" ] || exit 1; case "$*" in *Runtimes*) echo runc; [ ! -f "$S/sysbox" ] || echo sysbox-runc ;; esac ;;
      ps) for c in "$S"/ctr/*; do [ -d "$c" ] && echo "${c##*/} $(cat "$c/image")"; done; true ;;
      top) echo CMD; [ -z "${BUSY:-}" ] || [ "$2" != "$BUSY" ] || echo Runner.Worker ;;
      exec) cat "$S/ctr/$2/files$4" ;;
      inspect) c="$S/ctr/$2"; [ -d "$c" ] || exit 1; f="${4:-}"
        case "$f" in
          *Running*RestartPolicy*) echo "$(cat "$c/running") unless-stopped" ;;
          *Running*) cat "$c/running" ;; *Config.Image*) cat "$c/image" ;; *HostIp*) cat "$c/bind" 2>/dev/null ;;
          *HostPort*) cat "$c/port" 2>/dev/null ;; *Config.Env*) cat "$c/env" ;; *Destination*) cat "$c/mounts" ;; *NetworkMode*) echo bridge ;;
        esac ;;
    esac ;;
esac
EOS
chmod +x "$t/bin/stub"
for c in id dpkg-query apt-get sha256sum curl git ip ss iptables sysctl systemctl docker; do ln -s stub "$t/bin/$c"; done

# host NAME: an empty fake host; run SCRIPT [env...] [arguments, default --run]; calls: what was changed so far
host() { h="$t/$1"; mkdir -p "$h/etc/cron.d"; : > "$h/calls"; }
run() { local s="$1" a=(); shift; while [ "$#" -gt 0 ] && [[ "$1" == *=* ]]; do a+=("$1"); shift; done
  [ "$#" -gt 0 ] || set -- --run
  bare "$s" "${a[@]}" "$@"; }
# bare: the same, with exactly the arguments given
bare() { local s="$1" a=(); shift; while [ "$#" -gt 0 ] && [[ "$1" == *=* ]]; do a+=("$1"); shift; done
  env "${a[@]}" PATH="$t/bin:$PATH" AGL_ROOT="$h" AGL_NO_PULL=1 bash "$repo/kit/$s-install-host.sh" "$@" > "$h/out" 2>&1; echo $?; }
check() { if [ "$2" = "$3" ]; then echo "ok    $1"; else echo "FAIL  $1: got '$2', want '$3'"; sed 's/^/      /' "$h/out"; fail=1; fi; }
count() { grep -c -- "$1" "$h/calls"; }
said() { grep -q -- "$1" "$h/out" && echo yes || echo no; }

# --- trusted
host trusted
for s in trusted-pr untrusted-fork-pr download-server; do
  check "$s without argument: usage, nothing done"         "$(bare "$s") $(said "usage: $s-install-host.sh --check | --run") $(wc -l < "$h/calls") $(find "$h/etc" -type f | wc -l)" "2 yes 0 0"
done
check "--help prints the usage"                            "$(bare trusted-pr --help) $(said 'report only, change nothing')" "0 yes"
check "--check and --run together are refused"             "$(bare trusted-pr --check --run) $(wc -l < "$h/calls")" "2 0"
check "an unknown option is refused"                       "$(bare trusted-pr --force) $(wc -l < "$h/calls")" "2 0"
check "a token file alone does nothing"                    "$(bare trusted-pr /tmp/token) $(wc -l < "$h/calls")" "2 0"
check "trusted, new host, --check: differs"                "$(run trusted-pr --check)" 3
check "--check changes nothing"                            "$(wc -l < "$h/calls") $(find "$h/etc" -type f | wc -l)" "0 0"
check "apply converges without rsync settings"             "$(run trusted-pr)" 0
check "deploy ran for the trusted pool"                    "$(count 'deploy POOL=trusted')" 1
host token; run trusted-pr --run /tmp/token >/dev/null
check "the token file reaches deploy.sh"                   "$(count 'deploy POOL=trusted /tmp/token')" 1
h="$t/trusted"
check "no rsync settings is a TODO"                        "$(said 'TODO     no rsync daemon')" yes
check "the prune cron is installed with this checkout"     "$(grep -c "$repo/kit/prune-builder.sh" "$h/etc/cron.d/agl-builder")" 1
check "the nightly area exists"                            "$([ -d "$h/srv/agl-cache/nightly" ] && echo yes)" yes
: > "$h/calls"
check "a second run is current"                            "$(run trusted-pr)" 0
check "a second run changes nothing"                       "$(wc -l < "$h/calls")" 0
check "rsync settings start the daemon"                    "$(run trusted-pr RSYNCD_BIND=10.9.0.2 RSYNCD_ALLOW=10.9.0.1) $(count rsyncd)" "0 1"
: > "$h/calls"
check "the daemon is current without the settings again"   "$(run trusted-pr) $(wc -l < "$h/calls")" "0 0"
check "an address on no interface leaves the daemon"       "$(run trusted-pr RSYNCD_BIND=10.9.9.9) $(count rsyncd) $(said 'tunnel up')" "0 0 yes"
for i in 1 2; do echo 1 > "$h/units/agl-runner@$i.service"; done; : > "$h/calls"
check "a changed setting: busy slot pending, idle restarted" "$(run trusted-pr MIRROR_URL=http://m:8080 BUSY=agl-r1)" 3
check "only the idle slot was restarted"                   "$(count 'restart agl-runner@2') $(count 'restart agl-runner@1')" "1 0"
echo 1 > "$h/units/agl-runner@1.service"; : > "$h/calls"
check "the next run restarts the slot that is now idle"    "$(run trusted-pr) $(count 'restart agl-runner@1') $(count deploy)" "0 1 0"
check "a stopped slot is started"                          "$(run trusted-pr STOPPED_SLOT=agl-runner@2.service) $(count 'restart agl-runner@2')" "0 1"
: > "$h/calls"
check "a busy slot is never removed by a smaller number"   "$(run trusted-pr SLOTS=0 BUSY=agl-r2) $(count deploy) $(said 'would be removed')" "1 0 yes"
check "Sysbox is installed when asked"                     "$(run trusted-pr SIDECAR_RUNTIME=sysbox-runc) $(count '^sysbox')" "0 1"
check "an untrusted script refuses a trusted host"         "$(run untrusted-fork-pr) $(said 'trusted pool')" "1 yes"
check "HASHSERV_UPSTREAM is refused"                       "$(run trusted-pr HASHSERV_UPSTREAM=h:9494)" 1
host server_cron; touch "$h/etc/cron.d/agl-server"
check "a download server never becomes a builder"          "$(run trusted-pr) $(count deploy)" "1 0"

# --- untrusted
host untrusted
check "untrusted, new host: applied"                       "$(run untrusted-fork-pr) $(count 'deploy POOL=untrusted')" "0 1"
check "no mirror is a TODO; no builder cron, no daemon"    "$(said 'no MIRROR_URL') $(ls "$h/etc/cron.d" | wc -l) $(count rsyncd)" "yes 0 0"
check "a host that listens on loopback only"               "$(run untrusted-fork-pr LISTEN=127.0.0.1:22) $(said 'beyond loopback: nothing')" "0 yes"
check "SCTP is blocked"                                    "$(cat "$h/etc/modprobe.d/disable-sctp.conf")" "install sctp /bin/false"
check "no tuning unless asked"                             "$([ -f "$h/etc/sysctl.d/90-agl-ci-cache.conf" ] && echo yes || echo no)" no
check "tuning when asked"                                  "$(run untrusted-fork-pr NODE_TUNING=1) $([ -f "$h/etc/sysctl.d/90-agl-ci-cache.conf" ] && echo yes)" "0 yes"
check "HASHSERV_RW is refused"                             "$(run untrusted-fork-pr HASHSERV_RW=h:9393)" 1
mkdir -p "$h/ctr/agl-rsyncd"; echo x > "$h/ctr/agl-rsyncd/image"
check "an rsync daemon is refused"                         "$(run untrusted-fork-pr)" 1

# --- download server
host server
check "server with active runner slots is refused"         "$(run download-server ACTIVE_RUNNERS=1)" 1
check "server, new host, --check: differs, nothing done"   "$(run download-server --check) $(wc -l < "$h/calls")" "3 0"
check "first apply"                                        "$(run download-server)" 0
check "the settings are asked for, no cron yet"            "$(said 'fill BUILD_RSYNC') $([ -f "$h/etc/cron.d/agl-server" ] && echo yes || echo no)" "yes no"
check "tree, cosign, five clones and the mirror"           "$([ -d "$h/srv/agl-permanent/nightly" ] && echo yes) $([ -x "$h/usr/local/bin/cosign" ] && echo yes) $(count 'git clone') $(count '^mirror PORT=8080')" "yes yes 5 1"
sed -i 's/BUILDER-[AB]-PRIVATE-ADDRESS/10.9.0.2/g' "$h/etc/agl-release/promote.env"; touch "$h/etc/cron.d/agl-pull-sync" "$h/etc/cron.d/agl-git-mirrors"; : > "$h/calls"
check "with settings the cron is installed"                "$(run download-server) $([ -f "$h/etc/cron.d/agl-server" ] && echo yes)" "0 yes"
check "old cron files are moved aside, not deleted"        "$(ls "$h"/var/backups/agl-cron.*/ | wc -l) $(ls "$h/etc/cron.d")" "2 agl-server"
check "a second run changes nothing"                       "$(run download-server) $(wc -l < "$h/calls")" "0 0"
echo old > "$h/ctr/agl-mirror/files/etc/nginx/nginx.conf"
check "a changed web server config recreates the mirror"   "$(run download-server) $(count '^mirror')" "0 1"
echo old > "$h/ctr/agl-mirror/files/etc/nginx/nginx.conf"; echo /etc/nginx/mirror/tls/server.conf >> "$h/ctr/agl-mirror/mounts"; : > "$h/calls"
check "a TLS mirror is not recreated without certificate"  "$(run download-server) $(count '^mirror') $(said 'serves TLS')" "0 0 yes"
touch "$h/etc/cron.d/agl-builder"
check "a builder cron is refused"                          "$(run download-server)" 1
exit "$fail"
