# 02 Design decisions

Each entry: decision, reason, alternatives not taken.

| Decision | Reason | Alternatives considered |
|---|---|---|
| Two images, `runner` FROM `builder` | One toolchain definition; runner is the sensitive part and gets signed too | One image (bigger attack surface everywhere); builder only (runner unsigned) |
| Debian trixie base, pinned by digest + dated apt snapshot | Enables reproducible rebuilds; distro security via reviewed pin bumps | Floating `stable-slim` (not reproducible); Alpine/Wolfi/distroless (Yocto host tools need glibc + many packages) |
| Yocto-built builder in parallel (experiment) | Dogfooding; build-time SPDX 3.0 SBOM is more accurate than scanning | Yocto only: no `container-yocto-builder` shipped yet, SLSA provenance only a PoC, signing there is key-based |
| Bit-for-bit reproducibility, blocking | Strongest audit statement; second independent build must give same digest | Report-only (weaker); pinned inputs only (claim by construction) |
| Build twice on separate runners, compare | Detects non-determinism and a single compromised runner | Single build + provenance only |
| Plain `docker buildx` CLI + `skopeo` (in `scripts/publish-image.sh`), not build-push-action | Fewer third-party actions to pin and trust; exact control of OCI export and timestamps | `docker/build-push-action` (convenient, adds dependency; push path changes digest handling) |
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
| CVE policy: two selectable bars (build, release), both **report only** now (`policy/cve.env`, chapter 09) | Failing at release is too late, it should only catch zero-days between tag and release; fail early at build | One bar at release only; block from day one |
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

## Lint gate (decided 2026-10-22)
| Decision | Reason | Alternatives considered |
|---|---|---|
| `lint.yml` on every PR/push, first job of `images.yml` (`needs: lint`) | Nothing builds or publishes when the pipeline definition itself is unsafe | Required check only (does not stop tag-triggered runs); advisory first (weakens the gate) |
| actionlint + zizmor + shellcheck, pinned binaries with sha256 | Correctness and security tools are complementary (arXiv 2601.14455); no extra third-party actions | poutine/octoscan later if gaps show; marketplace actions for each tool (more trust surface) |
| Break-glass = `LINT_MODE=report` repo variable or dispatch input | A lint false positive must not block a security fix | Admin-only bypass of the ruleset (leaves no trace in the run) |
| Scorecard and CodeQL scheduled, not per-PR | Slow and noisy as gates; they provide audit evidence | Per-PR gates |

## Simplification review (decided 2026-10-22)
| Decision | Reason | Alternatives considered |
|---|---|---|
| cosign only for signature, SBOM and provenance; GitHub attestations optional extra | Most portable: any OCI registry, any forge with an accepted OIDC issuer, `--key` fallback; one verification tool | GitHub attestations only (least portable, needs `gh`); current mix (two tools in the verify policy) |
| Own SLSA provenance predicate (small script) | Keeps the verify policy cosign-only | GitHub-generated statement (richer, GitHub-only) |
| syft binary pinned (sha256) instead of anchore/sbom-action | One fewer third-party action; same pattern as other tools | sbom-action |
| Publish/sign logic in `scripts/`, workflow calls them | Forge-independent, locally testable, templatable | Inline YAML steps |
| Drop hadolint; keep actionlint, zizmor, shellcheck | Two small Dockerfiles; findings were cosmetic | Keep all four |
| Keep DinD default, keep two independent build runners | User decision: DinD needed for kas-container flows; independence of the per-push check | DIND=0 (simpler, removes docker-cli CVEs); single-job double build |
| Chapters merged (08->03, 12->09), Yocto experiment deferred | Fewer stubs; YAGNI | Keep 13 chapters |

## Layer CI (decided 2026-10-22)
| Decision | Reason | Alternatives considered |
|---|---|---|
| Reuse the existing matrix schema and scripts, adapted | Already tested, tiers exist, less new code | New `plan.py`/`images.yaml` (second schema to keep in sync) |
| `agl-ucb` is the single source of kas config and pins; CI = agl-ucb + layers cloned into it | meta-agl has no base/machine/pins; even `bitbake -p` needs the pinned externals | Standalone layer repos (duplicated files drift); kas repo-includes across repos (more machinery) |
| kas clones the layers (`url:`/`branch:` in agl-ucb `base.yml`); CI pins the repo under test with a generated fragment (`commit:`, fork `url:`); opt-in dev mode `kas/local/dev.yml` for local edits | Users get `git clone agl-ucb` + `aglsetup.sh`, one fetch mechanism on desk and in CI. Tested with kas 5.5: a clean clone without `commit:` is hard-reset to the branch tip (unpushed commits lost), a dirty one is skipped, `url:` set to null makes a repo local and untouched, `commit:` pins exactly | A separate `checkout-layers.sh` (second mechanism users must learn; was the first implementation); path-only `base.yml` (requires pre-cloned layers) |
| `needs:` in each repo's matrix defines the downstream chain | Declarative, local to each repo, templatable | Hard-coded repo map in the engine |
| `KAS_EXEC` switch: `kas-container` (default, signed builder) or `kas` direct | Both execution models kept at the price of one function | Only one of them |
| Cache permission by runner pool (agl-pr read-only, agl-release read-write) | A PR cannot poison the cache that main/release consume | Always cold; one shared read-write cache |
| Trial exception (2026-10-23): all slots read and write the cache; split returns before production | Every job profits while the pilot is tuned; approved fork PRs can poison it meanwhile | Split from day one |
| Hash equivalence server everywhere (read-write for trusted builds, read-only for PR builds); PR service only for release runners that publish a binary feed (2026-10-23, chapter 14) | Hashserv only changes build time; a PR build that can write could bind a task hash to an object of its choice. The PR service only matters for package upgrade order, and a down PR service fails every build that sets it | PR service everywhere (new single point of failure, no use without a feed); no hashserv (fewer sstate hits); one read-write hashserv for all builds (poisoning path) |
| Upstream-outage tiers T1 (keep building), T2 (clean rebuild on a new builder), T3 (old release years later) are all required; full HTTP mirrors for sources, sstate and git, filled by nightly and release; no NFS (2026-10-23, chapter 15) | One mirror design that serves every builder and outside users, and survives the loss of one builder | Warm local cache only (T1 only); cache plus rsync backup (T1, T2); AGL's mirror as second line only (outside our control); caching proxy (HTTPS needs TLS interception) |
| Outage drill first (`BB_NO_NETWORK=1`, fetchall, later full offline build) | Shows which fetches are still uncovered before any mirror is built | Build the mirrors first and find gaps in production |
| A pull request always runs tier `push-pr` and mode `build` | The caller file comes from the pull request, so its inputs cannot be trusted | Trust the input |
