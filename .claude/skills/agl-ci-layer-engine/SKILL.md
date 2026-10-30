---
name: agl-ci-layer-engine
description: How the AGL layer CI works (agl-ci repo, dl9pf-agl org) - reusable workflow layer-ci.yml, SHA-pinned callers, kas-based layer checkout and the pin fragment, matrix schema and tiers, kas hard-reset trap and --dev mode, runner labels. Consult BEFORE editing agl-ci/ci/*, .github/workflows/layer-ci.yml, a layer repo's ci/build-matrix.yaml or caller ci.yml, agl-ucb kas/base.yml or scripts/aglsetup.sh, or when a layer CI run fails at checkout, validate or build.
---

# AGL layer CI (agl-ci engine)

## Repos
`dl9pf-agl/{agl-ucb (kas config, branch master), meta-agl, meta-agl-demo, meta-agl-devel (master), agl-ci (main)}`.
All CI logic is in agl-ci. The other four hold a ~12-line caller `.github/workflows/ci.yml` calling
`dl9pf-agl/agl-ci/.github/workflows/layer-ci.yml@<40-char SHA> # comment` (inputs `repo`, `tier`, `ucb_ref`, `kas_exec`)
plus their own `ci/build-matrix.yaml`. Bump the SHA after every agl-ci change (`sha_pinning_required` is on for all five repos: a run with an unpinned `uses:` fails at start; Dependabot).
`job.workflow_sha` / `job.workflow_repository` give the engine ref at runtime.

## Rules (user decisions)
- KISS/ponytail, reproducible, templatable, portable to GitLab/Forgejo/desk. Keep `docs/manual` current in the same commit.
- Layer checkout goes through kas, never a user-facing script. User flow: `git clone agl-ucb; scripts/aglsetup.sh -m qemux86-64`.
- Only `pull_request`, never `pull_request_target`; no secrets in PR builds; fork PRs need approval (env `agl-ci-build`).
- Required check: `ci / result` (set on meta-agl; the ruleset of agl-ci requires `lint`; agl-ucb, meta-agl-demo and meta-agl-devel have no ruleset yet). Runner labels in use: `agl-pr` and `agl-fork`; `agl-kvm` is reserved; `agl-release` is only listed in `.github/actionlint.yaml`, no workflow or host uses it.
- The user merges PRs. Never operate on the user's server; give commands.

## kas 5.5 facts (tested)
- clean clone with `branch:` and no `commit:` is hard-reset to branch tip (unpushed commits lost); dirty clone skipped.
- `url:` null/empty = local repo, kas never touches it -> `kas/local/dev.yml`, `aglsetup.sh --dev` (needs layers cloned).
- `commit:` pins exactly; fork URL + SHA works. Warning "Using branch without commit... unsafe" is normal.
- git root of the first config file = work dir for includes (scratch tree needs `git init`).

## Pin fragment
`ci/scripts/_kas_runtime_args.sh` `kas_ci_includes()` appends `build/ci-kas/ci-only.yml` (if `CI=true`) and
`build/ci-kas/layer-pin.yml` (if `AGL_PIN_REPO`), written from `AGL_PIN_REPO/URL/SHA` (url, `branch:` cleared, commit). Python
helpers use `$PY` = `/opt/kas/bin/python` when present (PyYAML only lives in the kas venv).

## Engine flow
`matrix` job (hosted): checkout agl-ci@workflow_sha + agl-ucb@ucb_ref, cosign verify builder digest
(`scripts/verify-release.sh`), run `ci/scripts/checkout.sh` inside the builder image (`--entrypoint /bin/bash`, KAS_EXEC=kas),
then `_matrix.py --json $tier`. `check-layer` job (once per run, parallel to `build`: `check-layer.sh`, full yocto-check-layer output in its log). `build` job on `[self-hosted, agl-pr]`: checkouts, `layers` step (checkout.sh), `validate.sh --verbose` (flag in layer-ci.yml: delete it to quiet the log; output in `::group::`s, addresses shown as set/unset),
`build.sh`, upload artifacts. `result` aggregates. Env: `AGL_TREE`, `KAS_EXEC=kas-container|kas`, `AGL_SCOPE`.
Matrix tiers: `push-pr | nightly | release | dispatch`. Digests: `ci/builder.digest`; bump via PR after `images` publishes.

## Gotchas seen
- hosted Python 3.12: `pip --require-hashes` fails on unpinned transitive deps -> run in the builder image.
- builder entrypoint must be mode 0755 (`COPY --chmod=0755`), else `[FATAL tini] exec /entrypoint.sh failed: Permission denied`.
- Space: the shared cache `CACHE_DIR` takes 50-150 GB (manual chapter 05); the workspace volume of a slot lives in Docker's data root.
- The cache pool and the callers for demo, devel and agl-ucb exist now; see the state section below.

## State since the pilot (2026-10)
- Generated pin writes the repo under test under `repos:` **and** `overrides:`; the matrix job fails if the tree is not at the commit under test (`agl-ci-trust-and-security`).
- `_matrix.py` validates matrix files as untrusted input; shared names in `ci/matrix-defaults.yaml` (`machine_sets`, `tier_presets` with `machine_tiers`); `needs:` builds demo after meta-agl and devel after demo (`AGL_SCOPE`).
- meta-agl, -demo, -devel float on their branch; `resolved-pins.sh` writes the release pin (`agl-ci-release-and-pins`).
- Labels in use: `agl-pr` (trusted), `agl-fork` (untrusted), `agl-kvm` reserved; `agl-release` is unused. Build job limit 48 h. Reading runs: `agl-ci-run-triage`; hosts: `agl-ci-hosts-and-pools`; caches: `agl-ci-mirror-and-cache`.

