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
   Options (env): `GH_ORG`, `SLOTS`, `ENGINE`, `LABELS` (default by pool: `agl-pr` or `agl-fork`; `agl-kvm` reserved for jobs that need KVM), `MEM_LIMIT`,
   `CPU_LIMIT`, `DIND=0|1` (default 1), `RUNNER_DIGEST`, and for the pool `POOL`, `MIRROR_URL` (see "Pools").
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
`agl-pr`: pull-request and push builds (default of the kit, used by `runner-smoke.yml`). `agl-fork`: pull requests from forks, on untrusted hosts only (see "Pools"). `agl-kvm`: reserved for jobs that need `/dev/kvm`. Changing labels on an existing host: edit `LABELS=` in `/etc/agl-runner/runner.env`, `systemctl restart agl-runner@N`.

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
| Config, token, pool | `/etc/agl-runner/runner.env` (root, 0600): `ENGINE GH_ORG GH_TOKEN RUNNER_GROUP_ID LABELS POOL MIRROR_URL MEM_LIMIT CPU_LIMIT DIND CACHE_DIR SLOTS RUNNER_IMAGE DIND_IMAGE` (a plain update keeps all of them; give a variable in the environment to change it) |
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
| Change the number of slots | `SLOTS=3 ./kit/update.sh` (surplus slots are disabled) |
| New runner image | merge the digest into `kit/runner.digest`, then `./kit/update.sh` |
| Change limits | `MEM_LIMIT=32g CPU_LIMIT=12 ./kit/update.sh` |
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
| Jobs stay queued | no runner with the job's label: fork pull requests need an `agl-fork` host, everything else `agl-pr`; or all slots are busy (two cold demo builds block every other job, lint included; GitHub cancels a job that waits 24 hours) | set up the missing role; check `LABELS`; wait, or add a slot (`SLOTS=3 ./kit/update.sh`) |
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

## Open points
`/dev/kvm` inside nested kas containers; necessity of `seccomp=unconfined`; Podman path untested. (The old bare-host test runner
was removed from the org.)
