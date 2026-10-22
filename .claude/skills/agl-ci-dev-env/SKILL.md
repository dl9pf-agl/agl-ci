---
name: agl-ci-dev-env
description: Local test environment matching GitHub hosted ubuntu-24.04 for agl-ci work - Docker 28.0.4 daemon, Skopeo 1.13.3, lint tool paths, openSUSE no-systemd quirks. Consult BEFORE running docker/skopeo/lint locally for agl-ci, reproducing a hosted-runner failure, or running smoke-image.sh.
---

# Local CI-matching environment

- Host: openSUSE Leap 16, no systemd. Ask the user before any sudo (approved earlier only for docker/skopeo setup).
- Hosted ubuntu-24.04: Docker 28.0.4, Skopeo 1.13.3, Buildx 0.38.0, Podman 4.9.3. Local system skopeo is 1.18, so use the pinned one.
- Docker 29.4 daemon: `unix:///tmp/agl-dockerd.sock` (pre-existing). Docker 28.0.4 daemon (sudo-started): `unix:///tmp/ci28.sock` (path must be <108 chars).
- Use 28: `export PATH=<scratchpad>/ci28/bin:<scratchpad>/ci28/docker:$PATH DOCKER_HOST=unix:///tmp/ci28.sock DOCKER_CONFIG=<scratchpad>/ci28/cfg` (static binaries, `cfg/cli-plugins`, `bin/skopeo` wrapper).
- Skopeo 1.13.3 extracted from the Ubuntu package needs `libdevmapper.so.1.02.1`: symlink to `libdevmapper.so.1.03`, set `LD_LIBRARY_PATH`.
- `skopeo copy ... docker-daemon:` fails with Docker 29; don't use it.
- Lint tools in `/tmp/claude-1000/lintbin` (actionlint, zizmor, shellcheck, hadolint, grype, syft, checkbashisms). Every shell script: `bash -n`, shellcheck, checkbashisms.
- `build-image.sh` locally needs `jq` for the digest line.
- Never `sleep` then run; use Monitor. Long builds detached (`setsid ... & disown`).
- Later: `scripts/local-ci-docker.sh` to automate this (on the later list).
