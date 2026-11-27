#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Checks kit/sysbox.sh with stub commands (no host is touched, nothing is downloaded): a fresh installation, an installed host, and
# every refusal. The stubs record the installation in a state directory; ETC points to a fake /etc. Needs jq.
# Usage: kit/sysbox_test.sh [path-to-sysbox.sh]
set -u
f="$(readlink -f "${1:-$(dirname "$0")/sysbox.sh}")"; fail=0; t="$(mktemp -d)"; trap 'rm -rf "$t"' EXIT
mkdir "$t/bin"
cat > "$t/bin/stub" <<'EOF'
#!/bin/sh
case "${0##*/}" in
  id) echo 0 ;;
  dpkg) echo "${ARCH:-amd64}" ;;
  curl) while [ "$1" != -o ]; do shift; done; : > "$2" ;;
  sha256sum) [ -z "${BAD_SUM:-}" ] ;;
  apt-get) case "$*" in
      update*) ;;
      "install -s"*) echo "Inst fuse3 (3.17 Debian)"; [ -z "${APT_REMOVES:-}" ] || echo "Remv docker.io [26.1.5]" ;;
      *) [ -z "${APT_FAILS:-}" ] || exit 100; touch "$S/installed" ;;
    esac ;;
  docker) case "$1 ${2:-}" in
      "ps --format") printf 'agl-r1\nagl-d1\n' ;;
      "ps -aq") echo c1 ;;
      inspect*) [ -z "${RESTARTS:-}" ] || [ ! -f "$S/installed" ] || echo "restarted"; echo "container /agl-r1 start" ;;
      "network ls") echo n1 ;;
      "network inspect") echo "network bridge 172.17.0.0/16" ;;
      "info --format") case "$3" in *Runtimes*) echo runc; [ ! -f "$S/installed" ] || echo sysbox-runc ;; *) echo default=runc ;; esac ;;
      top*) echo CMD; [ -z "${JOB:-}" ] || echo Runner.Worker ;;
      "run --rm") echo "         0     ${MAP:-231072}      65536" ;;
      *) echo "unexpected: docker $*" >&2; exit 1 ;;
    esac ;;
  ip) [ -n "${NO_BRIDGE:-}" ] || echo "3: docker0    inet ${BIP:-172.17.0.1/16} scope global docker0" ;;
  systemctl) [ -z "${INACTIVE:-}" ] ;;
  iptables|ip6tables) echo "-P INPUT DROP" ;;
  ss) echo "LISTEN 0 1 0.0.0.0:22 0.0.0.0:*" ;;
  dockerd|sleep) ;;
esac
EOF
chmod +x "$t/bin/stub"
for c in id dpkg curl sha256sum apt-get docker ip systemctl iptables ip6tables ss dockerd sleep; do ln -s stub "$t/bin/$c"; done

# host NAME: a fresh fake host in $h with the old one-line daemon.json of a build host
host() { h="$t/$1"; mkdir -p "$h/etc/docker" "$h/state"; echo '{ "data-root": "/home/docker" }' > "$h/etc/docker/daemon.json"
  printf 'a:100000:65536\nsysbox:165536:65536\n' > "$h/etc/subuid"; cp "$h/etc/subuid" "$h/etc/subgid"; }
run() { env "$@" PATH="$t/bin:$PATH" TMPDIR="$t" S="$h/state" ETC="$h/etc" bash "$f" > "$h/out" 2>&1; }
check() { if [ "$2" = "$3" ]; then echo "ok    $1"; else echo "FAIL  $1: got '$2', want '$3'"; sed 's/^/      /' "$h/out"; fail=1; fi; }
result() { if run "$@"; then echo accepted; else echo refused; fi; }
cfg() { jq -c "$1" "$h/etc/docker/daemon.json"; }
old='{"data-root":"/home/docker"}'

host fresh
check "a fresh host is installed"                     "$(result)" accepted
check "daemon.json keeps what it had"                 "$(cfg '."data-root"')" '"/home/docker"'
check "bip is what docker0 has"                       "$(cfg .bip)" '"172.17.0.1/16"'
check "Docker's default pools are written"            "$(cfg '."default-address-pools" | length')" 7
check "the package finds both keys on indented lines" "$(grep -cE '^[ ]+"bip": "[0-9.]+.*"|^[ ]+"default-address-pools"' "$h/etc/docker/daemon.json")" 2
check "a copy of the old file is kept"                "$(jq -c . "$h/etc/docker/daemon.json.agl-before-sysbox")" "$old"
check "a second run checks and installs nothing"      "$(result APT_FAILS=1)" accepted
check "an installed host with a service down"         "$(result INACTIVE=1)" refused
host bip
check "another docker0 address is kept as bip"        "$(result BIP=10.200.0.1/24) $(cfg .bip)" 'accepted "10.200.0.1/24"'
host arch;    check "not amd64"                       "$(result ARCH=arm64) $(cfg .)" "refused $old"
host bridge;  check "no docker0"                      "$(result NO_BRIDGE=1) $(cfg .)" "refused $old"
host job;     check "a job is running"                "$(result JOB=1) $(cfg .)" "refused $old"
host sum;     check "wrong sha256"                    "$(result BAD_SUM=1) $(cfg .)" "refused $old"
host removes; check "apt would remove a package"      "$(result APT_REMOVES=1) $(cfg .)" "refused $old"
host aptfail; check "failed install restores the file" "$(result APT_FAILS=1) $(cfg .)" "refused $old"
host restart; check "a restarted container is reported" "$(result RESTARTS=1)" refused
host root;    check "root mapped to root"             "$(result MAP=0)" refused
host overlap; printf 'a:100000:65536\nsysbox:120000:65536\n' > "$h/etc/subuid"
check "overlapping subordinate ranges"                "$(result)" refused
exit "$fail"
