# 07 Compliance mapping

Status: **planned**. Rule: only claims that are evidenced by a committed artifact or a check.

| Framework | Requirement area | Evidence (target) |
|---|---|---|
| OpenSSF Scorecard | Pinned-Dependencies, Token-Permissions, Signed-Releases, Branch-Protection, Code-Review, SAST, Vulnerabilities, Security-Policy | Scorecard workflow result; `SECURITY.md`; SHA-pinned actions; `permissions` blocks |
| SLSA | Build L2 (signed provenance, hosted builder); reproducible rebuild as extra evidence | `attest-build-provenance`; blocking digest compare |
| NIST SSDF (SP 800-218) | PS.1-PS.3 protect/verify releases; PW.4 reuse trusted components; PO.3 toolchains | signed images, SBOM, pinned inputs |
| EU CRA | SBOM, vulnerability handling, secure by default | SPDX SBOM per image, `SECURITY.md`, pin-bump process |
| UNECE R155 / ISO 21434 | Supplier tool integrity, cybersecurity management of the build chain | this manual, hand-over log, key registry |

Gaps to close before claiming any of the above: enable branch rulesets and signed commits, add `SECURITY.md`,
Scorecard workflow, CODEOWNERS, Dependabot for actions; decide SLSA L3 generator.
