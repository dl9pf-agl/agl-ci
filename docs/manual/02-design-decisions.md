# 02 Design decisions

Each entry: decision, reason, alternatives not taken.

| Decision | Reason | Alternatives considered |
|---|---|---|
| Two images, `runner` FROM `builder` | One toolchain definition; runner is the sensitive part and gets signed too | One image (bigger attack surface everywhere); builder only (runner unsigned) |
| Debian trixie base, pinned by digest + dated apt snapshot | Enables reproducible rebuilds; distro security via reviewed pin bumps | Floating `stable-slim` (not reproducible); Alpine/Wolfi/distroless (Yocto host tools need glibc + many packages) |
| Yocto-built builder in parallel (experiment) | Dogfooding; build-time SPDX 3.0 SBOM is more accurate than scanning | Yocto only: no `container-yocto-builder` shipped yet, SLSA provenance only a PoC, signing there is key-based |
| Bit-for-bit reproducibility, blocking | Strongest audit statement; second independent build must give same digest | Report-only (weaker); pinned inputs only (claim by construction) |
| Build twice on separate runners, compare | Detects non-determinism and a single compromised runner | Single build + provenance only |
| Plain `docker buildx` CLI + `skopeo`, not build-push-action | Fewer third-party actions to pin and trust; exact control of OCI export and timestamps | `docker/build-push-action` (convenient, adds dependency; push path changes digest handling) |
| BuildKit attestations off, SBOM/provenance as cosign/GitHub attestations | BuildKit embeds timestamps in attestations, breaking bit-for-bit | `--provenance=mode=max --sbom=true` |
| Keyless cosign (OIDC -> Fulcio -> Rekor) for CI | No long-lived key to protect; identity = workflow path+ref | Key in GitHub secret (key theft risk); KMS key (cost, still a secret) |
| cosign v2.6.x | Documented, stable signature layout | cosign v3 (new bundle format by default, less field-tested) |
| YubiKey countersignature for releases, signed git tag as fallback | Human accountability, key never leaves hardware | Second CI approval via environment (proves approval, not a person) |
| GHCR only, optional mirror job later | KISS; digest-preserving copy keeps signatures valid | quay.io / Docker Hub from day one |
| Self-hosted runner = deploy kit (JIT, per-job container, DinD) | Strong isolation for public repos | Bare runner on host (persistent, shared state); rootless Podman (setup issues seen) |
| Markdown manual in repo, no site generator | KISS, reviewable in PRs | MkDocs/Docusaurus |
