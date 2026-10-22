# 13 Layer CI engine

Status: engine imported and adapted; **tested locally with a stand-in `kas`** (setup, build, validate, matrix scope,
both execution modes). Not yet run with real kas/bitbake; the GitHub workflow that calls it is the next step.

## Origin
Imported from the monolithic AGL CI repo (`ci/scripts`, `kas/ci-only.yml`, `kas/_validate-base.yml`) instead of writing a
new planner: its matrix schema, tiers and checks were already in use. GitLab files of the original (`ci/gitlab`) are not
imported yet (they still call `make`); the matrix and scripts are forge-independent, so only a thin adapter is missing.

## Layout
- **Build tree** = a checkout of `agl-ucb` (kas fragments, `kas/pins.yml`) with `meta-agl`, `meta-agl-demo`,
  `meta-agl-devel` cloned inside by `agl-ucb/scripts/checkout-layers.sh`. `agl-ucb` stays the single source of kas
  configuration and pins; layer repos do not carry base/machine/pins files.
- **Engine** = `agl-ci/ci/scripts` (+ `ci/kas/*.yml`, staged into `<tree>/build/ci-kas/` at run time because kas needs
  them inside the work dir).
- `AGL_TREE` selects the tree (default: current directory).

## Matrices
Each layer repo has `ci/build-matrix.yaml` with only its own images (schema: header of `_matrix.py`; tiers
`push-pr | nightly | release | dispatch`, per-machine tier overrides). `needs: [<repo>]` declares the dependency chain
(demo needs meta-agl, devel needs demo). With `AGL_SCOPE=<repo>` a run covers that repo plus every repo that needs it
(transitively), so a `meta-agl` change also runs the downstream images; a `meta-agl-devel` change runs only devel.
Without `AGL_SCOPE` all repos in the tree are included (nightly).

## Executing kas
`KAS_EXEC=kas-container` (default): `kas-container` with `KAS_CONTAINER_IMAGE` (the signed builder, by digest) and
`KAS_CONTAINER_ENGINE` (default `docker`); `KAS_EXEC=kas`: `kas` in the current environment (e.g. inside the signed runner
image, which contains kas and the Yocto host tools). Everything goes through `kas_run` in `_kas_runtime_args.sh`.

## Running on a desk
```
git clone https://github.com/dl9pf-agl/agl-ucb && cd agl-ucb && scripts/checkout-layers.sh
git clone https://github.com/dl9pf-agl/agl-ci ../agl-ci
AGL_TREE=$PWD CI=true ../agl-ci/ci/scripts/validate.sh --machine qemux86-64 --target agl-image-minimal
AGL_TREE=$PWD CI=true ../agl-ci/ci/scripts/build.sh    --machine qemux86-64 --target agl-image-minimal
```
`CI=true` adds `ci-only.yml` (passwordless login for HIL tests, buildhistory, CI tuning). Cache: `AGL_SSTATE_DIR`,
`AGL_DL_DIR` (existing fragments in `agl-ucb/kas/local`); the shared-cache policy for the runner is decided in the next steps.

## Changes against the original
Tree root and matrices are parameters instead of the repo root; one `kas_run` instead of three `kas-container` call
sites; `recipe-lint` and the check-layer paths follow the repos in scope; the GitLab generator is left out.
