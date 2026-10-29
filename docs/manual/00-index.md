# agl-ci manual

Living documentation of the agl-ci supply chain. Every change to workflows, Dockerfiles, scripts or the
runner kit updates the matching chapter in the same commit.

The chapters keep their numbers because scripts, skills and other chapters cite them; the parts group them by subject.

### Part A Overview
| # | Chapter | Content |
|---|---------|---------|
| 01 | [Architecture](01-architecture.md) | Components, trust boundaries, data flow |
| 02 | [Design decisions](02-design-decisions.md) | What was chosen, why, alternatives considered |
| 16 | [Glossary](16-glossary.md) | Terms used in the other chapters |

### Part B Image supply chain (builder and runner images)
| # | Chapter | Content |
|---|---------|---------|
| 03 | [Image build and reproducibility](03-image-build.md) | Pins, build steps, how to reproduce a digest locally |
| 04 | [Signing, attestation, verification](04-signing-and-verification.md) | CI signature, SBOM, provenance, consumer verification |
| 06 | [Release engineer guide](06-release-engineer.md) | YubiKey countersignature, rotation, revocation, hand-over |
| 09 | [CVE policy, scanning, VEX playbook](09-cve-policy-and-vex.md) | Two severity bars, grype, waivers, advisory response |
| 10 | [Lint and security gate](10-lint-gate.md) | actionlint, zizmor, shellcheck; recovery path |
| 12 | [Repository hardening](12-repo-hardening.md) | Ruleset, secret scanning, Scorecard, approvals, owner-only settings |
| 07 | [Compliance mapping](07-compliance.md) | OpenSSF Scorecard, SLSA, NIST SSDF, CRA, UNECE R155 |
| 08 | [Yocto-built builder experiment](08-yocto-experiment.md) | Deferred (not built) |

### Part C Build hosts
| # | Chapter | Content |
|---|---------|---------|
| 05 | [Runner setup](05-runner-setup.md) | Debian 13 host, deploy kit, GitHub org settings |

### Part D Layer CI
| # | Chapter | Content |
|---|---------|---------|
| 13 | [Layer CI engine](13-layer-ci-engine.md) | Build tree, matrices, scope chain, kas execution modes |
| 14 | [Hash equivalence and PR servers](14-hashserv-and-prserv.md) | Which server where, read-only vs read-write, when a PR service is needed |
| 15 | [Outage drill, mirrors, open items](15-outage-drill-and-mirrors.md) | Upstream-outage tiers, offline drill, mirror decisions, folder growth, tracked missing items |

### Part E Adoption
| # | Chapter | Content |
|---|---------|---------|
| 11 | [Templating and portability](11-templating.md) | Adopting agl-ci elsewhere, GitLab/Forgejo path |

## Which chapter do I need?
- Host administrator (set up, update or repair a build host): 05, then 15 for mirrors and caches.
- Layer maintainer (matrix, callers, a red or empty CI run): 13.
- Release engineer (signing, keys, hand-over): 06, 04.
- Security reviewer (trust rules, CVE policy, hardening): 01, 12, 13 ("Trust rules"), 09.
- Adopter on another forge or org: 11.

## Status words
Status legend used in the chapters: **in use** (runs in CI or on the hosts), **implemented** (written and tested locally, not
yet in regular use), **decided** (agreed, not built), **planned** and **deferred** (not started), and **untested** as a
qualifier for a part that has not been run.
