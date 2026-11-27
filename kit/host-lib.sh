# shellcheck shell=bash
# SPDX-License-Identifier: MIT
# Shared part of the host scripts, one per role of a machine (agl-ci chapter 05, "Host scripts"):
#   trusted-pr-install-host.sh  untrusted-fork-pr-install-host.sh  download-server-install-host.sh
# Source it; do not run it.
#
# A host script brings a new or an existing host to the state of THIS checkout. It is a list of steps. A step has two functions,
# have_<name> (is the host current? changes nothing) and make_<name> (bring it there). Each step prints one line:
#   ok       current already
#   changed  was not, is now
#   differs  is not current (--check only: nothing is changed)
#   pending  cannot be done now (a job runs in a slot): run the script again later
#   TODO     a person has to do it (secrets, tunnel, firewall rules: never changed here)
# Exit status: 0 current, 3 differs or pending, 1 a step failed or the host does not fit the role, 2 wrong usage.
#
# AGL_ROOT (a prefix for the host paths) and AGL_NO_PULL are for kit/host_test.sh.

R="${AGL_ROOT:-}"
check_only=0; differ=0; pending=0; changed=0; todos=0; token_file=""
pool=""   # trusted | untrusted: set by the script of a build role

die()  { echo "STOPPED: $*" >&2; exit 1; }
line() { printf '%-8s %s\n' "$1" "$2"; }
todo() { line TODO "$1"; todos=$((todos + 1)); }

# A have_ function that returns false says why in $why (one or more lines; never a value of runner.env, it holds secrets).
why=""
show_why() { local indent='           '; [ -z "$why" ] || printf '%s%s\n' "$indent" "${why//$'\n'/$'\n'$indent}"; }

# same_file <wanted file> <installed file>: false, with the difference in $why, when the two are not the same
same_file() {
  [ -f "$2" ] || { why="missing: ${2#"$R"}"; return 1; }
  why="$(diff "$1" "$2")" && return 0
  why="${2#"$R"} (< kit, > this host):
$(head -n 20 <<<"$why")"
  return 1
}

# step "<what>" <name>
step() {
  why=""
  if "have_$2"; then line ok "$1"
  elif [ "$check_only" = 1 ]; then line differs "$1"; show_why; differ=$((differ + 1))
  else
    show_why
    "make_$2"
    why=""
    "have_$2" || { show_why; die "$1: still not current after the change"; }
    line changed "$1"; changed=$((changed + 1))
  fi
}

# The header comment of the script is its help text.
usage() {
  sed -n '4,/^set /p' "$script" | sed '$d; s/^# \{0,1\}//'
  echo "usage: $(basename "$script") --check | --run [token-file]"
}

# host_init "$@": arguments, root, where we are. Without --check or --run only the usage is printed: nothing happens by
# accident. Re-runs itself with sudo (the environment is kept).
host_init() {
  local mode=""
  script="$(readlink -f "$0")"; args=("$@")
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --check|--run) [ -z "$mode" ] || { usage >&2; exit 2; }; mode="${1#--}" ;;
      -h|--help) usage; exit 0 ;;
      -*) usage >&2; exit 2 ;;
      *) token_file="$(readlink -f "$1")" ;;
    esac
    shift
  done
  [ -n "$mode" ] || { usage; exit 2; }
  [ "$mode" != check ] || check_only=1
  [ "$(id -u)" = 0 ] || exec sudo -E "$script" "${args[@]}"
  repo="$(dirname "$(dirname "$script")")"
  command -v apt-get >/dev/null || die "Debian or Ubuntu only (apt-get)"
  # shellcheck source=../docker/pins.env disable=SC1091
  . "$repo/docker/pins.env"
  # shellcheck source=../policy/project.env disable=SC1091
  . "$repo/policy/project.env"
}

# The checkout first: every other step compares the host against it. After a pull the new script takes over.
update_checkout() {
  [ -z "${AGL_NO_PULL:-}" ] || return 0
  [ -z "$(git -C "$repo" status --porcelain --untracked-files=no)" ] || die "$repo has local changes: commit or move them first"
  if [ "$check_only" = 1 ]; then
    if ! git -C "$repo" fetch -q; then todo "cannot fetch: the checkout may be behind"; return 0; fi
    local n; n="$(git -C "$repo" rev-list --count 'HEAD..@{upstream}')"
    if [ "$n" = 0 ]; then line ok "checkout is up to date"
    else line differs "checkout is $n commits behind; the lines below compare against the old checkout"; differ=$((differ + 1)); fi
  else
    local before; before="$(git -C "$repo" rev-parse HEAD)"
    git -C "$repo" pull -q --ff-only || die "git pull --ff-only failed in $repo"
    if [ "$(git -C "$repo" rev-parse HEAD)" != "$before" ]; then
      line changed "checkout updated to $(git -C "$repo" log -1 --format=%h); starting the new script"
      AGL_NO_PULL=1 exec "$script" "${args[@]}"
    fi
    line ok "checkout is up to date"
  fi
}

# --- packages, Docker, kernel settings
have_packages() {
  local p
  for p in $PACKAGES; do
    [ "$(dpkg-query -W -f='${db:Status-Status}' "$p" 2>/dev/null)" = installed ] || { why="not installed: $p"; return 1; }
  done
}
make_packages() {
  apt-get update -qq
  # shellcheck disable=SC2086
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends $PACKAGES
}

have_docker() { docker info >/dev/null 2>&1; }
make_docker() {
  command -v docker >/dev/null || DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends docker.io
  systemctl enable --now docker
}
# Everything after this step needs Docker; with --check on a host without it there is nothing more to compare.
docker_step() {
  step "Docker is installed and running" docker
  have_docker || { todo "no Docker yet: the remaining steps were not looked at"; finish; }
}

sctp_conf() { echo "$R/etc/modprobe.d/disable-sctp.conf"; }
have_sctp() { grep -qx 'install sctp /bin/false' "$(sctp_conf)" 2>/dev/null; }
make_sctp() { install -d -m 0755 "$(dirname "$(sctp_conf)")"; echo 'install sctp /bin/false' > "$(sctp_conf)"; }

tuning_dst() { echo "$R/etc/sysctl.d/90-agl-ci-cache.conf"; }
have_tuning() { same_file "$repo/kit/sysctl/90-agl-ci-cache.conf" "$(tuning_dst)"; }
make_tuning() { install -D -m 0644 "$repo/kit/sysctl/90-agl-ci-cache.conf" "$(tuning_dst)"; sysctl --system >/dev/null; }
# Build node tuning changes the whole machine: only when asked once (NODE_TUNING=1), then kept current (chapter 05).
tuning_step() { if [ "${NODE_TUNING:-}" = 1 ] || [ -f "$(tuning_dst)" ]; then step "build node tuning (sysctl)" tuning; fi; }

# A cron file of the kit, with the path of this checkout. The kit writes /root/agl-ci: that name stays when it is this
# checkout, also through a link (the script itself sees the resolved path).
cron_text() {
  if [ "$R/root/agl-ci" -ef "$repo" ]; then cat "$repo/kit/$1"; else sed "s|/root/agl-ci|$repo|g" "$repo/kit/$1"; fi
}

# Root runs scripts of this checkout from cron: no other user may be able to change them, or to swap one of the folders above
# them. Only reported. AGL_OWNER (one more accepted owner) is for kit/host_test.sh.
checkout_note() {
  local p bad
  p="$(readlink -f "$repo")"
  bad="$(find "$p/kit" ! -type l \( -perm /022 -o ! \( -uid 0 -o -uid "${AGL_OWNER:-0}" \) \) -print -quit)"
  while [ -z "$bad" ] && [ "$p" != / ]; do
    # a folder that others may write is accepted with the sticky bit (/tmp): they cannot rename what is not theirs
    bad="$(find "$p" -maxdepth 0 \( \( -perm /022 ! -perm -1000 \) -o ! \( -uid 0 -o -uid "${AGL_OWNER:-0}" \) \) -print)"
    p="$(dirname "$p")"
  done
  [ -z "$bad" ] || todo "root runs this checkout from cron, but another user can change $bad: move the checkout or fix the owner"
}

# What others can reach. Only reported: firewall rules and the tunnel are not changed by these scripts (chapter 18, "IPv6").
exposure_note() {
  local l
  l="$(ss -Hltn | awk '$4 !~ /^(127\.|\[::1\])/ {print $4}' | sort -u | tr '\n' ' ')"
  line note "listening beyond loopback: ${l:-nothing}"
  if [ -n "$(ip -6 -o addr show scope global)" ]; then
    line note "this host has a global IPv6 address: check every [::] listener and the ufw (v6) rules from outside"
  fi
}

finish() {
  echo
  echo "$changed changed, $differ differ, $pending pending, $todos TODO"
  if [ $((differ + pending)) -gt 0 ]; then exit 3; fi
  echo "current with this checkout"
  exit 0
}

# --- build hosts (the trusted and the untrusted role)
envfile() { echo "$R/etc/agl-runner/runner.env"; }
stored() { sed -n "s/^$1=//p" "$(envfile)" 2>/dev/null || true; }
# val KEY: what the host shall have: the environment when the variable is given (also empty), else what is stored
val() { if [ -n "${!1+x}" ]; then printf '%s' "${!1}"; else stored "$1"; fi; }
cache_dir() { local c; c="$(val CACHE_DIR)"; echo "$R${c:-/srv/agl-cache}"; }

guard_build_host() {   # $1 = trusted | untrusted
  local have; have="$(stored POOL)"
  [ -z "$have" ] || [ "$have" = "$1" ] || die "this host is in the $have pool; use the script of that role (a host never serves both)"
  [ ! -f "$R/etc/cron.d/agl-server" ] || die "this host is a download server (/etc/cron.d/agl-server): never a runner host too"
  [ -f "$(envfile)" ] || [ -n "$token_file" ] || [ -n "${GH_TOKEN:-}" ] || line note "new host: deploy.sh will ask for the GitHub token"
}

have_sysbox() {
  local r s
  r="$(docker info --format '{{range $n, $_ := .Runtimes}}{{println $n}}{{end}}')" || r=""
  grep -qx sysbox-runc <<<"$r" || { why="Docker does not list the runtime sysbox-runc"; return 1; }
  for s in sysbox-mgr sysbox-fs sysbox; do systemctl is-active --quiet "$s" || { why="service $s is not active"; return 1; }; done
}
make_sysbox() { "$repo/kit/sysbox.sh"; }

slot_numbers() {
  local s l; s="$(stored SLOTS)"; l="$(stored LINT_SLOTS)"
  seq 1 $(( ${s:-0} + ${l:-0} ))
}

# The installed runner kit equals this checkout, and every setting given in the environment is the stored one.
have_runners() {
  local k i f
  [ -f "$(envfile)" ] || { why="no runner settings yet (/etc/agl-runner/runner.env)"; return 1; }
  for f in "run-loop.sh:/opt/agl-runner/run-loop.sh" "agl-runner@.service:/etc/systemd/system/agl-runner@.service"; do
    cmp -s "$repo/kit/${f%%:*}" "$R${f#*:}" || { why="${f#*:} is not kit/${f%%:*}"; return 1; }
  done
  [[ "$(stored RUNNER_IMAGE)" == *"@$(tr -d '[:space:]' < "$repo/kit/runner.digest")" ]] ||
    { why="runner image is not the digest of kit/runner.digest"; return 1; }
  [ "$(stored DIND_IMAGE)" = "$DIND_IMAGE" ] || { why="sidecar image is not DIND_IMAGE of docker/pins.env"; return 1; }
  [ "$(stored POOL)" = "$pool" ] || { why="the stored POOL is not $pool"; return 1; }
  for k in GH_ORG ENGINE LABELS LINT_LABELS SLOTS LINT_SLOTS MIRROR_URL GIT_MIRROR HASHSERV_RW HASHSERV_UPSTREAM SIDECAR_RUNTIME \
           DIND CACHE_DIR MEM_LIMIT_RUNNER CPU_LIMIT_RUNNER MEM_LIMIT_SIDECAR CPU_LIMIT_SIDECAR LINT_MEM_LIMIT_RUNNER \
           LINT_CPU_LIMIT_RUNNER LINT_MEM_LIMIT_SIDECAR LINT_CPU_LIMIT_SIDECAR; do
    [ -z "${!k+x}" ] || [ "${!k}" = "$(stored "$k")" ] || { why="the given $k is not the stored one"; return 1; }
  done
  for i in $(slot_numbers); do
    systemctl is-enabled --quiet "agl-runner@$i.service" || { why="agl-runner@$i.service is not enabled"; return 1; }
  done
}
# deploy.sh stops the slots beyond a smaller number at once, so a surplus slot with a job stops this script first.
make_runners() {
  local i s l
  s="$(val SLOTS)"; l="$(val LINT_SLOTS)"
  for i in $(slot_numbers); do
    [ "$i" -le $(( ${s:-1} + ${l:-1} )) ] || ! slot_busy "$i" || die "slot $i would be removed but runs a job: run this script again when it is idle"
  done
  POOL="$pool" "$repo/kit/deploy.sh" ${token_file:+"$token_file"}
}

# A slot is stale when it is not running, or started before the loop script or the settings were last written.
slot_stale() {
  local since written
  systemctl is-active --quiet "agl-runner@$1.service" || return 0
  since="$(TZ=UTC systemctl show -p ActiveEnterTimestamp --value "agl-runner@$1.service")"
  [ -n "$since" ] || return 0
  written="$(stat -c %Y "$R/opt/agl-runner/run-loop.sh" "$(envfile)" | sort -n | tail -1)"
  [ "$(date -d "$since" +%s)" -lt "$written" ]
}
slot_busy() { local p; p="$(docker top "agl-r$1" 2>/dev/null)" && grep -q Runner.Worker <<<"$p"; }

# Restart stale slots, never one with a job.
slots_step() {
  local i any=0
  [ -f "$(envfile)" ] && [ -f "$R/opt/agl-runner/run-loop.sh" ] || return 0
  for i in $(slot_numbers); do
    slot_stale "$i" || continue
    any=1
    if [ "$check_only" = 1 ]; then line differs "slot $i is stopped, or runs an older loop script or older settings"; differ=$((differ + 1))
    elif slot_busy "$i"; then line pending "slot $i runs a job: run this script again when it is idle"; pending=$((pending + 1))
    else systemctl restart "agl-runner@$i.service"; line changed "slot $i restarted"; changed=$((changed + 1)); fi
  done
  [ "$any" = 1 ] || line ok "all slots run the installed loop script and settings"
}

# The steps both build roles share, in order.
build_host_steps() {
  step "packages" packages
  docker_step
  step "SCTP module blocked" sctp
  tuning_step
  if [ "$(val SIDECAR_RUNTIME)" = sysbox-runc ]; then step "Sysbox installed and its services active" sysbox; fi
  step "runner kit deployed as in this checkout (pool $pool)" runners
  slots_step
}
