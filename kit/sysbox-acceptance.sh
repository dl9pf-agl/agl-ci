#!/bin/sh
# SPDX-License-Identifier: MIT
# Acceptance of Sysbox on a build host, before the runner slots use it (agl-ci chapter 20, "Sysbox on a build host").
#   sudo kit/sysbox-acceptance.sh          print this text, change nothing
#   sudo kit/sysbox-acceptance.sh --run    run the checks
# It PROBES isolation: it tries to read 512 bytes of the host disk (nothing is written to it), and under Sysbox only it tries
# to change the host's core_pattern and puts the old value back if that worked. Throw-away containers, no published port; the
# runner slots are not touched. Safe to run again.
#
# Flow, in the order it runs:
#   1. prerequisites: root, a build host, Docker lists sysbox-runc, no leftover of another run
#   2. baseline: the checks in today's privileged sidecar, to prove that each check can see a difference
#   3. the same checks in a sidecar under sysbox-runc, and the core_pattern probe
#   4. no container process stuck in state D (the open Sysbox hang); exit 1 if any line says FAIL
set -u
repo=$(cd "$(dirname "$0")/.." && pwd)
envf=${ENVF:-/etc/agl-runner/runner.env}
core=${CORE:-/proc/sys/kernel/core_pattern}
ws=/home/runner/actions-runner/_work
name=agl-acc-d
net=agl-acc-n
vol=agl-acc-w
work=
fail=0

# Stop with a message; the trap removes what the script made.
die() {
  echo "STOPPED: $*" >&2
  exit 1
}

# Remove the sidecar, its network and volume; and at the end our own folder.
drop_sidecar() {
  docker rm -fv "$name" >/dev/null 2>&1
  docker network rm "$net" >/dev/null 2>&1
  docker volume rm "$vol" >/dev/null 2>&1
}

cleanup() {
  drop_sidecar
  if [ -n "$work" ]; then
    rm -f "$work/u/by-user" "$work/r/by-root"
    rmdir "$work/u" "$work/r" "$work"
  fi
}

# Print one result line; a wrong value marks the run as failed.
expect() {
  if [ "$2" = "$3" ]; then
    printf 'ok    %-44s %s\n' "$1" "$2"
  else
    printf 'FAIL  %-44s got "%s", want "%s"\n' "$1" "$2" "$3"
    fail=1
  fi
}

# Run docker inside the sidecar.
inner() {
  docker exec "$name" docker "$@"
}

# Start a sidecar the way kit/run-loop.sh does, with the given isolation.
start_sidecar() {
  docker network create "$net" >/dev/null || die "cannot create $net"
  docker volume create "$vol" >/dev/null || die "cannot create $vol"
  docker run --rm -v "$vol:/w" --user 0 --entrypoint chown "$runner" \
    1001:1001 /w || die "cannot prepare the workspace volume"
  docker run -d --rm "$1" --name "$name" --network "$net" \
    -e DOCKER_TLS_CERTDIR= -v "$vol:$ws" -v "$work:$work" "$dind" \
    >/dev/null || die "the sidecar does not start with $1"
  t0=$(date +%s)
  for _ in $(seq 1 90); do
    if docker run --rm --network "$net" -e DOCKER_HOST="tcp://$name:2375" \
      --entrypoint docker "$runner" info >/dev/null 2>&1; then
      echo "      inner docker answers after $(($(date +%s) - t0)) s"
      return 0
    fi
    sleep 2
  done
  docker logs --tail 20 "$name" >&2
  die "inner docker never answered with $1"
}

# 1. A nested container on the inner bridge resolves names and gets out.
c_net() {
  if inner run --rm --entrypoint wget "$dind" -q -O /dev/null \
    https://github.com; then echo ok; else echo broken; fi
}

# 2. Can the first sector of the host disk be read through a device node?
#    disk_probe builds the command; the two checks run it in a container.
disk_probe() {
  probe="rm -f /tmp/acc-disk; mknod /tmp/acc-disk b $major $minor \
2>/dev/null; if dd if=/tmp/acc-disk of=/dev/null bs=512 count=1 2>/dev/null \
|| dd if=$disk of=/dev/null bs=512 count=1 2>/dev/null; \
then echo readable; else echo blocked; fi"
}

c_disk_sidecar() {
  docker exec "$name" sh -c "$probe"
}

c_disk_nested() {
  inner run --rm --privileged --entrypoint sh "$dind" -c "$probe"
}

# 3. Runner (uid 1001) and a nested container share the workspace volume.
c_workspace() {
  docker run --rm -u 1001:1001 -v "$vol:$ws" --entrypoint sh "$runner" \
    -c "echo runner > $ws/from-runner" || return 0
  inner run --rm -u 1001:1001 -v "$ws:$ws" --entrypoint sh "$dind" \
    -c "grep -q runner $ws/from-runner && echo side > $ws/from-side" ||
    return 0
  docker run --rm -u 1001:1001 -v "$vol:$ws" --entrypoint sh "$runner" \
    -c "grep -q side $ws/from-side && stat -c %u:%g $ws/from-side"
}

# 4. Files written into the cache keep their owners on the host, also those
#    of the collect step, which runs as root.
c_cache() {
  rm -f "$work/u/by-user" "$work/r/by-root"
  inner run --rm -u 1001:1001 -v "$work:$work" --entrypoint touch "$dind" \
    "$work/u/by-user" || return 0
  inner run --rm --user 0 -v "$work:$work" --entrypoint touch "$dind" \
    "$work/r/by-root" || return 0
  stat -c %u:%g "$work/u/by-user" "$work/r/by-root" | tr '\n' ' '
}

# 5. A user plus network namespace in the builder image, as bitbake does it
#    to cut the network of a task.
userns='
import ctypes, os
libc = ctypes.CDLL(None, use_errno=True)
uid, gid = os.getuid(), os.getgid()
if libc.unshare(0x10000000 | 0x40000000) != 0:
    print("no: unshare errno", ctypes.get_errno())
else:
    try:
        open("/proc/self/uid_map", "w").write("%d %d 1" % (uid, uid))
        open("/proc/self/setgroups", "w").write("deny")
        open("/proc/self/gid_map", "w").write("%d %d 1" % (gid, gid))
        print("works")
    except OSError as e:
        print("no:", e.strerror)
'
c_userns() {
  inner run --rm -u 1001:1001 --entrypoint python3 "$builder" -c "$userns"
}

# The checks of one isolation, results in the variables r_*.
suite() {
  echo
  echo "== sidecar with $1"
  start_sidecar "$1"
  r_net=$(c_net)
  r_ds=$(c_disk_sidecar)
  r_dn=$(c_disk_nested)
  r_ws=$(c_workspace)
  r_cache=$(c_cache)
  r_userns=$(c_userns)
}

# Without the word --run only the explanation is printed.
if [ "${1:-}" != --run ] || [ "$#" -ne 1 ]; then
  sed -n '3,/^set /p' "$0" | sed '$d; s/^# \{0,1\}//'
  exit 2
fi

# Prerequisites: root, a build host, Sysbox known to Docker, no leftovers.
[ "$(id -u)" = 0 ] || die "run as root"
grep -q -e '^POOL=trusted$' -e '^POOL=untrusted$' "$envf" 2>/dev/null ||
  die "no runner settings in $envf: this is not a build host"
runtimes=$(docker info --format \
  '{{range $n, $_ := .Runtimes}}{{$n}} {{end}}') || die "no docker"
case " $runtimes " in
  *" sysbox-runc "*) ;;
  *) die "Docker does not list sysbox-runc: install it first" ;;
esac
if docker inspect "$name" >/dev/null 2>&1; then
  die "$name exists already: another run, or a leftover"
fi

# Images as the slots use them, the cache location and the host disk.
runner=$(sed -n 's/^RUNNER_IMAGE=//p' "$envf")
dind=$(sed -n 's/^DIND_IMAGE=//p' "$envf")
cache=$(sed -n 's/^CACHE_DIR=//p' "$envf")
builder=ghcr.io/dl9pf-agl/agl-ci/builder@$(tr -d '[:space:]' \
  <"$repo/ci/builder.digest")
[ -n "$runner" ] && [ -n "$dind" ] || die "no images in $envf"
disk=$(findmnt -no SOURCE /) || die "cannot find the root disk"
numbers=$(lsblk -dno MAJ:MIN "$disk" | tr -d ' ')
major=${numbers%:*}
minor=${numbers#*:}
[ -n "$major" ] && [ -n "$minor" ] || die "no device numbers for $disk"
dd if="$disk" of=/dev/null bs=512 count=1 2>/dev/null ||
  die "the host itself cannot read $disk: the disk check would prove nothing"
disk_probe

# A new folder beside the cache (same file system), removed at the end.
work=$(mktemp -d "${cache:-/srv/agl-cache}.acceptance.XXXXXX") ||
  die "cannot create the test folder"
trap cleanup EXIT
chmod 0755 "$work"
install -d -m 0755 -o 1001 -g 1001 "$work/u"
install -d -m 0755 "$work/r"

# First the baseline: today's privileged sidecar.
suite --privileged
echo
expect "baseline: nested container reaches the network" "$r_net" ok
expect "baseline: disk readable from the sidecar" "$r_ds" readable
expect "baseline: disk readable from nested privileged" "$r_dn" readable
expect "baseline: workspace shared, owner" "$r_ws" 1001:1001
expect "baseline: cache owners" "$r_cache" "1001:1001 0:0 "
echo "      baseline: user and network namespace: $r_userns"
base_userns=$r_userns
drop_sidecar

# Then Sysbox, with the same checks and the core_pattern probe.
suite --runtime=sysbox-runc
before=$(cat "$core")
docker exec "$name" sh -c \
  'echo agl-probe > /proc/sys/kernel/core_pattern' >/dev/null 2>&1
inner run --rm --privileged --entrypoint sh "$dind" -c \
  'echo agl-probe > /proc/sys/kernel/core_pattern' >/dev/null 2>&1
after=$(cat "$core")
if [ "$after" != "$before" ]; then
  printf '%s\n' "$before" >"$core"
  r_core=CHANGED
else
  r_core=unchanged
fi
echo
expect "sysbox: nested container reaches the network" "$r_net" ok
expect "sysbox: disk blocked from the sidecar" "$r_ds" blocked
expect "sysbox: disk blocked from nested privileged" "$r_dn" blocked
expect "sysbox: core_pattern of the host" "$r_core" unchanged
expect "sysbox: workspace shared, owner" "$r_ws" 1001:1001
expect "sysbox: cache owners" "$r_cache" "1001:1001 0:0 "
expect "sysbox: namespace as in the baseline" "$r_userns" "$base_userns"

# A hang of sysbox-fs leaves container processes in state D. Disk threads of
# the kernel are in D now and then, so only container processes count.
stuck=$(ps -eo state=,comm= |
  awk '$1 == "D" && /sysbox|runc|docker|containerd/' | wc -l)
expect "no container process in state D" "$((stuck))" 0

echo
[ "$fail" = 0 ] || die "acceptance FAILED; the runner slots were not touched"
echo "SYSBOX ACCEPTANCE PASSED (runner slots not touched)"
