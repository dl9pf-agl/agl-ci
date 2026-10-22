# agl-ci manual

Living documentation of the agl-ci supply chain. Every change to workflows, Dockerfiles, scripts or the
runner kit updates the matching chapter in the same commit.

| # | Chapter | Content |
|---|---------|---------|
| 01 | [Architecture](01-architecture.md) | Components, trust boundaries, data flow |
| 02 | [Design decisions](02-design-decisions.md) | What was chosen, why, alternatives considered |
| 03 | [Image build and reproducibility](03-image-build.md) | Pins, build steps, how to reproduce a digest locally |
| 04 | [Signing, attestation, verification](04-signing-and-verification.md) | CI signature, SBOM, provenance, consumer verification |
| 05 | [Runner setup](05-runner-setup.md) | Debian 13 host, deploy kit, GitHub org settings |
| 06 | [Release engineer guide](06-release-engineer.md) | YubiKey countersignature, rotation, revocation, hand-over |
| 07 | [Compliance mapping](07-compliance.md) | OpenSSF Scorecard, SLSA, NIST SSDF, CRA, UNECE R155 |
| 08 | [Yocto-built builder experiment](08-yocto-experiment.md) | Deferred (not built) |
| 09 | [CVE policy, scanning, VEX playbook](09-cve-policy-and-vex.md) | Two severity bars, grype, waivers, advisory response |
| 10 | [Lint and security gate](10-lint-gate.md) | actionlint, zizmor, shellcheck; recovery path |
| 11 | [Templating and portability](11-templating.md) | Adopting agl-ci elsewhere, GitLab/Forgejo path |
| 12 | [Repository hardening](12-repo-hardening.md) | Ruleset, secret scanning, Scorecard, approvals, owner-only settings |

Status legend used in the chapters: **done** (implemented and tested), **untested** (implemented, not yet run),
**planned**.
