# 16 Glossary

*Read this if a term in another chapter is unclear.*

Terms in alphabetical order inside each group. The chapter that explains a term in detail is in the last column.

## Repositories and tools
| Term | Meaning | Chapter |
|---|---|---|
| agl-ci | This repository: the only place with pipeline logic (images, reusable workflows, scripts, host kit, this manual) | 01 |
| agl-ucb | The umbrella checkout: kas fragments (`kas/`), pins (`kas/pins.yml`) and `scripts/aglsetup.sh`; kas clones the AGL layers into it | 13 |
| AGL layers | `meta-agl`, `meta-agl-demo`, `meta-agl-devel` | 13 |
| builder image | Debian image with Yocto host tools, kas and lint tools; used as `KAS_CONTAINER_IMAGE`; pinned by digest in `ci/builder.digest` | 03 |
| runner image | The builder plus docker CLI and the GitHub Actions runner; pinned by digest in `kit/runner.digest` | 03, 05 |
| kas, kas-container | The tool that checks out layers and runs bitbake from YAML fragments; `kas-container` runs it in a container; `KAS_EXEC` selects which one the engine calls | 13 |
| skill | A Markdown file under `.claude/skills/` that tells Claude Code how to work in a repo | none |

## CI concepts
| Term | Meaning | Chapter |
|---|---|---|
| caller | The `ci.yml` of a layer repo: triggers plus one `uses:` line, pinned by commit | 13 |
| matrix | The list of (repo, machine, features, target) builds, from `ci/build-matrix.yaml` of every repo in scope | 13 |
| tier | Which matrix entries run: `push-pr`, `nightly`, `release`, `dispatch`; a pull request always runs `push-pr` | 13 |
| mode | What a run does: `build`, `fetch` (fill the download cache), `drill`, `drill-mirror`; a pull request always runs `build` | 13, 15 |
| scope (`AGL_SCOPE`), `needs:` | A run covers the repo under test plus every repo that needs it; demo needs meta-agl, devel needs demo | 13 |
| repo under test | The repo whose commit is being checked, pinned by the generated `layer-pin.yml` | 13 |
| pin, floating, written-out pin | Pin: a fixed commit. Floating: the tip of the branch. Written-out pin: the commits a run resolved to, as a pins file (`resolved-pins.sh`); a release needs one | 13 |
| `overrides:` | kas section applied after everything else; a commit there beats any later `repos:` entry | 13 |
| result job | The aggregate job `ci / result`; the required check of the layer repos | 13 |

## Hosts and pools
| Term | Meaning | Chapter |
|---|---|---|
| pool | A class of hosts: trusted (label `agl-pr`: same-repo pull requests, push, nightly, release) or untrusted (label `agl-fork`: fork pull requests) | 05 |
| host, slot | A physical machine serves one pool; it runs 1..n slots (`agl-runner@N`), each building one job at a time | 05 |
| JIT runner | A runner registered with a single-use config for one job | 05 |
| DinD sidecar | The privileged `docker:dind` container per job that the unprivileged runner container uses | 05 |
| `CACHE_DIR` | The host's cache with `sstate/` and `dl/`; on a trusted host it is also the mirror | 05, 15 |

## Yocto and caches
| Term | Meaning | Chapter |
|---|---|---|
| sstate | Cache of task results, found by hash | 15 |
| `DL_DIR`, premirror | Download cache; a premirror is tried before the upstream URL | 15 |
| mirror | The HTTP server over the trusted cache (`/dl/`, `/sstate/`, `/git/`) | 15 |
| hash equivalence server (hashserv) | Maps task hashes to unihashes so unchanged outputs reuse sstate; read-write for trusted builds, read-only for pull requests | 14 |
| PR service | Hands out increasing package revisions for a binary feed; only needed when CI publishes one | 14 |
| uninative | The tarball of a host loader that bitbake fetches into `DL_DIR/uninative/` | 15 |
| T1, T2, T3 | Outage tiers: keep building; clean rebuild on a new builder; rebuild an old release years later | 15 |
| drill | A build with the network off or restricted to the mirror, to find what is not covered | 15 |

## Supply chain
| Term | Meaning | Chapter |
|---|---|---|
| digest | The sha256 of an image; used instead of tags | 03 |
| keyless signing | cosign signing with a short-lived certificate from the CI identity (OIDC, Fulcio, Rekor) | 04 |
| SBOM, provenance | Attestations attached to an image: component list (SPDX) and build facts (SLSA) | 04 |
| countersignature | The release engineer's YubiKey signature on the same digest | 06 |
| VEX, waiver | OpenVEX statement that a finding does not affect us; it removes the finding from the bar and is listed in the report | 09 |
| ruleset, CODEOWNERS | GitHub branch rules as code (`policy/github/ruleset-main.json`); the owner file that requests reviews | 12 |
