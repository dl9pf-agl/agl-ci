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
| 08 | [Maintenance](08-maintenance.md) | Bumping pins, incident response |
| 09 | [Yocto-built builder experiment](09-yocto-experiment.md) | Parallel dogfooding track |

Status legend used in the chapters: **done** (implemented and tested), **untested** (implemented, not yet run),
**planned**.
