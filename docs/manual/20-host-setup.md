# 20 Host setup and update (one script per role)

*Read this if you set up a new machine, bring an existing one up to date, or move a build host to Sysbox.*

Status: **implemented**, tested with stubs (`kit/host_test.sh`, `kit/sysbox_test.sh`). **Not run on a real host yet**
(2026-11-27). Start every real host with `--check`. The manual steps behind the scripts stay in chapters 05, 15, 18 and 19.

## 1 Which script on which machine
| Machine | Script in `kit/` | Pool, labels | Never on this machine |
|---|---|---|---|
| Trusted build host | `trusted-pr-install-host.sh` | `trusted`: `agl-pr`, `agl-lint` | the download server cron |
| Untrusted build host (fork pull requests) | `untrusted-fork-pr-install-host.sh` | `untrusted`: `agl-fork`, `agl-fork-lint` | a read-write hash server, an rsync daemon |
| Download server (mirror, releases, nightlies) | `download-server-install-host.sh` | none | runner slots, the builder's prune cron |

A machine has one role. A script that finds signs of another role stops before it changes anything on the host (`--run` pulls
the checkout first; section 6).

The scripts share `kit/host-lib.sh` and do the work by calling the parts of the kit: `deploy.sh` (runner slots), `sysbox.sh`
(Sysbox), `mirror/rsyncd.sh`, `mirror/run.sh`.

## 2 Calling a script
Run it as root from a git checkout of agl-ci on the host (the existing hosts have it in `/root/agl-ci`).

| Call | Does |
|---|---|
| `kit/<script>` | prints the usage, changes nothing, exit 2 |
| `kit/<script> --help` | prints the usage, exit 0 |
| `kit/<script> --check` | fetches the checkout's upstream and reports what differs; changes nothing on the host |
| `kit/<script> --run [token-file]` | pulls the checkout (`git pull --ff-only`), then changes what differs |

`--check` compares the host against **the checkout as it is**. If the checkout is behind, it says so; run `git pull --ff-only`
first to see the report for the current kit. `--run` pulls by itself and starts the new version of the script.

Both modes refuse a checkout with local changes. On a host without Docker, `--check` stops after the Docker step: the later
steps cannot be looked at.

Settings are given as environment variables: `sudo MIRROR_URL=https://mirror.example.org kit/<script> --run`. The token file
is only needed on a new build host (or to replace the token); without it `deploy.sh` reuses the stored token or asks.

### Reading the report
| Word | Meaning |
|---|---|
| `ok` | current already |
| `changed` | was not current, is now (`--run`) |
| `differs` | not current (`--check`) |
| `pending` | cannot be done now: a runner slot runs a job. Run the script again later |
| `TODO` | a person has to do it; the script never does it |
| `note` | information, for example listening ports |

Indented lines under `differs` (and before a change) say why: which file, setting, folder or container property differs. For
a file the first 20 lines of the difference are shown (`<` kit, `>` this host). Settings of `runner.env` are named, their
values are not shown.

The last lines count them. Exit status: **0** current with this checkout, **3** something differs or is pending, **1** a step
failed or the host does not fit the role, **2** wrong usage. `TODO` lines do not change the exit status: read them.

## 3 Before the first run on a new machine
1. Debian 13 with systemd, root access, network to GitHub and GHCR (chapter 05, "Host requirements"). If `/` is small, move
   Docker's data root and the cache first (chapter 05, "Storage on another file system").
2. A WireGuard tunnel between a trusted builder and the download server (chapter 18). The scripts do not create it.
3. Firewall (`ufw`), IPv4 **and** IPv6 (chapter 18, "IPv6"). The scripts do not change it.
4. Build hosts: the GitHub organisation token (chapter 05, "Before the first deploy").
5. `git clone https://github.com/<org>/agl-ci /root/agl-ci`.

**Root runs scripts straight from this checkout** (the cron files of a trusted builder and of the download server). It, and
every folder above it, must belong to root and be writable by root only; the scripts print a `TODO` otherwise. The cron files
name it `/root/agl-ci` when that path is the checkout or links to it, else its real path.

## 4 The three roles

### 4.1 Trusted build host
```
cd /root/agl-ci
sudo SLOTS=2 MIRROR_URL=http://<server>:8080 HASHSERV_RW=<server>:9393 \
     RSYNCD_BIND=<own tunnel address> RSYNCD_ALLOW=<server tunnel address> \
     kit/trusted-pr-install-host.sh --run /root/token
```
An existing host needs no variables: `sudo kit/trusted-pr-install-host.sh --run`.

| Step (as printed) | Current when | Change |
|---|---|---|
| checkout is up to date | no commits behind | `git pull --ff-only` |
| packages | `curl jq ca-certificates git rsync` installed | `apt-get install` |
| Docker is installed and running | `docker info` works | installs `docker.io`, enables the service |
| SCTP module blocked | `/etc/modprobe.d/disable-sctp.conf` holds the line | writes it (chapter 18) |
| build node tuning | only looked at with `NODE_TUNING=1` or when installed: file equals the kit's | installs it, `sysctl --system` |
| Sysbox installed | only with `SIDECAR_RUNTIME=sysbox-runc`: runtime listed, services active | `kit/sysbox.sh` (section 5) |
| runner kit deployed | loop script, unit, image digests, pool and every **given** setting equal; slot units enabled | `kit/deploy.sh` |
| slot N | running, and started after the loop script and settings were written | `systemctl restart`, **only without a job** |
| nightly and staging areas | both folders exist in the cache | creates them (root) |
| builder cron | `/etc/cron.d/agl-builder` equals `kit/builder.cron` (with this checkout's path) | installs it |
| rsync daemon | running, pinned image, current `rsyncd.conf`, mounts, bind and allow | `kit/mirror/rsyncd.sh` (a running pull is cut off) |

The rsync daemon's settings are stored only in the container: the script reads them from there, a variable overrides. With
no container and no variables, or a bind address that no interface has (tunnel down), it prints a `TODO` and leaves it.

### 4.2 Untrusted build host
```
sudo SLOTS=1 MIRROR_URL=https://mirror.example.org HASHSERV_UPSTREAM=<server>:9494 \
     kit/untrusted-fork-pr-install-host.sh --run /root/token
```
The steps are those of 4.1 from "checkout" to "slot N" with packages `curl jq ca-certificates git`. No cron, no rsync daemon.
Without `MIRROR_URL` it prints a `TODO`: fork builds then start cold.

### 4.3 Download server
```
sudo kit/download-server-install-host.sh --run     # first run: writes promote.env and asks you to fill it
sudo editor /etc/agl-release/promote.env           # BUILD_RSYNC, check the other values
sudo kit/download-server-install-host.sh --run     # installs the cron
```
| Step (as printed) | Current when | Change |
|---|---|---|
| checkout, packages, Docker, SCTP | as above (packages also `tar util-linux`) | as above |
| cosign | `/usr/local/bin/cosign` has the pinned sha256 | downloads and checks the pinned version |
| promote.env exists | the file exists | copies the example (mode 0600). An existing file is never changed |
| published tree | `dl sstate git staging release nightly` under `RELEASE_ROOT` (default `/srv/agl-permanent`) | creates them |
| clones | `agl-ucb` (`RELEASE_UCB_DIR` and `/root/agl-ucb`), `/root/src-meta-agl`, `-demo`, `-devel` | `git clone` |
| server cron | `/etc/cron.d/agl-server` equals `kit/server.cron`, no older cron file left | installs it and **moves** `agl-release`, `agl-pull-sync`, `agl-git-mirrors` to `/var/backups/agl-cron.<time>/` |
| mirror web server | running, pinned image, current nginx files, all mounts | `kit/mirror/run.sh` (short outage); port and host networking are kept |

The cron is not installed while `promote.env` still holds the placeholder `PRIVATE-ADDRESS`. A mirror that serves TLS and is
not current is **left as it is** unless `TLS_CERT` and `TLS_KEY` are given (`kit/mirror/certbot.sh`, chapter 15). Reported
only: missing release keys, a hash server that is stopped or has no restart policy, a missing `DOCKER-USER` drop rule.

## 5 Sysbox on a build host
`SIDECAR_RUNTIME=sysbox-runc` runs the Docker sidecar of each slot under Sysbox instead of `--privileged` (chapter 05,
"Sysbox sidecar": what changes, risks, what the installation does). Move a fleet one host at a time, the untrusted host
first.

| # | Step | Command | Slots touched? | Go on when |
|---|---|---|---|---|
| 1 | Look | `kit/<role script> --check` | no | the report is understood |
| 2 | Install | `sudo kit/sysbox.sh` | no | `sysbox: OK (uid_map: 0 <not 0> ...)` |
| 3 | Accept | the checks below, in throw-away containers | no | all pass |
| 4 | Switch | `sudo SIDECAR_RUNTIME=sysbox-runc kit/<role script> --run` | idle slots restart | `docker inspect agl-d1 --format '{{.HostConfig.Runtime}}'` prints `sysbox-runc` for each |
| 5 | Build | one real image build on the host | | it passes |
| 6 | Watch | several days of normal load | | no process in state `D`, no stuck container |

**Back out at any point:** `sudo SIDECAR_RUNTIME= kit/<role script> --run` (the empty value counts). The package may stay;
to remove it: `apt-get purge sysbox-ce`, then restore `/etc/docker/daemon.json.agl-before-sysbox` if wanted.

**Acceptance checks** (step 3). Run each once in a privileged sidecar (today's setup, to prove the check can see a
difference) and once under `sysbox-runc`. A script for this is not part of the kit yet.

| Check | Privileged | Sysbox must |
|---|---|---|
| A nested container on the inner bridge resolves names and reaches the network | works | work |
| Read the first sector of the host disk, from the sidecar and from a nested `--privileged` container | readable | be blocked |
| Change `kernel.core_pattern` from inside, compare on the host (restore it if it changed) | do not try | leave the host unchanged |
| Runner (uid 1001) and a nested container read and write the workspace volume | works | work |
| Files written into the cache as uid 1001 and as `--user 0` keep these owners on the host | yes | yes |
| A user plus network namespace in the builder image (bitbake cuts a task's network with it) | note the result | same result |

## 6 Refusals and failures
A script that stops prints `STOPPED: ...` (the host scripts) or `sysbox: ...`.

| Message | Cause | What to do |
|---|---|---|
| `this host is in the ... pool` | the script of the other build role | use the right script; changing a pool is chapter 05, reset 6 |
| `this host is a download server` | `/etc/cron.d/agl-server` exists | build roles never go on the server |
| `runner slots are active here` | server script on a builder | `systemctl disable --now 'agl-runner@*'` first, if this really becomes the server |
| `/etc/cron.d/agl-builder is installed` | the prune cron would delete staged releases | remove it, after checking why it is there |
| `... has local changes` | the checkout was edited | look at `git status`, move the changes away |
| `git pull --ff-only failed` | the checkout diverged | fix the checkout |
| `<step>: still not current after the change` | the change ran and the check still fails | read the output above; run `--check` |
| `slot N would be removed but runs a job` | smaller `SLOTS` or `LINT_SLOTS` | wait until the slot is idle |
| `a trusted host uses HASHSERV_RW` / `an untrusted host never gets HASHSERV_RW` | wrong hash server setting | give the right one (chapter 14) |
| `an rsync daemon runs here` | untrusted host offers its cache | remove the container `agl-rsyncd` after checking |
| `the mirror uses the network ...` | `MIRROR_NETWORK` differs from the running mirror | leave the variable out, or follow the printed steps |
| `the TLS file ... is not what the mirror serves` | `TLS_CERT` or `TLS_KEY` differ from the served copy | leave them out, or follow the printed steps |
| `TLS_CERT and TLS_KEY must both be given and readable` | one is missing or unreadable | give both |
| `sysbox: a job is running in agl-rN` | installation while a job runs | try again later |
| `sysbox: apt would remove or upgrade packages` | installing needs more than new packages | look at the list; do not force it |
| `sysbox: installation failed, daemon.json restored` | the package install failed | read the apt output above |
| `sysbox: the host changed (< before, > after)` | containers, networks, firewall or ports differ | compare the lines. A slot that finished a job shows up too. **A second run does not compare again** |
| `sysbox: overlapping ranges in ...` | two accounts share subordinate ids | fix `/etc/subuid`, `/etc/subgid` |
| `sysbox: root in a Sysbox container is root on the host` | no user mapping | do not use this host with Sysbox; report it |

## 7 What no script changes
The WireGuard tunnel, `ufw` and `DOCKER-USER` rules, the hash server container, TLS certificates, release keys, GitHub
tokens and organisation settings, runner registrations, the cache contents. Kernel and package updates of the host are in
chapter 18 ("Host CVE watch").

## 8 Settings
**A changed port** (`RSYNCD_PORT`, mirror `PORT` or `TLS_PORT`) makes the container count as out of date; `--run` creates it again
and prints where the old port is still written: `BUILD_RSYNC` in `promote.env` on the download server, `ufw`, `MIRROR_URL` in
`runner.env` of the build hosts.

**The mirror's network and TLS files are never changed by the script.** A `MIRROR_NETWORK`, `TLS_CERT` or `TLS_KEY` that differs
from the running mirror stops it before any change, in `--check` and `--run`, and prints the commands to do it by hand. A
certificate that is renewed in place is noticed only when `TLS_CERT` and `TLS_KEY` are given; `mirror/certbot.sh renew`
restarts the mirror itself (chapter 15); on a download server give it `MIRROR_ROOT`, or the restarted mirror serves the
cache directory of a builder.

Build hosts keep them in `/etc/agl-runner/runner.env` (root only; never print it, it holds the token). A variable that is not
given keeps the stored value. All variables and defaults: the header of `kit/deploy.sh`; the limits: chapter 05.

| Variable | Role | Stored in |
|---|---|---|
| `SLOTS`, `LINT_SLOTS`, `LABELS`, limits | build | `runner.env` |
| `MIRROR_URL`, `GIT_MIRROR` | build | `runner.env` |
| `HASHSERV_RW` / `HASHSERV_UPSTREAM` | trusted / untrusted | `runner.env` |
| `SIDECAR_RUNTIME` | build | `runner.env` |
| `CACHE_DIR` | build | `runner.env` |
| `RSYNCD_BIND`, `RSYNCD_ALLOW`, `RSYNCD_PORT` | trusted | the `agl-rsyncd` container |
| `NODE_TUNING=1` | build | the installed sysctl file |
| `BUILD_RSYNC`, `RELEASE_ROOT`, ... | server | `/etc/agl-release/promote.env` |
| `TLS_CERT`, `TLS_KEY`, `PORT`, `MIRROR_NETWORK` | server | the `agl-mirror` container |
