# 07 Compliance mapping

Status: **planned**. Rule: only claims that are evidenced by a committed artifact or a check.

| Framework | Requirement area | Evidence (target) |
|---|---|---|
| OpenSSF Scorecard | Pinned-Dependencies, Token-Permissions, Signed-Releases, Branch-Protection, Code-Review, SAST, Vulnerabilities, Security-Policy | Scorecard workflow result; `SECURITY.md`; SHA-pinned actions; `permissions` blocks |
| SLSA | Build L2 (signed provenance, hosted builder); reproducible rebuild as extra evidence | `attest-build-provenance`; blocking digest compare |
| NIST SSDF (SP 800-218) | PS.1-PS.3 protect/verify releases; PW.4 reuse trusted components; PO.3 toolchains | signed images, SBOM, pinned inputs |
| EU CRA | SBOM, vulnerability handling, secure by default | SPDX SBOM per image, `SECURITY.md`, pin-bump process |
| UNECE R155 / ISO 21434 | Supplier tool integrity, cybersecurity management of the build chain | this manual, hand-over log, key registry |

Gaps to close before claiming any of the above: signed commits, rulesets for the layer repos other than `meta-agl`
(`agl-ucb`, `meta-agl-demo`, `meta-agl-devel` have none), a team in CODEOWNERS and required reviews once there is a second
engineer; decide the SLSA L3 generator. (`SECURITY.md`, Scorecard, CODEOWNERS, Dependabot and the `main` ruleset of agl-ci exist.)

## Release report contents (planned, `report.md` / `report.html`)
Completeness; provenance (commit, workflow, runner type, pins and diff to previous release, signature table);
reproducibility (digests of all builds); vulnerabilities (Grype, KEV/EPSS, OpenVEX waivers shown); licenses;
CRA block (SBOM, security contact, support period, update path, vulnerability status at release);
R155 / ISO 21434 supplier block (tool versions, build-environment integrity, approvals, change history,
evidence retention). CRA dates to verify against Regulation (EU) 2024/2847: reporting duties from 2026-09-11,
rest from 2027-12-11.

## Status of the repo-hygiene items (2026-10-22)
Done: LICENSE, SECURITY.md, CODEOWNERS, Dependabot (actions), Scorecard workflow, `main` ruleset (PR + `lint`),
secret scanning + push protection, SHA pinning (the setting is enforced on all five repos since 2026-10-29), read-only token default (chapter 12). Open: signed commits, required
reviews (needs a second engineer), org 2FA and org-level policies (owner action), first signed release tag.
