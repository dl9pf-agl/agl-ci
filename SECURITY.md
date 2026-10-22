# Security policy

## Reporting a vulnerability
Use GitHub private vulnerability reporting: <https://github.com/dl9pf-agl/agl-ci/security/advisories/new>.
Do not open a public issue. We acknowledge within 5 working days. Where a vulnerability is actively exploited,
affects released images, or is reportable under the EU CRA, we start the coordinated process described in
`docs/manual/07-compliance.md`.

## Supported versions
The latest release tag and the `edge` images built from `main`. Older releases get fixes only on request.

## What is in scope
Workflows, scripts, Dockerfiles, pins and policy in this repository, and the published images
`ghcr.io/dl9pf-agl/agl-ci/{builder,runner}`. Verify an image with `scripts/verify-release.sh` before use.

## Supply-chain facts
Images are built reproducibly, signed keyless with cosign, and carry an SPDX SBOM and SLSA provenance
(`docs/manual/04-signing-and-verification.md`). Known vulnerabilities in the base image are reported per build
(`docs/manual/09-cve-policy-and-vex.md`).
