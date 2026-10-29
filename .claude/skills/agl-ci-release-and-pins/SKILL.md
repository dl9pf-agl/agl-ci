---
name: agl-ci-release-and-pins
description: How pins work across AGL CI and what a release needs - callers pinned to agl-ci by full SHA, builder and runner image digests (ci/builder.digest, kit/runner.digest), agl-ucb kas/pins.yml for external layers, the three AGL layers that float on their branch, and the written-out pin (ci/scripts/resolved-pins.sh) for releases. Consult BEFORE bumping any pin or digest, merging across the repos, cutting a release, or explaining why a build is not reproducible.
---

# Pins and releases (agl-ci, agl-ucb, layer repos)

## Which thing is pinned where
| What | Where | Rule |
|---|---|---|
| agl-ci workflow used by a repo | `uses: dl9pf-agl/agl-ci/.github/workflows/layer-ci.yml@<40-char SHA> # comment` in `ci.yml` of meta-agl, -demo, -devel, agl-ucb (lint) | Enforced: `sha_pinning_required` is on for all five repos (since 2026-10-29; the org-level setting is off), so an unpinned `uses:` fails the run at start. Whether to keep the update churn this causes is an open decision. Bump after every agl-ci change that callers need (timeouts, checks, fixes ship through this pin only). |
| Builder image | `ci/builder.digest` | Set after `images` publishes and verifies; the matrix job cosign-verifies it. |
| Runner image on hosts | `kit/runner.digest` | Then `./kit/update.sh` on each host. |
| External layers (poky, meta-openembedded, BSPs, bitbake...) | agl-ucb `kas/pins.yml` under `overrides.repos` | Pinned together; they drift out of mutual compatibility if bumped one by one (meta-flutter vs oe-core). |
| `meta-agl`, `meta-agl-demo`, `meta-agl-devel` | **not pinned: float on the tip of their branch** (decision 2026-10-28) | The repo under test is pinned by a generated `layer-pin.yml` in CI. |
| Release | **written-out pin** of everything, stored with the release | Below. |

Image digests change with every commit (`SOURCE_DATE_EPOCH` = last commit time), so a digest in a file refers to a published build, not to "the source".

## Bump order (rebase-merge only: merging gives new SHAs)
1. Merge the agl-ci PR. 2. If `docker/` or `ci/scripts` changed the image: wait for `images` to publish and verify, PR the new digests. 3. PR the new agl-ci SHA into each caller (meta-agl first; its nightly builds demo/devel through `needs:`). 4. `./kit/update.sh` on hosts when the runner digest moved. 5. Rebase local branches onto the new SHAs. Check `gh pr view <n> --json state` and `git merge-base --is-ancestor origin/<base> HEAD` before every push.
A push to a PR restarts its running jobs: do not push to a PR with a cold build in progress unless you intend that.

## Floating layers and the release pin
Because the three AGL layers float, a run is not described by the pins file alone. Each `matrix` job summary prints "Resolved pins of this run" (output of `ci/scripts/resolved-pins.sh`: `header: version: 22`, `overrides: repos: <name>: commit: <sha>` for every repo of the kas tree; offline via `kas for-all-repos`; needs a checked-out tree and the CI env `AGL_TREE`, `KAS_EXEC`, `AGL_PIN_*`).
**A release must store that file** and rebuild with `kas/base.yml:...:resolved-pins.yml` in place of `kas/pins.yml`. Tested: a tree moved to older commits was brought back to exactly the recorded commits, offline. Caveat: a commit that is not on the branch declared in `base.yml` (`branch: master`) makes kas fetch, so release pins must be commits on `master`. Open: storing the file with nightly/release artifacts (M20) and the release bundle for T3 (M17).

## Cross-repo consequences
Floating means a red `master` of demo or devel turns meta-agl PRs red (its matrix pulls them via `needs:`). A repo under test that is also in `pins.yml` would be overridden by the pin: do not add the three AGL layers to `pins.yml` (the generated pin and the "tree is at the commit under test" check exist because that happened).
