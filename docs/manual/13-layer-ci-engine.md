# 13 Layer CI engine

Status: engine imported and adapted; **tested locally with a stand-in `kas`** (setup, build, validate, matrix scope,
both execution modes). Not yet run with real kas/bitbake; the GitHub workflow that calls it is the next step.

## Origin
Imported from the monolithic AGL CI repo (`ci/scripts`, `kas/ci-only.yml`, `kas/_validate-base.yml`) instead of writing a
new planner: its matrix schema, tiers and checks were already in use. GitLab files of the original (`ci/gitlab`) are not
imported yet (they still call `make`); the matrix and scripts are forge-independent, so only a thin adapter is missing.

## Layout
- **Build tree** = a checkout of `agl-ucb` (kas fragments, `kas/pins.yml`). kas clones `meta-agl`, `meta-agl-demo`
  and `meta-agl-devel` into it (`url:`/`branch:` in `agl-ucb/kas/base.yml`), exactly as on a developer desk. `agl-ucb`
  stays the single source of kas configuration and pins; layer repos do not carry base/machine/pins files.
- **Repo under test** = env `AGL_PIN_REPO`, `AGL_PIN_URL` (fork URL for fork PRs), `AGL_PIN_SHA`. The engine writes
  `<tree>/build/ci-kas/layer-pin.yml` (`url`, `commit`, `branch:` cleared) and appends it last to the kas chain, so kas
  builds exactly that commit and nothing is reset to a branch tip. The `matrix` job first runs `ci/scripts/checkout.sh`
  (`kas checkout` of `base.yml` + `pins.yml` + the pin; `pins.yml` in agl-ucb pins the externals, `meta-agl-demo` and `meta-agl-devel`, so no layer follows a branch tip except the repo under test) so the `ci/build-matrix.yaml` files exist before the matrix is computed.
- **Engine** = `agl-ci/ci/scripts` (+ `ci/kas/*.yml`, staged into `<tree>/build/ci-kas/` at run time because kas needs
  them inside the work dir).
- `AGL_TREE` selects the tree (default: current directory).

## Matrices
Each layer repo has `ci/build-matrix.yaml` with only its own images (schema: header of `_matrix.py`; tiers
`push-pr | nightly | release | dispatch`, per-machine tier overrides). `needs: [<repo>]` declares the dependency chain
(demo needs meta-agl, devel needs demo). With `AGL_SCOPE=<repo>` a run covers that repo plus every repo that needs it
(transitively), so a `meta-agl` change also runs the downstream images; a `meta-agl-devel` change runs only devel.
Without `AGL_SCOPE` all repos in the tree are included (nightly). The nightly of `meta-agl` therefore already covers the
images of demo and devel; their callers have no schedule of their own.

**Shared names (`ci/matrix-defaults.yaml`).** What every repo would repeat lives in agl-ci, next to the engine and pinned with
it: `machine_sets` (`ci` = qemux86-64, qemuarm64, raspberrypi5, sparrow-hawk) and `tier_presets` (`dispatch`, `nightly`, `gate`
= pull request gate on qemux86-64 plus nightly on every machine, `nightly-x86`). An image says `machines: ci` and `tiers: gate`
and lists only what differs (an explicit machine list, an explicit tiers list, or a `{tiers: [...]}` on one machine entry
override the names). An unknown name is an error. The expansion is identical to the spelled-out form (checked for the demo and
devel matrices: same 38 entries).

**The caller needs no inputs.** `layer-ci.yml` takes the repo under test from `github.event.repository.name`, and the tier and
mode of a manual run from the event's own inputs; a caller may still pass `repo`, `tier` and `mode`. A caller is the triggers
plus one `uses:` line pinned by commit.

**yocto-check-layer.** `validate.sh` checks `meta-agl/meta-agl-core` by default. `check_layers.default` in a repo's matrix adds
layers to that default for every run in scope. The demo and devel matrices list their layers (so `CHECK_LAYERS=all` and
`make validate CHECK_LAYERS="..."` can check them) but keep `default: []`: **not active** until the layers pass; see M19.

## Executing kas
`KAS_EXEC=kas-container` (default): `kas-container` with `KAS_CONTAINER_IMAGE` (the signed builder, by digest) and
`KAS_CONTAINER_ENGINE` (default `docker`); `KAS_EXEC=kas`: `kas` in the current environment (e.g. inside the signed runner
image, which contains kas and the Yocto host tools). Everything goes through `kas_run` in `_kas_runtime_args.sh`.

`mode` input: `build` (default) or `drill` (chapter 15); `pull_request` always runs `build`.

## Trust rule for the tier
The tier decides which matrix entries run and, once release and nightly jobs have their own runner pool and artifact
share, where the job runs and what it may write. For `pull_request` events the workflow file, including the caller's
`tier:` input, comes from the pull request, so the caller cannot be trusted. The matrix step therefore forces
`tier=push-pr` for every `pull_request`; the other tiers only come from `push`, `schedule`, `release` and maintainers'
`workflow_dispatch`.

The same rule picks the runner pool (chapter 05, "Pools"): the matrix step sets `pool=agl-fork` when the event is a
`pull_request` whose head repository is not the repository itself (a fork, or a deleted fork, so it fails closed), and
`pool=agl-pr` for everything else; the build job uses it in `runs-on`. It is decided from the event in the pinned
workflow, never from a caller input, so a pull request cannot edit its way onto the trusted pool. Fork pull requests
wait until an `agl-fork` runner (an untrusted host) exists.

## Reusable workflow
`.github/workflows/layer-ci.yml` is called by the layer repos, pinned by full SHA. Inputs: `repo` (repo under test, scopes
the downstream chain), `tier` (default: derived from the event), `kas_exec` (`kas-container` | `kas`), `ucb_ref` (agl-ucb
ref to build with, default branch when empty; use it to test an agl-ucb branch before merging). The builder image is
pinned in `ci/builder.digest` and verified (`scripts/verify-release.sh`) in the `matrix` job. Bump the digest after every
published builder (digest in the `publish` job log of the `images` run on `main`).

## Running on a desk
```
git clone https://github.com/dl9pf-agl/agl-ucb && cd agl-ucb
scripts/# the first engine run clones the layers via kas; for local edits see agl-ucb README (--dev)
git clone https://github.com/dl9pf-agl/agl-ci ../agl-ci
AGL_TREE=$PWD CI=true ../agl-ci/ci/scripts/validate.sh --machine qemux86-64 --target agl-image-minimal
AGL_TREE=$PWD CI=true ../agl-ci/ci/scripts/build.sh    --machine qemux86-64 --target agl-image-minimal
```
To test local layer changes use the opt-in dev mode of agl-ucb (`kas/local/dev.yml`, `scripts/aglsetup.sh --dev`): kas then
never resets the layer clones. To build a specific commit set `AGL_PIN_REPO/URL/SHA` as above.
`CI=true` adds `ci-only.yml` (passwordless login for HIL tests, buildhistory, CI tuning). Cache: `AGL_SSTATE_DIR`,
`AGL_DL_DIR` (existing fragments in `agl-ucb/kas/local`); the kit sets both on the runner (chapter 05, "Shared cache"). `kas_runtime_args` mounts the directories at the
same path into the kas container and forwards the variable; `kas_extra_includes` adds the two fragments.

## Changes against the original
Tree root and matrices are parameters instead of the repo root; one `kas_run` instead of three `kas-container` call
sites; `recipe-lint` and the check-layer paths follow the repos in scope; the GitLab generator is left out.
