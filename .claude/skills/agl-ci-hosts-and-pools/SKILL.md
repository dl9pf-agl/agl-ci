---
name: agl-ci-hosts-and-pools
description: How the AGL CI build hosts and runner pools work (kit/deploy.sh, update.sh, run-loop.sh, agl-runner@N systemd slots, runner.env, trusted agl-pr vs untrusted agl-fork pool, JIT runners, cache dir) and how to diagnose a host that is quiet, queued, full or "offline". Consult BEFORE touching kit/*, updating or restarting a host, or concluding that a runner is missing or a job is stuck.
---

# Hosts and pools (agl-ci kit)

Verified behaviour from the kit and from running it. Chapter 05 of `docs/manual` is the long form; this is the part that bites.

## Model
- **Limits:** two containers per slot, two sets of limits. `MEM_LIMIT_RUNNER`/`CPU_LIMIT_RUNNER` (24g, 8) bound the runner container; `MEM_LIMIT_SIDECAR`/`CPU_LIMIT_SIDECAR` (default none) bound the Docker sidecar, where `kas-container`'s build container actually runs. The runner limit alone does not bound a build. Old names `MEM_LIMIT`/`CPU_LIMIT` are read as RUNNER values. Chapter 05, "Limits of a slot".
- **Lint slots:** `LINT_SLOTS` (default 1) extra slots after the pool slots, label `agl-lint` (trusted) or `agl-fork-lint` (untrusted), 4g/2 CPUs, no cache or hash server; only `repo-lint.yml` targets them. Update hosts before moving a caller's pin of `repo-lint.yml`, else the lint job queues (chapter 05, "Lint slots").
- A host serves **one pool**: `trusted` (label `agl-pr`: same-repo PRs, push, nightly, release) or `untrusted` (label `agl-fork`: fork PRs). Never both (`deploy.sh` refuses; `FORCE_POOL_CHANGE=1` + empty `CACHE_DIR` to move).
- Per slot (`systemctl agl-runner@N`, `run-loop.sh`): own network, workspace volume and a privileged `docker:dind` sidecar, then an unprivileged runner container with a **single-use JIT config**. One job, then the container exits and the loop registers a new one. The long-lived `GH_TOKEN` stays on the host (`/etc/agl-runner/runner.env`).
- `deploy.sh` copies `run-loop.sh` and the unit to `/opt/agl-runner` and `/etc/systemd/system` (root-owned snapshot of a reviewed commit). Editing the checkout changes nothing until `deploy.sh` runs.
- `CACHE_DIR` (default `/srv/agl-cache`, `root:root 0700`; `sstate/` and `dl/` owned by uid 1001) is read-write for all slots of a trusted host and is the mirror source. An untrusted host has a private cache and reads the mirror over the network (`MIRROR_URL`).
- Hash server: `HASHSERV_RW` only on trusted hosts, `HASHSERV_UPSTREAM` only on untrusted ones; `deploy.sh` refuses the wrong one.

## Commands
- Update: `./kit/update.sh` (git pull --ff-only, deploy, restart all slots). Token, `POOL`, `MIRROR_URL`, `CACHE_DIR`, `SLOTS`, limits are kept from the last deploy. New image: put the digest in `kit/runner.digest` first.
- Status: `systemctl status 'agl-runner@*'`, `journalctl -u agl-runner@1 -n 40`, `docker ps`.
- GitHub's view: `gh api orgs/dl9pf-agl/actions/runners --jq '.runners[]|"\(.name) \(.status) busy=\(.busy)"'`.

## Traps
- **An update or restart kills the job in progress.** Look at the Actions tab first.
- **A runner is "missing" for minutes after every job.** After a job the container exits ("Runner listener exit with 0 return code, stop the service, no retry needed", "Removed .credentials/.runner" are normal), the loop cleans up and registers the next one. After a 10 h build the gap was ~27 min. An org listing taken in that gap shows no runner; look again, and read the journal before calling it an outage. (The cleanup of the workspace volume is the likely reason; not verified.)
- **Slots are few.** Two slots: two cold builds block everything else, including the nightly. Queued jobs fail after 24 h in the queue.
- **Job limit is 24 h** (`timeout-minutes: 1440` in `layer-ci.yml`, from the caller's pinned agl-ci). A hung job holds a slot that long. Older pins still have 10 h.
- **Failing fast is deliberate.** If the runner container dies in under 30 s the loop deletes the registration and backs off (30 s steps up to 10 min), so a broken engine cannot flood the org with stale registrations.
- **`runner.env` keeps the mode and group of an existing file** (`cat >` into it). A host set up earlier can have another group or mode (for example `0640` with a non-root group) instead of the `0600 root:root` the kit would create; check `ls -l /etc/agl-runner/` after a first deploy and tighten it. The service runs as root, so a looser mode does not break it, but the file holds the org token.
- **`ps` shows the `JITCONFIG` of a live runner** in the container arguments. It is single-use, but do not paste `ps` output into issues or chat.
- **A fork job on a trusted host fails by design:** the runner image's job-started hook refuses it (`agl-hook: job refused: ...` in the `Set up runner` log). `run-loop.sh` passes `AGL_POOL=$POOL`; the hook is `docker/runner/job-started.sh`, tested by `docker/runner/job-started_test.sh`. If every job on a trusted host fails at once right after an update, look at that log line first (the hook fails closed when it cannot read the event).
- **`RUNNER_GROUP_ID=1` is hardcoded** (the `Default` group, open to every workflow). Restricting the trusted pool to agl-ci's workflows needs a per-pool group: open item M21.
- Stale state after a crash: stop the slots, remove `agl-[rd]N` containers, `agl-nN` networks and `agl-wN` volumes (patterns leave `agl-mirror` alone), delete offline registrations. Exact commands: manual chapter 05, "Reset and re-setup".
- The trusted host also runs the mirror web server (`./kit/mirror/run.sh`, container `agl-mirror`); restart it after an update that changes `kit/mirror/`.

## Before you change the kit
Run `scripts/lint.sh` (actionlint, zizmor, shellcheck on the scripts, the matrix test) and, by hand, `checkbashisms` and `bash -n` (not part of lint.sh). Keep the manual in the same commit. Never commit a host address (the development mirror IP is temporary and private to the dev cycle).
