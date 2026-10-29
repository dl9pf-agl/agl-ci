# 01 Architecture

*Read this if you want the big picture before any other chapter.*

Status: **in use**. `images.yml` ran green on the latest pushes to `main` (checked 2026-10-29): build twice and compare, scan, smoke, publish and sign, verify on a fresh runner.

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

## Layer CI
```
layer repo (meta-agl, -demo, -devel; agl-ucb lint)   ci.yml: triggers + one `uses:` line pinned by commit
   -> agl-ci layer-ci.yml (reusable)
      matrix job   (GitHub-hosted): checkout agl-ucb + the layers through kas, compute the matrix, decide pool/tier/mode
      build jobs   (self-hosted)   : trusted pool agl-pr (same-repo PRs, push, nightly) or untrusted pool agl-fork (fork PRs)
      result job                   : the one required check
trusted host: shared cache = mirror (nginx, read-only), later hash equivalence server
```
Chapters: 13 (engine), 05 (hosts and pools), 15 (mirrors, drills), 14 (hash servers).

## Trust boundaries
- Build and signing of the images happen only on GitHub-hosted runners. The self-hosted hosts never sign or publish images; they
  build the layer images and upload them as workflow artifacts.
- PR builds have no `id-token`, no `packages: write`, no secrets.
- Consumers trust: GitHub OIDC issuer, Sigstore (Fulcio/Rekor), the workflow path+ref identity, and for
  releases the release engineer's public key committed in this repo.
