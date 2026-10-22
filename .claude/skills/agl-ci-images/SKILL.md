---
name: agl-ci-images
description: How the agl-ci builder and runner container images are built, reproduced, scanned, smoke-tested, signed and verified, and how the runner kit (kit/deploy.sh, update.sh, run-loop.sh) deploys them. Consult BEFORE editing docker/*, docker/pins.env, .github/workflows/images.yml, scripts/{smoke-image,verify-release,build-image}.sh, policy/*, kit/*, or when an images run or a runner deploy fails.
---

# agl-ci images and runner kit

- Images in `ghcr.io/dl9pf-agl/agl-ci/{builder,runner}`; runner is `FROM builder@digest` + checksum-verified GitHub runner. All inputs in `docker/pins.env`; apt from dated snapshot.debian.org; `SOURCE_DATE_EPOCH` = commit time.
- `images.yml`: lint (actionlint, zizmor, shellcheck via `scripts/lint.sh`) -> two independent builds -> compare (digests must be bit-identical) -> CVE scan (two bars, `policy/cve.env`, OpenVEX waivers in `policy/vex`) -> `smoke` -> publish (main only) -> cosign keyless sign + SBOM + SLSA provenance -> verify (`scripts/verify-release.sh`, pinned to workflow identity). PRs build only, never push/sign.
- Smoke (`scripts/smoke-image.sh builder|runner OCI.tar`) guards non-startable images. Portable load: `skopeo copy oci-archive:X docker-archive:Y:ref` then `docker load`. Hosted ubuntu-24.04 = Docker 28.0.4 classic store, which cannot `docker load` an OCI archive directly (Docker 29 can).
- Builder ENTRYPOINT `/entrypoint.sh` execs `kas`; kas venv at `/opt/kas`.
- After `images` publishes on main: put new digests in `ci/builder.digest` and `kit/runner.digest` via PR (they lag main by one PR).
- Kit: `kit/deploy.sh` verifies `runner@digest` with cosign, pulls it, writes `/etc/agl-runner/runner.env` (LABELS default agl-pr), copies `run-loop.sh`+unit to `/opt/agl-runner` and `/etc/systemd/system` (root-owned snapshot: systemd runs it as root, a checkout can change under git pull). `kit/update.sh` = git pull + deploy SLOTS=2 + restart. JIT ephemeral runners, privileged DinD sidecar per job. Token file on the server: `/home/ghrunner/DL9PF-AGL-CI-RUNNER-TOKEN`.
- Known caveats: runner CVEs mostly from upstream runner bundled Node and docker-cli Go stdlib (Critical/High cleanup is on the later list); only `lint` is a required check on main (images.yml path-filtered).
- Commits: Beams + OE style `component: summary`, 72-col body, Signed-off-by, then the attribution trailer given by the harness.
