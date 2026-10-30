# 05 Runner setup (Debian 13 host)

*Read this if you set up, update, repair or retire a build host.*

Status: running on the trusted build host since 2026-10-22 (kit in `kit/`, pulls and verifies the signed runner image;
`kit/runner.digest` pinned to a verified publish). An untrusted host (label `agl-fork`) is online and the mirror web server
(`kit/mirror/`) runs on the trusted host. The runbook below covers setup, daily use, reset and troubleshooting.

## What the kit does
`kit/deploy.sh` (systemd + Docker/Podman, run from a checkout of this repo):
1. Reads the pinned runner digest from `kit/runner.digest` (or env `RUNNER_DIGEST`).
2. Installs a sha256-pinned `cosign` if missing, runs `cosign verify` with the CI identity from
   `policy/project.env`, pulls `ghcr.io/<owner>/agl-ci/runner@<digest>`. Nothing is built on the host.
3. Writes `/etc/agl-runner/runner.env` (0600; token only here), installs `run-loop.sh` and the systemd unit,
   starts `agl-runner@N`.
Per job (`run-loop.sh`): private network, workspace volume and sidecar are prepared and health-checked FIRST; only then the JIT registration (single-use config) is requested, so a broken engine registers nothing. Details: private network, workspace volume (owned by uid 1001),
privileged `docker:dind` sidecar pinned by digest (`DIND_IMAGE` in `docker/pins.env`) and an unprivileged runner
container using it via `DOCKER_HOST`. All removed after the job. `DIND=0`: no sidecar, kas runs directly in the
runner image and `/dev/kvm` goes straight to the container.

## Before the first deploy (GitHub side and runner image)
Done once per organisation. The commands on the host itself are in the Runbook below ("First setup").

1. GitHub: org `dl9pf-agl`; Settings > Actions > General: fork PR workflows = *Require approval for all external
   contributors*; Runner groups > Default: allow public repositories (only after that); fine-grained PAT, owner
   the org, permission *Self-hosted runners: Read and write*.
2. First publish of the runner image (merge to `main`), then make the GHCR package public once
   (package settings > visibility), otherwise the host needs a pull token.
3. Pin the digest: `echo sha256:... > kit/runner.digest` (PR; the digest is printed by the `publish` job and
   verified by `scripts/verify-release.sh`).
4. On the host: `git clone` this repo, `cd kit && sudo ./deploy.sh /path/to/token-file`.
   Options (env): `GH_ORG`, `SLOTS`, `ENGINE`, `LABELS` (default by pool: `agl-pr` or `agl-fork`; `agl-kvm` reserved for jobs that need KVM), `MEM_LIMIT_RUNNER`,
   `CPU_LIMIT_RUNNER`, `MEM_LIMIT_SIDECAR`, `CPU_LIMIT_SIDECAR` (see "Limits of a slot"), `DIND=0|1` (default 1), `RUNNER_DIGEST`, `LINT_SLOTS` (default 1, see "Lint slots"), and for the pool `POOL`, `MIRROR_URL` (see "Pools").
5. Check: org Settings > Actions > Runners shows an idle runner; run `runner-smoke.yml`; logs
   `journalctl -fu agl-runner@1`. Stop: `systemctl disable --now agl-runner@1`.

## Pools (trusted and untrusted hosts)
**A host serves one pool only; trusted and untrusted never share a physical server** (the privileged DinD sidecar and
the shared kernel make anything else weak). `POOL` is `trusted` (default) or `untrusted`, `SLOTS` is the number of slots
on this host (1..n); a pool can span several hosts.

| Pool | Label | Jobs | `CACHE_DIR` | Mirror |
|---|---|---|---|---|
| trusted | `agl-pr` | pull requests from the repo itself, nightly, push to the default branch, tags, maintainer dispatch | read-write for all slots of the host; this is what the mirror web server serves (chapter 15, `kit/mirror`) | the source itself; `MIRROR_URL` optional (T2 tests) |
| untrusted | `agl-fork` | pull requests from forks, after approval | read-write, private to this host, never served | `MIRROR_URL=https://...` of the trusted mirror, read-only over the network |

Trust assumption: write access to the repo counts as trusted (a same-repo pull request author can already push a branch
and start CI). A fork pull request can only write the cache of an untrusted host, so it cannot reach a release, the
mirror or the hash equivalence database. `MIRROR_URL` reaches the build as `AGL_MIRROR_URL`; the engine then includes `kas/local/mirrors.yml` of agl-ucb
(chapter 15, "Consumer settings").

Set up: the existing host stays as it is (trusted; hosts from before the pools count as trusted). A second machine for
fork pull requests: `POOL=untrusted MIRROR_URL=https://mirror.example/ SLOTS=2 ./kit/deploy.sh <token-file>`. `POOL` and
`MIRROR_URL` are kept by later deploys and `kit/update.sh`; changing the pool of a host needs `FORCE_POOL_CHANGE=1` and
an emptied `CACHE_DIR`. The shared hash server is given with `HASHSERV_RW=host:9393` (trusted hosts) or
`HASHSERV_UPSTREAM=host:9494` (untrusted hosts); `deploy.sh` refuses the wrong one for the pool (chapter 14). `layer-ci.yml` sends fork pull requests to `agl-fork` and everything else to `agl-pr` (chapter 13), so
an untrusted host must exist before fork pull requests can build; until then they wait in the queue. Set the host up
first, then pin the callers to the `layer-ci.yml` that routes.

**Lint jobs use the pools too.** The reusable `repo-lint.yml` (callers: agl-ucb) routes by the same rule: pull request from the
repo and push/dispatch to `agl-pr`, pull request from a fork to `agl-fork`; the decision is in the pinned workflow, not in the
caller. The runner image carries actionlint, zizmor, shellcheck and PyYAML (pinned in `docker/pins.env`, checked by the image
smoke test), so a lint job downloads nothing. A job waits in the queue until a host of its pool is online and runs the new
tools only once the hosts run an image built from this change (`kit/update.sh`). A caller may pass `runner: github` to use a
GitHub-hosted runner instead (it then installs the tools per run). Tested: the image builds locally and the tools and the lint
script of agl-ucb run in it. Tested on GitHub: the images workflow builds the image, and the `lint` job of agl-ucb pull requests
runs on the trusted pool (`agl-pr`). Not tested: a fork pull request of agl-ucb on the untrusted pool.

### Labels
`agl-pr`: pull-request and push builds (default of the kit, used by `runner-smoke.yml`). `agl-fork`: pull requests from forks, on untrusted hosts only (see "Pools"). `agl-lint` and `agl-fork-lint`: the lint slots of a trusted and of an untrusted host (see "Lint slots"). `agl-kvm`: reserved for jobs that need `/dev/kvm`. Changing labels on an existing host: edit `LABELS=` in `/etc/agl-runner/runner.env`, `systemctl restart agl-runner@N`.

## Lint slots
Lint and preparation jobs (`repo-lint.yml`, used by agl-ucb) must not wait behind a cold build that holds both pool slots for a day. So
every host runs `LINT_SLOTS` extra slots (default **1**, 0 turns them off), numbered after the pool slots: with `SLOTS=2` and `LINT_SLOTS=1`
the units are `agl-runner@1` and `@2` (label `agl-pr`) and `@3` (label `agl-lint`). An untrusted host's lint slot has the label `agl-fork-lint`.

A lint slot is the same single-use runner with its own limits and less access: `LINT_MEM_LIMIT_RUNNER` (default 4g), `LINT_CPU_LIMIT_RUNNER` (default 2) and the two `LINT_*_SIDECAR` limits (2g, 2; see "Limits of a slot"),
**no cache directory, no mirror URL, no hash server** (`run-loop.sh`, block "slot role"; tested by `kit/run-loop_test.sh`). It carries no pool
label, so a build cannot land on it, and a lint job cannot land on a pool slot. The pool boundary is unchanged: `AGL_POOL` is passed as before,
so the job-started hook still refuses fork pull requests on a trusted host's lint slot. `LINT_LABELS` overrides the label (not remembered by an update).

`repo-lint.yml` picks `agl-lint` for same-repo pull requests, push and dispatch and `agl-fork-lint` for pull requests from forks. A caller
(agl-ucb) pins that file by SHA, so **update the hosts first, then move the pin**: a pin that names a label no host carries leaves the job
queued. Only `repo-lint.yml` uses the lint slots; `layer-ci.yml` builds and `runner-smoke.yml` stay on the pool slots.

## Limits of a slot
Every slot runs two containers, and each has its own limits:

| Variable | Default | Bounds |
|---|---|---|
| `MEM_LIMIT_RUNNER`, `CPU_LIMIT_RUNNER` | 24g, 8 | the **runner container** (`agl-rN`): the GitHub runner and the steps of the job, including the `kas-container` script |
| `MEM_LIMIT_SIDECAR`, `CPU_LIMIT_SIDECAR` | **none** | the **Docker sidecar** (`agl-dN`): its daemon and every container that `kas-container` starts in it, which is where bitbake runs |
| `LINT_MEM_LIMIT_RUNNER`, `LINT_CPU_LIMIT_RUNNER` | 4g, 2 | the runner container of a lint slot |
| `LINT_MEM_LIMIT_SIDECAR`, `LINT_CPU_LIMIT_SIDECAR` | 2g, 2 | the sidecar of a lint slot |

`kas-container` is a script: it runs in the runner container and calls `docker run` against the sidecar (`DOCKER_HOST` points there), so
the build container it starts is created by the sidecar's daemon and lives below the sidecar, not below the runner. **A limit on the
runner container alone therefore does not bound an image build**; the sidecar limit does. Until this was split, the sidecar had no limit
at all and a build could use the whole machine (by reading `run-loop.sh`; check on a host with `docker inspect agl-r1 agl-d1 --format
'{{.Name}} mem={{.HostConfig.Memory}} cpus={{.HostConfig.NanoCpus}}'` while a job runs, `0` means no limit). The default for the build
slots' sidecar is still none, so a plain update changes nothing there; set it per host, for example for two build slots on a 62 GB, 8 CPU
machine `MEM_LIMIT_SIDECAR=26g CPU_LIMIT_SIDECAR=7 ./kit/update.sh` leaves room for the other slot, the lint slot and the system. A
memory limit that is too low makes the kernel kill bitbake mid-build: the heaviest tasks (Qt, Flutter, WebRTC) need the most.

The old names `MEM_LIMIT`, `CPU_LIMIT`, `LINT_MEM_LIMIT` and `LINT_CPU_LIMIT` are read as the RUNNER values, given on the command line or
stored in an old `runner.env`, so a host keeps its sizes through the first update; the new `runner.env` no longer contains them.
Precedence: given now (new name, then old name), then stored (new name, then old name), then the default. A value takes effect when
the slot service restarts (`update.sh` restarts all of them; `systemctl restart agl-runner@N` kills the job on that slot). `--pids-limit
8192` and `seccomp=unconfined` of the runner container are written in `run-loop.sh` and have no variable.
Tested by `kit/run-loop_test.sh` (which slot gets which limits; the options reach both `docker run` calls) and `kit/deploy_test.sh`
(what a plain update keeps, the old names); not tested on a host yet.

## Build node tuning
Linux already uses all free RAM as page cache, so "more disk cache" is not a switch. What can be tuned is how long **written** data stays in RAM
before it goes to disk, and which kernel caches are given up first. A Yocto build writes millions of small temporary files and deletes most of them
again; with a long write-back window they often never reach the disk, and the file metadata stays cached. `kit/sysctl/90-agl-ci-cache.conf` (six
`vm.*` settings, each explained in the file) does this. The numbers are from the kernel documentation (the dirty ratios are percentages of
*available* memory, free plus reclaimable, not of total memory; `vm.vfs_cache_pressure = 0` is avoided on purpose, the kernel documents out-of-memory
conditions for it). Apply it by hand, on a **build node**, as root; `deploy.sh` does not do it because it changes the whole machine:
```
sysctl -a 2>/dev/null | grep -E '^vm\.(swappiness|vfs_cache_pressure|dirty_)' > ~/sysctl-before.txt     # the old values, for the way back
sudo install -m 0644 kit/sysctl/90-agl-ci-cache.conf /etc/sysctl.d/
sudo sysctl --system
sysctl vm.swappiness vm.vfs_cache_pressure vm.dirty_background_ratio vm.dirty_ratio vm.dirty_expire_centisecs vm.dirty_writeback_centisecs
```
The last command must print the new values (1, 25, 40, 80, 30000, 3000). Things to know:
- Data written **without `fsync`** can be lost on a crash or power failure, up to the 5 minutes of the window. Build output and sstate objects can be
  rebuilt; data that a program flushes with `fsync` is not affected.
- **Not on the cache host** (the machine whose `CACHE_DIR` is the mirror, or that holds the hash database): there the data is the source of truth.
  On today's single trusted host both roles share the machine, so decide there; with separate roles only the builders get the file.
- When the dirty limit is reached, writers wait until the disk has caught up: seconds on NVMe, minutes on spinning disks.
- A container's memory limit (`MEM_LIMIT_SIDECAR`, "Limits") counts the cache it uses; leave room above what the build itself needs.
- **The gain is not measured yet.** A warm gate writes little; the effect belongs to the cold builds. Look at `grep -E 'Dirty|Writeback' /proc/meminfo`
  during a build and compare cold build times before and after.
- Way back: delete `/etc/sysctl.d/90-agl-ci-cache.conf`, then set each old value from `~/sysctl-before.txt` with `sudo sysctl -w name=value` (or
  reboot); deleting the file alone does not change the running values.

## Shared cache (trial)
`deploy.sh` creates `CACHE_DIR` (default `/srv/agl-cache`) with `sstate/` and `dl/`. The parent is `root:root 0700`, the two folders
belong to uid 1001 (see "Host requirements": that is the runner user inside the image, not an account of the host).
`run-loop.sh` bind-mounts it at the same path into the DinD sidecar and the runner container and exports
`AGL_SSTATE_DIR=$CACHE_DIR/sstate`, `AGL_DL_DIR=$CACHE_DIR/dl`; the engine turns them into the kas fragments
`sstate-shared.yml` and `dl-shared.yml` (chapter 13). The sidecar needs the mount too, because `kas-container` runs
in the sidecar's daemon and resolves host paths there.

Default (a trusted host, the trial decision of 2026-10-23): every slot, PR or release, reads AND writes the same cache, so all jobs profit. Known
risk: an approved fork PR can write poisoned sstate that later jobs reuse; concurrent builds share the hash
equivalence database in `sstate/` (sqlite). The routing of fork pull requests to the untrusted pool exists now (see "Pools"; the caller of
`meta-agl`, and those in the open pull requests of demo and devel, pin a `layer-ci.yml` that routes), so the trial exception ends for new runs; whether to rebuild the trusted cache
from scratch once is still to be decided.
Hash equivalence and PR servers: chapter 14. To empty the cache see "Reset and re-setup", step 4 (next build is cold). Size: expect 50-150 GB, check `df -h`.

## Host requirements and what the kit does not assume
- **Needed on the host:** Linux with systemd; Debian or Ubuntu (`deploy.sh` uses `apt-get`, and installs Docker if it is missing);
  root or `sudo`; a rootful Docker (rootless Docker and Podman are untested); network access to GitHub and GHCR; a file system
  for `CACHE_DIR` that supports Unix owners and modes (not a root-squashed NFS); for QEMU boot tests `/dev/kvm` that any user
  can open (the default on systemd distributions). On hosts with SELinux enforcing the bind mounts would need `:z`; not done.
- **Not needed and not assumed:** any particular user or uid on the host. The runner runs as uid 1001 *inside* the signed image;
  no account with that uid has to exist on the host, and an account that happens to have it (or any other uid) gains nothing.
  Reason: Docker does not remap uids, so the numeric owner of the two mounted cache folders is all that connects the container to
  the host. The parent folder `CACHE_DIR` is `root:root 0700`, so no host account can walk into it, and the Docker daemon (root)
  mounts the two folders without walking through the parent. Look into the cache with `sudo`. The per-job workspace is a Docker
  volume under `/var/lib/docker`, which is root-only too.
- **Not hard-coded:** the token file (`deploy.sh` reuses the token of the previous deploy, so `kit/update.sh` needs no path),
  the organisation (`GH_ORG`), the checkout location, the cache location (`CACHE_DIR`), the number of slots (`SLOTS`) and the
  limits. A host with its own values keeps them across updates; the environment of a deploy overrides them.
- **Where the space goes:** two places grow, both on the file system that holds them. `CACHE_DIR` (50-150 GB, see "Shared cache")
  and Docker's data root (default `/var/lib/docker`), which holds the per-job workspace volume with the whole build tree and
  the images of the sidecar. A Yocto build tree is large (measure it after the first build with `docker system df`); plan
  tens of GB per slot, and fewer slots on a small disk. On a host whose big disk is not `/`, move both before the first
  deploy, see "Storage on another file system".
- **Check on a new host:** `sudo -u nobody ls /srv/agl-cache` must say `Permission denied`, and a job must still build.

### Storage on another file system
Example: `/` is small and the big disk is mounted at `/home`. Put the cache and Docker's data root there, as root, before the
first deploy (nothing to move yet):
```
sudo systemctl stop docker docker.socket 2>/dev/null || true
sudo install -d -m 0710 -o root -g root /home/docker
printf '{ "data-root": "/home/docker" }\n' | sudo tee /etc/docker/daemon.json     # merge by hand if the file exists
sudo systemctl start docker
docker info --format '{{.DockerRootDir}}'                                          # must print /home/docker
sudo CACHE_DIR=/home/agl-cache SLOTS=1 ./kit/deploy.sh <token-file>
```
`CACHE_DIR` is stored, so later `kit/update.sh` keeps it. If Docker already holds data, stop it and `rsync -a
/var/lib/docker/ /home/docker/` before starting it again. `/home/docker` must stay `root`-only like `/var/lib/docker`.

## Runbook: setup, daily use, reset
Everything below is run on the host, as a user with `sudo`, from a checkout of this repo (`git clone
https://github.com/dl9pf-agl/agl-ci`; commands are relative to it). `<token-file>` is a file with the org token (fine-grained
PAT, *Self-hosted runners: Read and write*); the kit never prints it and keeps it only in `/etc/agl-runner/runner.env` (0600). It
is needed once per host (and after a complete re-setup); later `kit/update.sh` reuses the stored token.

### Where things live
| What | Where |
|---|---|
| Config, token, pool | `/etc/agl-runner/runner.env` (root, 0600): `ENGINE GH_ORG GH_TOKEN RUNNER_GROUP_ID LABELS POOL MIRROR_URL DIND CACHE_DIR SLOTS LINT_SLOTS LINT_LABELS MEM_LIMIT_RUNNER CPU_LIMIT_RUNNER MEM_LIMIT_SIDECAR CPU_LIMIT_SIDECAR LINT_MEM_LIMIT_RUNNER LINT_CPU_LIMIT_RUNNER LINT_MEM_LIMIT_SIDECAR LINT_CPU_LIMIT_SIDECAR RUNNER_IMAGE DIND_IMAGE` (a plain update keeps all of them; give a variable in the environment to change it) |
| Loop script and unit (root-owned snapshot of a reviewed commit) | `/opt/agl-runner/run-loop.sh`, `/etc/systemd/system/agl-runner@.service` |
| Slot N | systemd `agl-runner@N`; containers `agl-rN` (runner) and `agl-dN` (DinD sidecar), network `agl-nN`, volume `agl-wN` (workspace, removed after every job) |
| Cache | `CACHE_DIR` (default `/srv/agl-cache`, `root:root 0700`): `sstate/`, `dl/` (owner uid 1001, the runner user inside the image) |
| Mirror web server (trusted host) | container `agl-mirror`, files in `kit/mirror/` |
| Logs | `journalctl -fu agl-runner@N`; `docker logs agl-mirror` |

### Host roles
| Role | Pool | Label | Runs |
|---|---|---|---|
| Trusted build host (today's host) | `trusted` | `agl-pr` | same-repo pull requests, nightly, push, release; owns the cache that is the mirror; also runs the mirror web server and, later, the hashserv container (chapter 14) |
| Untrusted build host (second machine) | `untrusted` | `agl-fork` | pull requests from forks only; private cache; reads the mirror over the network |
They are different physical machines. Never put both roles on one host.

### First setup
Trusted host (the existing one already is):
1. `sudo SLOTS=2 ./kit/deploy.sh <token-file>`. It verifies the token, installs Docker if missing, verifies the pinned runner
   image with `cosign`, writes the config, creates `CACHE_DIR`, starts the slots.
2. `CACHE_DIR=/srv/agl-cache ./kit/mirror/run.sh` starts the mirror web server (port 8080).
3. Check (below).

Untrusted host:
1. `sudo POOL=untrusted MIRROR_URL=http://<trusted-host>:8080 SLOTS=2 ./kit/deploy.sh <token-file>`.
2. Check (below). Fork pull requests start to build once the callers pin a `layer-ci.yml` that routes (chapter 13).

### Check after any setup
- `systemctl is-active 'agl-runner@*'` prints `active` per slot; `sudo grep -v TOKEN /etc/agl-runner/runner.env` shows the
  expected `POOL`, `LABELS`, `CACHE_DIR`.
- Org Settings > Actions > Runners: one idle runner per slot, labels `self-hosted Linux X64` plus the pool label.
- Trusted host: `curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8080/dl/` prints `403` (listing off), a real file
  under `$CACHE_DIR/dl` prints `200` (list the folder with `sudo`: it is root-only on the host).
- A real job: a pull request or `workflow_dispatch` of the caller; first build on an empty cache is cold (`agl-image-minimal` about 4.5 hours; the Qt and Flutter demo images take 20 hours or more), the next one warm (about 25 to 30 minutes).

### Updating the runner
Bump pins (chapter 03), merge, wait for publish+verify, put the new digest into `kit/runner.digest`, re-run
`deploy.sh` on the host (it restarts nothing by itself: `systemctl restart agl-runner@N` between jobs).

One command: `kit/update.sh [token-file]` does `git pull --ff-only`, `deploy.sh` with the stored `SLOTS` (2 when none is stored) and restarts
all slots. Why `deploy.sh` copies `run-loop.sh` and the unit to `/opt` and `/etc/systemd`: systemd runs it as root, so
it must not come from a checkout that a `git pull`, a branch switch or a non-root user can change. The copy is a
root-owned snapshot of a reviewed commit; the cost is one `install` line. Alternative (rejected): `ExecStart`
straight from the checkout, which makes every `git pull` an instant root-code change.

### Daily use
| Task | Command |
|---|---|
| Update the host to the current `main` | `./kit/update.sh` (git pull, deploy, restart all slots; token, `POOL`, `MIRROR_URL`, `CACHE_DIR`, `SLOTS` and limits are kept; a host from before this change gets 2 slots; give a variable to change it, a token file argument replaces the stored token) |
| Change the number of slots | `SLOTS=3 ./kit/update.sh` (surplus slots are disabled); lint slots: `LINT_SLOTS=0 ./kit/update.sh` removes them, `LINT_SLOTS=2` adds one |
| New runner image | merge the digest into `kit/runner.digest`, then `./kit/update.sh` |
| Change limits | `MEM_LIMIT_SIDECAR=26g CPU_LIMIT_SIDECAR=7 ./kit/update.sh` (see "Limits of a slot"; restarts the slots) |
| Status | `systemctl status 'agl-runner@*'`, `docker ps` |
| Pause the host | `sudo systemctl stop 'agl-runner@*'` (jobs in progress are killed: wait until the runners are idle) |
| Resume | `sudo systemctl start agl-runner@1 agl-runner@2` |
| Restart the mirror | `./kit/mirror/run.sh` (recreates the container) |

A restart kills the job in progress (the first pilot build died this way). Check the Actions tab before restarting.

### Reset and re-setup, from small to complete
1. **Restart the slots** (changed `run-loop.sh` or `runner.env`): `sudo systemctl restart 'agl-runner@*'`.
2. **Remove stale Docker state** after a crash or kill (the cleanup trap did not run). Stop the slots first:
   ```
   sudo systemctl stop 'agl-runner@*'
   docker rm -f $(docker ps -aq --filter 'name=^agl-[rd][0-9]+$') 2>/dev/null
   docker network rm $(docker network ls -q --filter 'name=^agl-n[0-9]+$') 2>/dev/null
   docker volume rm $(docker volume ls -q --filter 'name=^agl-w[0-9]+$') 2>/dev/null
   sudo systemctl start agl-runner@1 agl-runner@2
   ```
   The patterns leave `agl-mirror` alone.
3. **Remove stale runner registrations** at GitHub (offline entries after a crash; normal jobs remove their own):
   ```
   gh api orgs/dl9pf-agl/actions/runners --paginate -q '.runners[]|select(.status=="offline")|"\(.id) \(.name)"'
   gh api -X DELETE orgs/dl9pf-agl/actions/runners/<id>
   ```
4. **Cold cache** (trusted host: this also empties the mirror and the hash equivalence database, which lives in `sstate/`).
   Stop the slots, `sudo rm -rf $CACHE_DIR/sstate/* $CACHE_DIR/dl/*`, start the slots. Refill: run the caller with
   `mode: fetch`, `tier: dispatch`, then a build or the next nightly. Untrusted host: the same, and nothing else depends on it.
5. **Re-setup the host from scratch** (new OS, broken state). `runner.env` is deleted here, so `POOL` and `MIRROR_URL`
   must be given again:
   ```
   sudo systemctl disable --now 'agl-runner@*'
   (remove stale Docker state as in 2)
   sudo rm -rf /opt/agl-runner /etc/agl-runner /etc/systemd/system/agl-runner@.service && sudo systemctl daemon-reload
   sudo [POOL=untrusted MIRROR_URL=...] SLOTS=2 ./kit/deploy.sh <token-file>
   ```
   Keep `CACHE_DIR` if you want to keep a warm cache; the deploy reuses it.
6. **Change the pool of a host**: only with an emptied cache: `FORCE_POOL_CHANGE=1 POOL=untrusted ./kit/update.sh`. A host
   never serves both pools; prefer re-setting up a different machine.
7. **Decommission a host**: as in 5 without the final deploy, plus `docker rm -f agl-mirror` on the trusted host, `rm -rf
   $CACHE_DIR` if wanted, and delete stale registrations (3).

### Troubleshooting
| Symptom | Cause | Fix |
|---|---|---|
| `deploy.sh`: `token check failed (HTTP 403/404)` | token lacks *Self-hosted runners: Read and write* on the org, or wrong org | new fine-grained PAT, `GH_ORG=...` |
| `deploy.sh`: `this host is trusted; a host never serves both pools` | `POOL` differs from the previous deploy | see reset 6 |
| `deploy.sh`: `kit/runner.digest is empty` / `cosign verify` fails | no published runner image or wrong identity | chapter 04; pin the digest |
| No runner appears in the org | token, group not allowed for public repos, or label typo | `journalctl -fu agl-runner@1`; Runner groups > allow public repositories |
| `sidecar agl-dN never answered` | Docker daemon or `docker:dind` image problem | `docker logs agl-dN`; reset 2; the loop backs off up to 10 minutes |
| Jobs stay queued | no runner with the job's label: fork pull requests need an `agl-fork` host, everything else `agl-pr`; or all slots are busy (two cold demo builds block every other job, lint included; GitHub cancels a job that waits 24 hours) | set up the missing role; check `LABELS`; wait, or add a slot (`SLOTS=3 ./kit/update.sh`); lint jobs of repo-lint.yml need an `agl-lint` slot (or `agl-fork-lint` for fork pull requests), see "Lint slots" |
| The org shows no runner right after a long job | the slot is cleaning up and registers the next runner (about 26 minutes after a 10-hour build) | wait; read `journalctl -u agl-runner@N` before calling it an outage |
| Runner offline entries pile up | crashes | reset 3 |
| `Permission denied` for your own account on `/srv/agl-cache` | intended: the folder is `root:root 0700` | use `sudo` |
| `df` full | cache or Docker data | cache size 50-150 GB; `docker system df`; reset 2 and 4 |
| Offline drill finds misses | cache cold or never fetched | chapter 15: fetch mode, then drill |

## Failure behaviour (run-loop.sh)
- Preparation fails (network, volume, sidecar not answering within ~3 min): cleanup, back off 30 s x failures (max 10 min), no GitHub call.
- Runner container exits within 30 s (never served a job): its registration is deleted via the API, then back off.
- A run longer than 30 s resets the backoff.
Lesson (2026-10-22): the first version requested the JIT config before preparing the sidecar, so a failing engine created one stale runner registration every ~11 s (44 in 6 minutes).

## Security notes
- The sidecar is privileged: a job can start privileged containers in it. Weaker than `DIND=0`.
- Containers share the host kernel; fine for a personal rig, VM-per-job for untrusted PRs at scale.
- Runner container: non-root, default caps, `seccomp=unconfined` (bitbake `unshare()`).
- Bind mounts besides the per-job workspace volume: only `CACHE_DIR` (read-write; one pool per host). The mirror web server mounts it read-only.
- Never run `pull_request_target` workflows on this runner.
- **Job-started hook.** The runner image sets `ACTIONS_RUNNER_HOOK_JOB_STARTED=/opt/agl-hooks/job-started.sh` (root-owned, outside the
  runner directory; source `docker/runner/job-started.sh`). GitHub runs it before the first step of every job and fails the job when it
  exits non-zero. It exists because the workflow file of a fork pull request is the fork's own and can name the label `agl-pr` itself.
  The pool is read from the environment of the container's **first process** (`run-loop.sh` starts the container with `-e
  AGL_POOL=$POOL`; unknown counts as trusted), not from the hook's own environment, which a workflow might be able to fill. On a
  trusted host the hook refuses every pull request whose head repository is not the repository itself, including a deleted fork. A
  pull request is recognised by the `pull_request` object of the payload as well as by the event name, the base repository is the one
  in the payload (no fallback to `GITHUB_REPOSITORY`), the tool path is fixed, and a readable payload is required for every job (fail
  closed). An untrusted host accepts everything; push, schedule, dispatch and release pass on a trusted host because their payload is
  not a pull request. A refused job shows `agl-hook: job refused: ...` in the `Set up runner` log. What it cannot stop: a file that already
  exists in the image used through `GITHUB_EVENT_PATH` or `BASH_ENV`; the container is single-use, a workflow cannot create files before
  the job starts, and the image has no file that would help.
  Tested: 26 cases in `docker/runner/job-started_test.sh` (run by `scripts/lint.sh`), including attempts to tamper with the
  environment of the hook (pool, event name, `PATH`, repository, `BASH_ENV`); shown to fail on six deliberately weakened copies of the
  hook; the image smoke test runs both pools and the tampering inside the built image. **Tested on the real trusted host on 2026-10-29**
  (runner image `sha256:7a9dbcd0…`): a dispatch run and a same-repo pull request pass, and a fork pull request whose three jobs name
  `agl-pr` is refused (details below).

### Verifying the hook on a real host
Do this after the first update of a trusted host, and after every change of the hook. A failure in one of the first three steps is
visible at once (every job on the trusted host fails); the last step is the real attack.
1. `runner-smoke.yml` by dispatch (event `workflow_dispatch`, payload without `pull_request`): must pass.
2. A same-repo pull request with a build (for example a meta-agl pull request): must pass.
3. Read the `Set up runner` log of one of them: no `agl-hook: job refused`. If every job fails with "no readable event payload" or "event
   name is not set", GitHub does not give the hook those variables and the hook needs another source for them.
4. **Attack from a fork.** On the test fork (`dl9pf/meta-agl`, with the owner's permission) put this workflow on a branch and open a
   pull request to the base repository. Every job names the trusted label; the steps only print a line and use no secret. The
   variants try the ways a workflow could get past the hook:
   ```yaml
   name: hook-attack
   on: pull_request
   permissions: {}
   env: {AGL_POOL: untrusted, GITHUB_EVENT_NAME: push, BASH_ENV: /nonexistent}      # workflow level
   jobs:
     plain:      {runs-on: [self-hosted, agl-pr], steps: [{run: echo HOOK-BYPASSED plain}]}
     job-env:
       runs-on: [self-hosted, agl-pr]
       env: {AGL_POOL: untrusted, ACTIONS_RUNNER_HOOK_JOB_STARTED: '', PATH: /tmp:/usr/bin}
       steps: [{run: echo HOOK-BYPASSED job-env}]
     container:  {runs-on: [self-hosted, agl-pr], container: 'debian:trixie-slim', steps: [{run: echo HOOK-BYPASSED container}]}
   ```
   **Pass:** every job fails before its first step with `agl-hook: job refused: pull request from fork dl9pf/meta-agl on a trusted host`,
   and no log contains `HOOK-BYPASSED`. **If any job prints it, the hook is bypassed:** stop the trusted slots, tell the owner, fix the
   hook (the test in `docker/runner/job-started_test.sh` gets the new case first). Then close the pull request and delete the branch.
   GitHub may reject some `env:` names (`GITHUB_*`); a rejected workflow tests less, note which variants ran.

**First run, 2026-10-29 (trusted host on runner image `sha256:7a9dbcd0…`).** 1. `runner-smoke.yml` by dispatch (run 40890281323): passed; the job log shows
`A job started hook has been configured by the self-hosted runner administrator` and `Run '/opt/agl-hooks/job-started.sh'`. 2. A same-repo
`pull_request` (an empty-commit pull request of agl-ucb, closed afterwards, run 40890410309): passed on the trusted pool, same log lines.
3. GitHub does give the hook the event name and a readable payload (dispatch and pull_request): otherwise both jobs would have failed.
4. The attack from the fork `dl9pf/meta-agl` (pull request meta-agl#11, run 40891396519, branch based on the current `master`, `ci.yml` removed
so that no build started): all three jobs reached the trusted host and failed in `Set up runner` with `agl-hook: job refused: pull request from
fork dl9pf/meta-agl on a trusted host (base dl9pf-agl/meta-agl, event 'pull_request')`; no log contains `HOOK-BYPASSED`. The pull request was
closed and the branch deleted. Not known: whether the `env:` values of the workflow reach the hook at all (the refusal does not depend on it).
Not done: a fork job on the **untrusted** host after the hook update, and the test with a second GitHub account.

## Open points
`/dev/kvm` inside nested kas containers; necessity of `seccomp=unconfined`; Podman path untested. (The old bare-host test runner
was removed from the org.)
