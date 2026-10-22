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

## Release gate (decided 2026-10-22)
| Decision | Reason | Alternatives considered |
|---|---|---|
| Release trust policy is selectable: `gate`, `yubikey`, `both` (`verify-release.sh --release=...`) | Human time is expensive; one phone tap for routine releases, hardware key where independence from GitHub settings matters | YubiKey only (slow, laptop + token + PIN + touch); phone-as-FIDO-key for `cosign --sk` (not possible: libfido2 talks USB/NFC only); private Sigstore with company Okta (heavy to run) |
| `gate` = audit job, then environment `release` with required reviewers (GitHub Mobile push), then keyless `release-approval` attestation | Approval is visible in the Fulcio cert (OID 1.3.6.1.4.1.57264.1.23 "Deployment Environment") | Separate approval service (more infrastructure, no stronger identity) |
| Audit job runs with no human, produces `report.md` + static `report.html` | Release engineer decides on facts: completeness, provenance, reproducibility, CVEs, licenses, CRA and R155 evidence | Manual checklist (error-prone) |
| CVE scanning: Grype on the signed SPDX SBOM; sbom-cve-check / VulnScout for the Yocto track | Grype matches Debian advisories; sbom-cve-check is built for Yocto SPDX 3 (CPE/NVD) | Trivy (VEX support unclear), NVD-only matching on Debian (noisy) |
| CVE policy: **report only** at first | Open findings are expected on a new base image; switch to "block on fixable High/Critical without OpenVEX waiver" when the backlog is understood | Block from day one |
| Waivers = reviewed OpenVEX files in the repo, always listed in the report | Suppressions stay auditable | Ignore lists in scanner config (invisible in the report) |
| Weekly re-scan of released SBOMs (`scripts/recheck-sbom.sh`) | CRA ongoing vulnerability handling evidence | Scan at release only |
| Reviewers: solo now, 2 reviewers + no self-review once staffed; report marks `single-approver` | GitHub cannot block self-review with one person; weakness must be visible | Second account now; org team minimum 2 |
| R1 reproducibility: third rebuild on the Debian server at release time; if the kit is not live the report says `R1 pending` | Independent infrastructure and operator | Hosted-only rebuild (same cloud, weaker independence); independent third party (R2, later) |

## Trust levels (documented in chapter 04)
- `gate`: depends on GitHub (environment settings, reviewers' accounts and 2FA, org owners who can change rules).
  Reviewer login with passkey: synced passkeys are generally accepted at NIST AAL2, device-bound hardware keys at AAL3
  (verify against SP 800-63-4 text before citing).
- `yubikey`: independent of GitHub settings; key non-exportable, touch required.
- `both`: highest; use for releases consumed by safety/cybersecurity-relevant products.
