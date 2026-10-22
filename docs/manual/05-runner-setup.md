# 05 Runner setup (Debian 13 host)

Status: kit moved to `kit/`, now pulls and verifies the signed runner image. **Untested end to end**: the runner
image is not published yet (PR #1 not merged), so `kit/runner.digest` is empty. Docker-in-Docker was validated
earlier on a dev host with a locally built image.

## What the kit does
`kit/deploy.sh` (systemd + Docker/Podman, run from a checkout of this repo):
1. Reads the pinned runner digest from `kit/runner.digest` (or env `RUNNER_DIGEST`).
2. Installs a sha256-pinned `cosign` if missing, runs `cosign verify` with the CI identity from
   `policy/project.env`, pulls `ghcr.io/<owner>/agl-ci/runner@<digest>`. Nothing is built on the host.
3. Writes `/etc/agl-runner/runner.env` (0600; token only here), installs `run-loop.sh` and the systemd unit,
   starts `agl-runner@N`.
Per job (`run-loop.sh`): JIT registration (single-use config), private network, workspace volume (owned by uid 1001),
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
   Options (env): `GH_ORG`, `SLOTS`, `ENGINE`, `LABELS` (default `agl-kvm`; the test runner used `agl`), `MEM_LIMIT`,
   `CPU_LIMIT`, `DIND=0|1` (default 1), `RUNNER_DIGEST`.
5. Check: org Settings > Actions > Runners shows an idle runner; run `runner-smoke.yml`; logs
   `journalctl -fu agl-runner@1`. Stop: `systemctl disable --now agl-runner@1`.

## Updating the runner
Bump pins (chapter 03), merge, wait for publish+verify, put the new digest into `kit/runner.digest`, re-run
`deploy.sh` on the host (it restarts nothing by itself: `systemctl restart agl-runner@N` between jobs).

## Security notes
- The sidecar is privileged: a job can start privileged containers in it. Weaker than `DIND=0`.
- Containers share the host kernel; fine for a personal rig, VM-per-job for untrusted PRs at scale.
- Runner container: non-root, default caps, `seccomp=unconfined` (bitbake `unshare()`).
- No volumes besides the workspace: builds start cold. A trusted read-only sstate mirror can be added later.
- Never run `pull_request_target` workflows on this runner.

## Open points
`/dev/kvm` inside nested kas containers; necessity of `seccomp=unconfined`; Podman path untested; the old
test runner (`Debian-1303-trixie-amd64-base`, bare host install, labels `self-hosted Linux X64 agl`) must be
removed from the org when the kit replaces it.
