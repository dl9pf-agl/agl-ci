#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Checks kit/sysbox-acceptance.sh with stub commands (no host is touched, no container is started): a passing host, every
# kind of leak, and every refusal. The stubs act like Docker: what a probe sees depends on how the sidecar was started.
# Usage: kit/sysbox-acceptance_test.sh [path-to-sysbox-acceptance.sh]
set -u
f="$(readlink -f "${1:-$(dirname "$0")/sysbox-acceptance.sh}")"; fail=0; t="$(mktemp -d)"; trap 'rm -rf "$t"' EXIT
mkdir -p "$t/bin" "$t/repo/kit" "$t/repo/ci"; cp "$f" "$t/repo/kit/sysbox-acceptance.sh"; echo sha256:abc > "$t/repo/ci/builder.digest"
cat > "$t/bin/stub" <<'EOS'
#!/bin/bash
mode() { cat "$S/mode" 2>/dev/null; }
# a probe from inside a container: the privileged sidecar sees the host disk, Sysbox shall not
disk() { if [ "$(mode)" = privileged ] || [ -n "${DISK_LEAK:-}" ]; then echo readable; else echo blocked; fi; }
core() { [ -z "${CORE_LEAK:-}" ] || echo agl-probe > "$CORE"; }
case "${0##*/}" in
  id) echo 0 ;;
  findmnt) echo /dev/fake ;;
  lsblk) echo '9:3' ;;
  dd|sleep) ;;
  ps) [ -z "${STUCK:-}" ] || echo 'D runc:[2:INIT]'; echo 'D md2_raid1' ;;
  install) mkdir -p "${*: -1}" ;;
  stat) printf '1001:1001\n0:0\n' ;;
  docker) echo "docker $*" >> "$S/calls"
    case "$1" in
      info) echo "runc ${NO_SYSBOX:+x}$([ -n "${NO_SYSBOX:-}" ] || echo sysbox-runc)" ;;
      inspect) [ -n "${LEFTOVER:-}" ] ;;
      run) case "$*" in
          *"-d --rm --privileged"*) echo privileged > "$S/mode" ;;
          *"-d --rm --runtime=sysbox-runc"*) echo sysbox > "$S/mode" ;;
          *"stat -c"*) echo 1001:1001 ;;
        esac ;;
      exec) case "$*" in
          *"--entrypoint wget"*) ;;
          *core_pattern*) core ;;
          *acc-disk*) disk ;;
          *"--entrypoint touch"*) touch "${*: -1}" ;;
          *"--entrypoint python3"*) echo 'no: unshare errno 1' ;;
        esac ;;
    esac ;;
esac
EOS
chmod +x "$t/bin/stub"
for c in id findmnt lsblk dd sleep ps install stat docker; do ln -s stub "$t/bin/$c"; done

# host NAME [pool]: a fresh fake host in $h
host() { h="$t/$1"; mkdir -p "$h"; : > "$h/calls"; echo core > "$h/core"
  printf 'POOL=%s\nRUNNER_IMAGE=r\nDIND_IMAGE=d\nCACHE_DIR=%s/cache\n' "${2:-trusted}" "$h" > "$h/env"; }
result() { env "$@" PATH="$t/bin:$PATH" S="$h" ENVF="$h/env" CORE="$h/core" sh "$t/repo/kit/sysbox-acceptance.sh" "${arg---run}" > "$h/out" 2>&1; echo $?; }
check() { if [ "$2" = "$3" ]; then echo "ok    $1"; else echo "FAIL  $1: got '$2', want '$3'"; sed 's/^/      /' "$h/out"; fail=1; fi; }
said() { if grep -q -- "$1" "$h/out"; then echo yes; else echo no; fi; }

host usage;    arg="" ; check "without --run: usage, no Docker call"  "$(result) $(said 'PROBES isolation') $(wc -l < "$h/calls")" "2 yes 0"; unset arg
host good;     check "a good host passes"                             "$(result) $(said 'ACCEPTANCE PASSED')" "0 yes"
check "the test folder is removed"                                    "$(find "$h" -name 'cache.acceptance.*' | wc -l)" 0
host disk;     check "disk readable under Sysbox fails"               "$(result DISK_LEAK=1) $(said 'FAIL  sysbox: disk blocked from the sidecar')" "1 yes"
host core;     check "a changed core_pattern fails and is restored"   "$(result CORE_LEAK=1) $(cat "$h/core")" "1 core"
host stuck;    check "a container process in state D fails"           "$(result STUCK=1)" 1
host nosysbox; check "no Sysbox: refused, nothing started"            "$(result NO_SYSBOX=1) $(grep -c ' run ' "$h/calls")" "1 0"
host leftover; check "a leftover sidecar: refused"                    "$(result LEFTOVER=1) $(grep -c ' run ' "$h/calls")" "1 0"
host server x; check "not a build host: refused, no Docker call"      "$(result) $(wc -l < "$h/calls")" "1 0"
exit "$fail"
