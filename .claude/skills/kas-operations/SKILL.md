---
name: kas-operations
description: Hard-won operational knowledge for calling kas and kas-container in this repo - environment variables (KAS_TARGET, KAS_WORK_DIR, KAS_BUILD_DIR, KAS_CONTAINER_IMAGE), how this repo composes its kas/ YAML fragments, kas-container's exact command grammar, and how to safely run and debug long bitbake builds without corrupting them. Consult this BEFORE running make build/validate/setup, scripts/aglsetup.sh, or any direct kas-container/kas invocation in this repo, and whenever a kas-related command fails in a way that looks confusing (wrong target built, missing tool inside the container, a build that fails right after being interrupted, sstate suddenly at 0%). Also consult it before moving/renaming anything under kas/ or changing a repos: path: in a kas YAML fragment.
---

# kas / kas-container operational knowledge (this repo)

Fast-lookup reference, not a tutorial. Everything here was verified firsthand against this
repo's actual `kas`/`kas-container` behavior - quote the relevant section back when explaining
*why* something needs doing, don't just follow it blindly.

## 1. Environment setup (do this before anything else)

| Need | How | Why it matters |
|---|---|---|
| Docker daemon | `sudo dockerd --storage-driver=vfs --group=docker > log 2>&1 & disown` (if not already running) | `kas-container` shells out to `docker run` - nothing works without a daemon. **Confirm with the user before running sudo**, even if it's available. |
| Docker group | Wrap docker commands in `sg docker -c '...'` | The invoking shell is often in the `docker` group in `/etc/group` but started before that membership took effect - bare `docker`/`kas-container` calls then fail with a permission error. `sg docker -c '...'` sidesteps this without needing `newgrp` or a new login shell. |
| `KAS_CONTAINER_IMAGE` | `docker build -f ci/docker/Dockerfile -t agl-ci-builder:dev .` then `export KAS_CONTAINER_IMAGE=agl-ci-builder:dev` | Without this, `kas-container` defaults to the upstream `ghcr.io/siemens/kas/kas:5.5` image, which has `kas` but **not** `oelint-adv` - `make validate`'s `recipe-lint` sub-check fails with a plain "No such file or directory" that looks like a repo bug but isn't. GitHub Actions CI sets this automatically from its own build-image job; local runs must do it by hand. Documented in `docs/setup.md` but easy to skip. |

## 2. Environment variables kas / kas-container read

| Variable | Effect | Gotcha |
|---|---|---|
| `KAS_WORK_DIR` | Repo root mounted as `/work` in the container | Defaults to `$(pwd)` if unset (confirmed in kas-container's `setup_kas_dirs()`), but every script in this repo sets it explicitly (`KAS_WORK_DIR="$REPO_ROOT" kas-container ...`) for robustness - do the same in new scripts. |
| `KAS_TARGET` | Overrides the bitbake build target | kas's own config resolver (`kas/config.py` in the installed `kas` package) checks `KAS_TARGET` (space-delimited) **before** falling back to the schema default (`core-image-minimal`) or any `target:` key in the YAML. `kas-container` auto-forwards it into the container (see whitelist below) - no extra plumbing needed once it's exported. **Real incident**: `ci/scripts/build.sh` used to omit this, so `kas-container build` silently built `core-image-minimal` instead of the matrix-resolved target for a long time before it was caught. If a build produces the wrong image name, check this first. |
| `KAS_BUILD_DIR` | Redirects where kas puts its build dir (TMPDIR/sstate/etc.) | Setting it auto-creates the directory and kas-container mounts/forwards it correctly whether the path is inside or outside the repo root (`forward_dir()`/`setup_kas_dirs()` - no manual `mkdir`/`realpath` needed). Useful for running isolated machine/feature combos without colliding on the shared `build/`. |
| `DL_DIR`, `KAS_REPO_REF_DIR`, `SSTATE_DIR`, `BB_HASHSERVE_DB_DIR`, `KAS_BUILDTOOLS_DIR` | Same auto-create/auto-mount treatment as `KAS_BUILD_DIR` | Via the same `forward_dir()` mechanism. |

**kas-container's fixed env-var passthrough whitelist** (confirmed by reading its source): `TERM`,
`KAS_DISTRO`, `KAS_MACHINE`, `KAS_TARGET`, `KAS_TASK`, `KAS_CLONE_DEPTH`, `KAS_PREMIRRORS`,
`DISTRO_APT_PREMIRRORS`, `BB_NUMBER_THREADS`, `PARALLEL_MAKE`, `GIT_CREDENTIAL_USEHTTPPATH`,
`BB_HASHSERVE`, `BB_HASHSERVE_UPSTREAM`, `NO_COLOR`, `TZ`, plus the directory-forwarding vars
above. **Anything else needs `--runtime-args -e --runtime-args VAR=value` - two separate
`--runtime-args` occurrences**, not one `--runtime-args "-e VAR=value"` (its parser consumes
exactly one following word per `--runtime-args` flag). See `ci/scripts/_kas_runtime_args.sh`'s
`kas_runtime_args()` for the established pattern (e.g. how `AGL_SSTATE_DIR` is wired through).

## 3. How this repo composes its kas YAML

- Fragments live in `kas/` at the repo root: `base.yml`, `pins.yml`/`floating.yml`,
  `machine/<name>.yml`, `feature/<name>.yml`, `ci-only.yml`, `_validate-base.yml`.
- A kas invocation takes a **colon-joined list** of these as its `KASFILE` argument, e.g.
  `kas/base.yml:kas/machine/qemux86-64.yml:kas/feature/agl-demo.yml:kas/pins.yml`. kas merges
  `repos:`/`layers:` additively across files.
- Feature fragments auto-pull-in their own dependencies via kas's native `header.includes:`
  field (e.g. `kas/feature/agl-demo.yml` includes `agl-pipewire.yml`, `agl-app-framework.yml`,
  etc.) - this mirrors classic AGL's `aglsetup.sh`/`included.dep` transitive-dependency graph,
  resolved natively by kas when it loads the files. **Never manually expand feature
  dependencies** - just pass through the literal top-level feature names.
- A `repos:` entry's `path:` controls where kas checks it out. **GOTCHA**: moving the directory
  that holds the *outermost* kas config file changes `BBPATH` (derived from that file's
  location), which invalidates essentially every task's sstate signature on the next build -
  confirmed when `ci/kas/` was moved to `kas/` in this repo's history (went from a warm cache to
  `Sstate summary: ... 0% match, 0% complete`). This is a one-time cost, not a sign something
  broke - warn the user about it before/after relocating a kas config directory, but don't treat
  the resulting full rebuild as a regression.
- A `repos:` entry with **no `url:`** is treated as already-present/vendored, never fetched by
  kas. This repo vendors `meta-agl`, `meta-agl-demo`, `meta-agl-devel` this way (git subtree),
  unlike `external/*` repos, which *do* have `url:`/`branch:` and get pinned commits in
  `kas/pins.yml`.
- `ci/scripts/_compose_kasfiles.py --no-matrix` builds a kasfiles list for an arbitrary
  machine/feature combo **without** requiring a `ci/build-matrix.yaml` entry to match - use this
  (or `scripts/aglsetup.sh`, built on top of it) for free-form local exploration instead of
  hand-rolling the colon-join logic.

## 4. kas-container command grammar

- `kas-container {checkout,build,shell} KASFILE[:KASFILE...]` - only a colon-joined file-list
  positional arg plus flags. **There is no bare positional "target name" argument for `build`**
  (confirmed in kas's own `plugins/build.py` argparse setup) - use the `KAS_TARGET` env var or a
  repeatable `--target` flag instead.
- `kas-container shell KASFILE -c "some command"` runs one non-interactive command inside the
  container and exits - the right tool for scripted smoke-tests (e.g.
  `bitbake-layers show-layers`, `bitbake -p`) when you don't have a real interactive TTY, e.g.
  verifying a kas config change from an agent session rather than a human terminal.
- `kas menu <path/to/Kconfig>` opens an interactive ncurses-style menu for exploring
  machine/feature combos outside the curated matrix, writing a `.config.yaml`. This repo's
  `scripts/aglsetup.sh -m <machine> <feature...>` is the non-interactive, scriptable sibling of
  the same bypass-the-matrix idea.

## 5. Running and debugging long bitbake builds safely

**Never run a long build (anything beyond a few minutes) as a foreground command inside a
tool/harness that will SIGTERM the whole process tree after some wall-clock limit** (commonly
~10 minutes in constrained agent environments). A forced kill mid-`make -j` corrupts in-progress
build artifacts. Symptoms actually seen from this:
- A static archive missing its ranlib index: `archive has no index; run ranlib to add one`.
- A git mirror left with an invalid HEAD after a kill mid-fetch, producing a misleading
  `Unable to find revision ... even from upstream` error even though the revision exists and
  network access is fine.

**Fix: launch the build fully detached from the invoking session**, immune to the parent being
killed:
```sh
setsid bash -c '... > build.log 2>&1' < /dev/null > /dev/null 2>&1 &
disown
```
Then poll/tail the log file separately (a `Monitor` watching for
`Tasks Summary|ERROR|artifacts in` is a good filter) without ever signaling the detached process
group. This pattern was proven in this repo by `dockerd` itself surviving an entire multi-hour
session this way.

**If a build fails right after an interruption** with a corrupted-artifact-shaped error (broken
archive, "invalid HEAD", a linker error like `undefined reference to main` in a tool that
clearly used to build fine) - **suspect corruption from that interruption before assuming a real
regression**:
1. `kas-container shell KASFILE -c "bitbake -c clean <recipe>"` to force a clean rebuild of just
   that recipe, or
2. `rm -rf build/downloads/git2/<corrupted-mirror>` to force a fresh re-clone of a corrupted git
   mirror - verify corruption first with `git fsck --full` (look for "invalid HEAD" or dangling
   commits) inside the mirror directory, and confirm plain network connectivity
   (`curl -sI https://github.com`) so a real outage isn't misdiagnosed as corruption.

**Reading the cache-hit signal**: `Sstate summary: Wanted N Local 0 Mirrors 0 Missed N Current 0
(0% match, ...)` near the start of a build log means a full rebuild from scratch is coming (set
expectations accordingly, including about commiting to watching it to completion); a high
`Current`/match % means a normal incremental build.
