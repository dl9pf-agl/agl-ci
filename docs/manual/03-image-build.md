# 03 Image build and reproducibility

Status: builder reproducibility **tested locally** (two cold `--no-cache` builds, identical OCI archive); CI run and runner image **untested**.

## Pins
`docker/pins.env` and `docker/requirements.txt` are the only inputs reviewers edit:
base image digest, `snapshot.debian.org` timestamp, GitHub runner version + sha256, BuildKit image digest,
cosign release; Python packages are hash-locked (`pip install --require-hashes`).

## What makes the build deterministic
- Base: `debian@sha256:...`; apt sources rewritten to `snapshot.debian.org/archive/debian/<SNAPSHOT>`.
- `SOURCE_DATE_EPOCH` = last commit time; `rewrite-timestamp=true` on the OCI exporter clamps file mtimes.
- `PYTHONDONTWRITEBYTECODE`, `pip --no-compile`: no `.pyc` with embedded mtimes.
- Cleanup of logs, caches, `ldconfig` aux-cache, dpkg/debconf backups; fixed shadow `lastchg`.
- BuildKit provenance/SBOM attestations disabled in the build; added afterwards as cosign/GitHub attestations.

## Reproduce a published digest locally
```
git clone https://github.com/dl9pf-agl/agl-ci && cd agl-ci && git checkout <commit>
SOURCE_DATE_EPOCH=$(git log -1 --format=%ct) scripts/build-image.sh builder builder.tar   # prints digest
scripts/build-image.sh runner runner.tar builder.tar
```
Compare with `cosign verify` output or `skopeo inspect --raw docker://ghcr.io/dl9pf-agl/agl-ci/builder:<tag> | sha256sum`.

## Findings while getting to bit-for-bit
- Logs and `ldconfig` aux-cache written by `apt` differed between cold builds. A later `RUN rm` does not
  help: the file stays in the earlier layer. Cleanup must happen in the same `RUN` that creates the files.
- A second build with warm BuildKit cache is identical trivially; always test with `--no-cache`
  (`NO_CACHE=1 scripts/build-image.sh ...`). CI runners start cold.

## Known risks
- A package withdrawn from the snapshot, or non-deterministic package postinstall output, breaks the
  blocking compare. Fix: diff the two OCI layouts (`diffoci` or `skopeo`/`tar`), remove the source of variation.
