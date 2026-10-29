# 13 Layer CI engine

*Read this if you maintain the CI of a layer repo, the matrix or the engine, or a CI run is red or empty.*

Status: **in use** with real kas and bitbake: `meta-agl` builds on the trusted host (warm build 26-27 min, cold `agl-image-minimal` about 4h28), `meta-agl-demo` and `meta-agl-devel` have their first cold builds running (2026-10-29). Fork pull requests have not been run end to end yet.

## Origin
Imported from the monolithic AGL CI repo (`ci/scripts`, `kas/ci-only.yml`, `kas/_validate-base.yml`) instead of writing a
new planner: its matrix schema, tiers and checks were already in use. GitLab files of the original (`ci/gitlab`) are not
imported yet (they still call `make`); the matrix and scripts are forge-independent, so only a thin adapter is missing.

## The reusable workflow and its caller
`.github/workflows/layer-ci.yml` is called by the layer repos, pinned by full SHA. Inputs: `repo` (repo under test, scopes
the downstream chain), `tier` (default: derived from the event), `kas_exec` (`kas-container` | `kas`), `ucb_ref` (agl-ucb
ref to build with, default branch when empty; use it to test an agl-ucb branch before merging), `mode` (`build` by default, `fetch`, `drill`, `drill-mirror`; chapter 15). The builder image is
pinned in `ci/builder.digest` and verified (`scripts/verify-release.sh`) in the `matrix` job. Bump the digest after every
published builder (digest in the `publish` job log of the `images` run on `main`).

**The caller needs no inputs.** `layer-ci.yml` takes the repo under test from `github.event.repository.name`, and the tier and
mode of a manual run from the event's own inputs; a caller may still pass `repo`, `tier` and `mode`. A caller is the triggers
plus one `uses:` line pinned by commit.

## Layout
- **Build tree** = a checkout of `agl-ucb` (kas fragments, `kas/pins.yml`). kas clones `meta-agl`, `meta-agl-demo`
  and `meta-agl-devel` into it (`url:`/`branch:` in `agl-ucb/kas/base.yml`), exactly as on a developer desk. `agl-ucb`
  stays the single source of kas configuration and pins; layer repos do not carry base/machine/pins files.
- **Repo under test** = env `AGL_PIN_REPO`, `AGL_PIN_URL` (fork URL for fork PRs), `AGL_PIN_SHA`. The engine writes
  `<tree>/build/ci-kas/layer-pin.yml` (`url`, `commit`, `branch:` cleared) and appends it last to the kas chain, so kas
  builds exactly that commit and nothing is reset to a branch tip. The `matrix` job first runs `ci/scripts/checkout.sh`
  (`kas checkout` of `base.yml` + `pins.yml` + the pin) so the `ci/build-matrix.yaml` files exist before the matrix is computed.
  `pins.yml` in agl-ucb pins the external layers only. `meta-agl`, `meta-agl-demo` and `meta-agl-devel` float on the tip of their
  branch, and the repo under test is pinned by the generated fragment.
- **Engine** = `agl-ci/ci/scripts` (+ `ci/kas/*.yml`, staged into `<tree>/build/ci-kas/` at run time because kas needs
  them inside the work dir).
- `AGL_TREE` selects the tree (default: current directory).

### Pin of the repo under test
The repo under test is pinned by a generated fragment (`layer-pin.yml`): the url (a fork for a fork pull request) under
`repos:` and the commit under both `repos:` and `overrides:`. The `overrides:` entry is required because agl-ucb's `kas/pins.yml`
pinned `meta-agl-demo` and `meta-agl-devel` with `overrides:` (kas applies those last; they float now, but the entry stays as defence
in depth for any repo that gets pinned again); without it a pull request of those repos checked out the pinned master instead of itself, found no matrix and went green without building (seen on the first demo and devel
pull requests, tested with kas 5.5). The `matrix` job now fails when `tree/<repo>` is not at the commit under test, and warns when
the matrix is empty.

## Matrices
Each layer repo has `ci/build-matrix.yaml` with only its own images (schema: header of `_matrix.py`; tiers
`push-pr | nightly | release | dispatch`, per-machine tier overrides). `needs: [<repo>]` declares the dependency chain
(demo needs meta-agl, devel needs demo). With `AGL_SCOPE=<repo>` a run covers that repo plus every repo that needs it
(transitively), so a `meta-agl` change also runs the downstream images; a `meta-agl-devel` change runs only devel.
Without `AGL_SCOPE` all repos in the tree are included (nightly). The nightly of `meta-agl` therefore already covers the
images of demo and devel; their callers have no schedule of their own.

### Shared names (`ci/matrix-defaults.yaml`)
What every repo would repeat lives in agl-ci, next to the engine and pinned with
it: `machine_sets` (`ci` = qemux86-64, qemuarm64, raspberrypi5, sparrow-hawk) and `tier_presets` (`dispatch`, `nightly`, `gate`
= pull request gate on qemux86-64 plus nightly on every machine, `nightly-x86`). An image says `machines: ci` and `tiers: gate`
and lists only what differs (an explicit machine list, an explicit tiers list, or a `{tiers: [...]}` on one machine entry
override the names). An unknown name is an error. The expansion is identical to the spelled-out form (checked for the demo and
devel matrices: same 38 entries).

### Floating layers and the written-out pin
`meta-agl`, `meta-agl-demo` and `meta-agl-devel` float on the tip of their branch; a
meta-agl run therefore builds the current heads of demo and devel (a real integration test of the chain). What a run resolved to
is not lost: `ci/scripts/resolved-pins.sh` prints the commit of every repo of the tree in the format of agl-ucb's `kas/pins.yml`
(offline, through `kas for-all-repos`), and the `matrix` job puts it in the job summary. **A release needs this written-out pin**:
build it with `kas/base.yml:...:resolved-pins.yml` in place of `kas/pins.yml`, and store the file with the release (bundle,
M17/M20). Tested: with the file alone a tree moved to older commits was brought back to exactly the recorded commits, offline.
The commits must be on the declared branch (`base.yml` says `branch: master`); a commit that is not on it makes kas fetch.

### yocto-check-layer
`validate.sh` checks `meta-agl/meta-agl-core` by default. `check_layers.default` in a repo's matrix adds
layers to that default for every run in scope. The demo and devel matrices list their layers (so `CHECK_LAYERS=all` and
`make validate CHECK_LAYERS="..."` can check them) but keep `default: []`: **not active** until the layers pass; see M19.

## Executing kas
`KAS_EXEC=kas-container` (default): `kas-container` with `KAS_CONTAINER_IMAGE` (the signed builder, by digest) and
`KAS_CONTAINER_ENGINE` (default `docker`); `KAS_EXEC=kas`: `kas` in the current environment (e.g. inside the signed runner
image, which contains kas and the Yocto host tools). Everything goes through `kas_run` in `_kas_runtime_args.sh`.

`mode` input: `build` (default) or `drill` (chapter 15); `pull_request` always runs `build`.

## Trust rules
### Tier and pool
The tier decides which matrix entries run and, once release and nightly jobs have their own runner pool and artifact
share, where the job runs and what it may write. For `pull_request` events the workflow file, including the caller's
`tier:` input, comes from the pull request, so the caller cannot be trusted. The matrix step therefore forces
`tier=push-pr` for every `pull_request`; the other tiers only come from `push`, `schedule`, `release` and maintainers'
`workflow_dispatch`.

The same rule picks the runner pool (chapter 05, "Pools"): the matrix step sets `pool=agl-fork` when the event is a
`pull_request` whose head repository is not the repository itself (a fork, or a deleted fork, so it fails closed), and
`pool=agl-pr` for everything else; the build job uses it in `runs-on`. It is decided from the event in the pinned
workflow, never from a caller input, so a pull request cannot pick the pool through the inputs of our workflow. **Limit:** a
fork's workflow file is the fork's own; it does not have to call our workflow and could name the label `agl-pr` in its own
`runs-on`. Two things stand in the way: the approval policy `all_external_contributors` (a maintainer must approve the run and read the
workflow change), and, from the runner image that carries it, the job-started hook of the trusted hosts, which refuses any pull request
whose head repository is not the repository itself before a step runs (chapter 05, "Security notes").
An `agl-fork` runner (untrusted host) is online; a fork pull request has not been run on it yet.

### The matrix file is untrusted input
The `ci/build-matrix.yaml` of a pull request is untrusted input (a fork can change `ci/build-matrix.yaml`). It cannot choose the pool,
the tier or the mode, but its values reach kas file paths, shell strings of the build job and artifact paths. `_matrix.py`
therefore checks every repo's file when it loads it and fails the `matrix` job, before anything is built, on: a target, feature,
machine or repo name that is not a plain name (`[A-Za-z0-9._-]`, no `..`, no leading dash), a tier outside
`push-pr|nightly|release|dispatch`, a non-boolean `sdk` or EULA flag, a `check_layers` path that is absolute or contains `..`,
more than 128 expanded entries (GitHub's own limit is 256 matrix jobs), and an entry on a machine that needs an EULA in the tier
`push-pr` (a pull request never accepts an EULA). `ci/scripts/_matrix_test.py` holds the cases, runs in the lint job, and was
checked to fail against the code before this change. What a hostile matrix can still do is build chosen images on the pool of its
trust level, which the pull request's own recipes can do anyway.

## Job time limit
The `build` job has `timeout-minutes: 1440` (24 h). The first build of an image on an empty cache is cold: `agl-image-minimal` took
about 4h28 (268 min), and two cold demo images (`agl-ivi-demo-flutter`, `agl-ivi-demo-qt`, built side by side on the two slots of the trusted host)
did not finish in the former 10 h and were cancelled. Tasks that finished are kept in the shared sstate, so a re-run resumes where
the cancelled one stopped and a warm build takes minutes. A job that hangs ties up a slot for the whole limit.

## Running on a desk
```
git clone https://github.com/dl9pf-agl/agl-ucb && cd agl-ucb
# the first engine run clones the layers via kas; for local edits see the agl-ucb README (--dev)
git clone https://github.com/dl9pf-agl/agl-ci ../agl-ci
AGL_TREE=$PWD CI=true ../agl-ci/ci/scripts/validate.sh --machine qemux86-64 --target agl-image-minimal
AGL_TREE=$PWD CI=true ../agl-ci/ci/scripts/build.sh    --machine qemux86-64 --target agl-image-minimal
```
To test local layer changes use the opt-in dev mode of agl-ucb (`kas/local/dev.yml`, `scripts/aglsetup.sh --dev`): kas then
never resets the layer clones. To build a specific commit set `AGL_PIN_REPO/URL/SHA` as above.
`CI=true` adds `ci-only.yml` (passwordless login for HIL tests, buildhistory, CI tuning). Cache: `AGL_SSTATE_DIR`,
`AGL_DL_DIR` (existing fragments in `agl-ucb/kas/local`); the kit sets both on the runner (chapter 05, "Shared cache"). `kas_runtime_args` mounts the directories at the
same path into the kas container and forwards the variable; `kas_extra_includes` adds the fragment of every variable that is set: the two cache directories, `AGL_MIRROR_URL` (`mirrors.yml`) and the hash server variables (chapter 14).

## Changes against the original
Tree root and matrices are parameters instead of the repo root; one `kas_run` instead of three `kas-container` call
sites; `recipe-lint` and the check-layer paths follow the repos in scope; the GitLab generator is left out.
