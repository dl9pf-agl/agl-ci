# 01 Architecture

Status: workflow and Dockerfiles **untested** (first run pending).

## Components
- **agl-ci repo** (this repo): the only place with pipeline logic. Layer repos only call it.
- **`images.yml` workflow**: builds the `builder` and `runner` images twice on independent GitHub-hosted
  runners, requires identical digests, publishes to GHCR, signs, attests, and verifies from a fresh runner.
- **`builder` image**: Debian trixie + Yocto host tools + qemu + kas + oelint-adv. Used as `KAS_CONTAINER_IMAGE`.
- **`runner` image**: `FROM builder` + docker CLI + GitHub Actions runner. Started per job by the deploy kit.
- **Deploy kit** (`kit/`): systemd + Docker/Podman on the Debian host; JIT runner registration, one job per container.

## Data flow
```
PR/main/tag -> images.yml (GitHub-hosted, ephemeral)
   build-a, build-b -> compare digests (must be equal)
   publish: skopeo copy (digest preserved) -> ghcr.io/<owner>/agl-ci/{builder,runner}:<tag>
            cosign sign (keyless, OIDC) + SBOM attestation + SLSA provenance attestation
   verify : fresh runner checks signature, SBOM, provenance by pinned identity
release engineer (tags only): local YubiKey cosign signature on the same digest
runner host: kit pulls runner@digest, verifies signatures, runs jobs in per-job containers
```

## Trust boundaries
- Build and signing happen only on GitHub-hosted runners. The self-hosted box never signs or publishes.
- PR builds have no `id-token`, no `packages: write`, no secrets.
- Consumers trust: GitHub OIDC issuer, Sigstore (Fulcio/Rekor), the workflow path+ref identity, and for
  releases the release engineer's public key committed in this repo.
