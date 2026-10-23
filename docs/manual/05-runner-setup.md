# 05 Runner setup (Debian 13 host)

Status: kit moved to `kit/`, pulls and verifies the signed runner image; `kit/runner.digest` pinned to the first verified publish (main run 39761708441). **Untested on the server.** Docker-in-Docker was validated
earlier on a dev host with a locally built image.

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

## Steps
1. GitHub: org `dl9pf-agl`; Settings > Actions > General: fork PR workflows = *Require approval for all external
   contributors*; Runner groups > Default: allow public repositories (only after that); fine-grained PAT, owner
   the org, permission *Self-hosted runners: Read and write*.
2. First publish of the runner image (merge to `main`), then make the GHCR package public once
   (package settings > visibility), otherwise the host needs a pull token.
3. Pin the digest: `echo sha256:... > kit/runner.digest` (PR; the digest is printed by the `publish` job and
   verified by `scripts/verify-release.sh`).
4. On the host: `git clone` this repo, `cd kit && sudo ./deploy.sh /path/to/token-file`.
   Options (env): `GH_ORG`, `SLOTS`, `ENGINE`, `LABELS` (default `agl-pr`; planned `agl-release` for release jobs on their own slots; `agl-kvm` reserved for jobs that need KVM), `MEM_LIMIT`,
   `CPU_LIMIT`, `DIND=0|1` (default 1), `RUNNER_DIGEST`.
5. Check: org Settings > Actions > Runners shows an idle runner; run `runner-smoke.yml`; logs
   `journalctl -fu agl-runner@1`. Stop: `systemctl disable --now agl-runner@1`.

## Updating the runner
Bump pins (chapter 03), merge, wait for publish+verify, put the new digest into `kit/runner.digest`, re-run
`deploy.sh` on the host (it restarts nothing by itself: `systemctl restart agl-runner@N` between jobs).

One command: `kit/update.sh [token-file]` does `git pull --ff-only`, `deploy.sh` with `SLOTS=2` and restarts both
slots. Why `deploy.sh` copies `run-loop.sh` and the unit to `/opt` and `/etc/systemd`: systemd runs it as root, so
it must not come from a checkout that a `git pull`, a branch switch or a non-root user can change. The copy is a
root-owned snapshot of a reviewed commit; the cost is one `install` line. Alternative (rejected): `ExecStart`
straight from the checkout, which makes every `git pull` an instant root-code change.

## Shared cache (trial)
`deploy.sh` creates `CACHE_DIR` (default `/srv/agl-cache`, owner uid 1001 = runner user) with `sstate/` and `dl/`.
`run-loop.sh` bind-mounts it at the same path into the DinD sidecar and the runner container and exports
`AGL_SSTATE_DIR=$CACHE_DIR/sstate`, `AGL_DL_DIR=$CACHE_DIR/dl`; the engine turns them into the kas fragments
`sstate-shared.yml` and `dl-shared.yml` (chapter 13). The sidecar needs the mount too, because `kas-container` runs
in the sidecar's daemon and resolves host paths there.

Trial decision (2026-10-23): every slot, PR or release, reads AND writes the same cache, so all jobs profit. Known
risk: an approved fork PR can write poisoned sstate that later jobs reuse; concurrent builds share the hash
equivalence database in `sstate/` (sqlite). Before production: `agl-pr` slots mount the cache read-only, a trusted
`agl-release` slot is the only writer (this was the original design), and the cache is rebuilt from scratch once.
Hash equivalence and PR servers: chapter 14. Delete the cache with `rm -rf $CACHE_DIR/*` (next build is cold). Size: expect 50-150 GB, check `df -h`.

## Security notes
- The sidecar is privileged: a job can start privileged containers in it. Weaker than `DIND=0`.
- Containers share the host kernel; fine for a personal rig, VM-per-job for untrusted PRs at scale.
- Runner container: non-root, default caps, `seccomp=unconfined` (bitbake `unshare()`).
- No volumes besides the workspace: builds start cold. A trusted read-only sstate mirror can be added later.
- Never run `pull_request_target` workflows on this runner.

## Open points
`/dev/kvm` inside nested kas containers; necessity of `seccomp=unconfined`; Podman path untested; the old
test runner (`Debian-1303-trixie-amd64-base`, bare host install, labels `self-hosted Linux X64 agl` (removed)) must be
removed from the org when the kit replaces it.

## Labels
`agl-pr`: pull-request and push builds (default of the kit, used by `runner-smoke.yml`). `agl-release`: release jobs, to be given their own slots when the release workflow exists (decision 2026-10-22: rename only for now). `agl-kvm`: reserved for jobs that need `/dev/kvm`. Changing labels on an existing host: edit `LABELS=` in `/etc/agl-runner/runner.env`, `systemctl restart agl-runner@N`.

## Failure behaviour (run-loop.sh)
- Preparation fails (network, volume, sidecar not answering within ~3 min): cleanup, back off 30 s x failures (max 10 min), no GitHub call.
- Runner container exits within 30 s (never served a job): its registration is deleted via the API, then back off.
- A run longer than 30 s resets the backoff.
Lesson (2026-10-22): the first version requested the JIT config before preparing the sidecar, so a failing engine created one stale runner registration every ~11 s (44 in 6 minutes).
