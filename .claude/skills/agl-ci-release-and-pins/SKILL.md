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
| Release | agl-ucb `kas/releases/pins_<branch>_<version>.yml`: **all** repos (23 today) at one commit each, made by `scripts/prepare-release.sh`; `release.yml` copies it over `kas/pins.yml` in its throw-away tree | Manual chapter 19; section "A release of the AGL images" below. |

Image digests change with every commit (`SOURCE_DATE_EPOCH` = last commit time), so a digest in a file refers to a published build, not to "the source".

## Bump order (rebase-merge: merging gives new SHAs)
Rebase-merge is the convention; the rulesets of agl-ci and meta-agl enforce it (`allowed_merge_methods` = rebase), agl-ucb, meta-agl-demo and meta-agl-devel have no ruleset yet and still allow merge and squash.
1. Merge the agl-ci PR. 2. If `docker/` or `ci/scripts` changed the image: wait for `images` to publish and verify, PR the new digests. 3. PR the new agl-ci SHA into each caller (meta-agl first; its nightly builds demo/devel through `needs:`). 4. `./kit/update.sh` on hosts when the runner digest moved. 5. Rebase local branches onto the new SHAs. Check `gh pr view <n> --json state` and `git merge-base --is-ancestor origin/<base> HEAD` before every push.
A push to a PR branch **cancels** that PR's run in progress (`cancel-in-progress` for `pull_request` in `layer-ci.yml`): do not push to a PR with a cold build running unless you intend that.

## Floating layers and the release pin
Because the three AGL layers float, a run is not described by the pins file alone. Each `matrix` job summary prints "Resolved pins of this run" (output of `ci/scripts/resolved-pins.sh`: `header: version: 22`, `overrides: repos: <name>: commit: <sha>` for every repo of the kas tree; offline via `kas for-all-repos`; needs a checked-out tree and the CI env `AGL_TREE`, `KAS_EXEC`, `AGL_PIN_*`).
**A release must store that file** and rebuild with `kas/base.yml:...:resolved-pins.yml` in place of `kas/pins.yml`. Tested: a tree moved to older commits was brought back to exactly the recorded commits, offline. Caveat: a commit that is not on the branch declared in `base.yml` (`branch: master`) makes kas fetch, so release pins must be commits on `master`. Open: storing the file with nightly/release artifacts (M20) and the release bundle for T3 (M17).

## Cross-repo consequences
Floating means a red `master` of demo or devel turns meta-agl PRs red (its matrix pulls them via `needs:`). A repo under test that is also in `pins.yml` would be overridden by the pin: do not add the three AGL layers to `pins.yml` (the generated pin and the "tree is at the commit under test" check exist because that happened).

## A release of the AGL images (chapter 19)
- Tag `<branch>_<version>` in agl-ucb (admins only, ruleset "release tags") starts agl-ucb `release.yml`, which calls agl-ci `release.yml` **pinned by commit**; the caller grants `contents: write, id-token: write` (ceiling). Bump that pin by PR like every other pin; the pins file and the tag go on the same merge commit.
- Jobs: matrix (hosted) -> build per image (pool, any host, `AGL_RELEASE=1`, collects into that host's `staging/release/<branch>/<version>/`) -> attest (hosted, the only `id-token`) -> publish (hosted, the only `contents: write`; GitHub release with `release-signed.tar.gz`, `SHA256SUMS`, bundle).
- Download server cron (`kit/release/run.sh`): pull `staging` from all build hosts, `git pull` agl-ucb, `promote.sh` (CI signature + engineer signature file `kas/releases/<tag>.SHA256SUMS.<id>.sig`, all hashes, then copy to `release/`). `RELEASE_PROMOTE=manual` switches promotion off.
- A version is used once. Two images of one machine in the `release` tier need the same kernel. Rehearsal: `releasetest_0.0.1` to `0.0.3` (the last one passed end to end).
