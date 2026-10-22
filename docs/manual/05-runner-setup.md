# 05 Runner setup (Debian 13 host)

Status: kit **partially tested** (Docker-in-Docker validated on a dev host, kit not yet run end to end on
the Debian server). Integration with the signed runner image is **planned**: the kit will pull
`ghcr.io/dl9pf-agl/agl-ci/runner@<pinned digest>` and run `cosign verify` before use (kit/pins).

## GitHub side
1. Org `dl9pf-agl` (free). Settings > Actions > Runner groups > Default: allow public repositories
   (needed because the repos are public) - only after step 2.
2. Settings > Actions > General: fork pull request workflows = *Require approval for all external
   contributors*; also consider *Require actions to be pinned to a full-length commit SHA*.
3. Fine-grained PAT: owner `dl9pf-agl`, organization permission *Self-hosted runners: Read and write*.
   Keep it only on the host (`/etc/agl-runner/runner.env`, 0600).

## Host side
```
sudo ./deploy.sh /path/to/token-file      # installs Docker if neither Docker nor Podman exists
```
Options (env): `GH_ORG`, `SLOTS`, `ENGINE`, `LABELS` (default `agl-kvm`; the test runner uses `agl`), `MEM_LIMIT`,
`CPU_LIMIT`, `DIND=0|1`, `REBUILD=1`, `RUNNER_VERSION`. Logs: `journalctl -fu agl-runner@1`.

## Model
Per job: JIT registration (single-use config, PAT never enters the container), fresh container, removed
after the job. With `DIND=1`: private network + volume + privileged `docker:dind` sidecar; the runner
container stays unprivileged (`DOCKER_HOST=tcp://...`). `DIND=0`: no sidecar, kas runs directly in the runner
image, `/dev/kvm` goes straight to the runner container (preferred for QEMU boot tests).

## Test runner state (2026-10-22)
A bare, hand-installed runner (`Debian-1303-trixie-amd64-base`, labels `self-hosted Linux X64 agl`) served the
smoke test. It runs jobs directly on the host and is to be replaced by the kit.

## Open points
- `/dev/kvm` inside nested kas containers; `seccomp=unconfined` necessity; Podman path untested.
- Runner image uid is 1001 in the signed image (builder user `ci` is 1000): kit volume chown must match.
