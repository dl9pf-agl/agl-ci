---
name: yocto-bitbake
description: Hard-won Yocto/bitbake operational knowledge - layer/recipe conventions, what bitbake task signatures actually depend on (why moving a layer or recipe triggers a rebuild), yocto-check-layer's exact requirements, reading bitbake's task-log output and the sstate summary line, recovering from a build interrupted mid-compile, and the standalone bitbake CLI incantations this repo's scripts use (bitbake -e for a single variable, -S lockedsigs for a dry signature dump, -c clean, bitbake-layers). Consult this whenever interpreting a bitbake/yocto-check-layer log, debugging a recipe do_compile/do_fetch failure, explaining why a build suddenly needs to rebuild more than expected, or working with layer.conf/LAYERDEPENDS/BBFILE_COLLECTIONS. This is about Yocto/bitbake itself; see the kas-operations skill for the kas-container wrapper mechanics (env vars, command grammar) layered on top of it in this repo.
---

# Yocto / bitbake operational knowledge (this repo)

Fast-lookup reference, not a tutorial. Verified firsthand against this repo's actual bitbake
behavior. Pairs with the `kas-operations` skill, which covers the `kas`/`kas-container` wrapper
layered on top of everything here - this skill is about bitbake/Yocto itself.

## 1. Layer and recipe conventions

- A bitbake **layer** is any directory with a `conf/layer.conf` declaring (at minimum)
  `BBFILE_COLLECTIONS`, `BBFILE_PATTERN_<collection>`, `BBFILE_PRIORITY_<collection>`, and
  usually `LAYERDEPENDS_<collection>` (other layers it needs) and `LAYERSERIES_COMPAT_<collection>`
  (which Yocto release series it's validated against). A directory *without* `conf/layer.conf` is
  just a container/grouping directory, not a layer itself - e.g. in this repo, `meta-agl/` itself
  has no `conf/layer.conf`; `meta-agl/meta-agl-core/` does.
  - **Real repo example**: `meta-agl` is one upstream git repo (vendored here) containing several
    actual layers as subdirectories (`meta-agl-core`, `meta-agl-bsp`, `meta-pipewire`, etc.) -
    each with its own `conf/layer.conf`. Don't assume a git-repo boundary and a layer boundary
    are the same thing.
- Several real sublayers in this repo declare **no `LAYERDEPENDS` at all** despite clearly needing
  others (confirmed by reading their `conf/layer.conf`: zero `LAYERDEPENDS_<name>`, despite dozens
  of `.bbappend` files targeting recipes elsewhere) - a genuine upstream metadata gap, not
  something tooling can discover on its own. Where this matters, it has to be special-cased (see
  `ci/build-matrix.yaml`'s `check_layers.layers` entries with an explicit `additional_layers:`
  list).

## 2. What actually invalidates a bitbake task's sstate signature

Easy to under-estimate how much goes into a task's signature. Confirmed causes of **broad**
(not just one-recipe) sstate invalidation seen in this repo's history:

| Change | Effect |
|---|---|
| Moving the directory holding the outermost kas config file | Changes `BBPATH` (kas derives it from that file's location) - `BBPATH` feeds into the base configuration hash shared by virtually every task, so this invalidates nearly all signatures at once. One `Sstate summary: ... 0% match, 0% complete` rebuild, not a bug. |
| Moving a layer or recipe to a different path | A recipe's own file path (`FILE`, and layer-relative variables derived from it) is a signature input for that recipe's tasks - relocating a layer costs at least a partial rebuild of everything in it, even with file *contents* unchanged. |
| Changing which kas YAML fragments are loaded (different `kas/feature/*.yml` combo) | Can change `DISTRO_FEATURES`/`IMAGE_FEATURES`/layer set, each of which flows into dependent recipes' signatures - expect more rebuild the further upstream (toolchain-level) the change reaches. |

**Reading the tell**: `Sstate summary: Wanted N Local 0 Mirrors 0 Missed N Current 0 (0% match, 0%
complete)` near the top of a build log means "full rebuild incoming" - set expectations (and
patience) before committing to babysit a long build. A normal incremental build shows a high
`Current`/match percentage instead.

## 3. `yocto-check-layer`

- Needs `--dependency <root> [<root> ...]` - directories recursively scanned for `conf/layer.conf`
  files so it can auto-resolve each checked layer's declared `LAYERDEPENDS_<name>`. Layers with no
  `LAYERDEPENDS` (see §1) need `--additional-layers <path> [<path> ...]` force-added on top, or
  the check fails on a missing-dependency error that auto-resolution can't see.
- **Must run against a "bare" config** - no AGL/distro-specific layers pre-loaded beyond what's
  under test - because `yocto-check-layer` manages its own layer-under-test additions internally;
  running it against a config that already has the same layer loaded causes a duplicate
  `BBFILE_COLLECTIONS` conflict. This repo's `kas/_validate-base.yml` exists specifically to be
  this bare base (deliberately omits `kas/base.yml`, which pre-loads `meta-agl-core`/`meta-agl-bsp`,
  and never sets `DISTRO=agl`).
- Internally runs a **full world-parse signature dump** (`bitbake -S lockedsigs world`, then a
  second `-k` keep-going pass) - this is genuinely slow (minutes, even with a warm cache) and is
  the single slowest step in `make validate`. Don't mistake "no new log output for a while" during
  this step for a hang; check for live child processes before assuming something's stuck.

## 4. Recovering from a build interrupted mid-compile

**Never let a long bitbake run get SIGTERM'd mid-`make -j`** (e.g. a tool/harness enforcing a
wall-clock timeout on a foreground command) - a forced kill corrupts in-progress artifacts.
Confirmed failure signatures from exactly this:

- A static archive missing its ranlib index: `archive has no index; run ranlib to add one`,
  surfacing later as `undefined reference to 'main'` or similar linker errors in a tool that
  previously built fine.
- A git mirror (under `build/downloads/git2/<host>.<org>.<repo>.git`) left with an invalid HEAD
  after a kill mid-fetch - `git fsck --full` on it shows `error: invalid HEAD` even though the
  specific commit object is present; bitbake then reports a confusing
  `Unable to find revision ... even from upstream` even though the revision genuinely exists and
  network access is fine (verify with `curl -sI https://github.com` before assuming a real
  outage).

**Recovery**, once you suspect this (don't assume a real regression first if the failure comes
right after an interruption):
1. `bitbake -c clean <recipe>` (one or more recipe names) to force a clean rebuild of just the
   affected recipe(s) - cheap, since it reuses everything else's sstate.
2. For a corrupted git mirror specifically: `rm -rf build/downloads/git2/<corrupted-mirror>` to
   force a fresh re-clone on the next `do_fetch`.
3. See the `kas-operations` skill for how to launch the *next* attempt detached from the
   invoking session so this doesn't recur.

## 5. Standalone bitbake CLI patterns used by this repo's scripts

| Command | Purpose |
|---|---|
| `bitbake -e <target> \| grep -E '^LICENSE='` | Extract one expanded variable's final value without building anything - this repo's `license-manifest` check. |
| `bitbake -S lockedsigs world` (then a second pass with `-k`) | Dump task signatures for every recipe without building - what `yocto-check-layer` does internally (§3); also a way to force a full dependency/signature recompute. |
| `bitbake -p` | Parse all recipes without building - catches syntax/parse errors fast, the `bitbake-parse` check in `make validate`. |
| `bitbake -c clean <recipe>` | Clean one recipe's build state (not sstate-wide) - the standard recovery step for a corrupted/stale single-recipe build (§4). |
| `bitbake -c populate_sdk <target>` | Build the SDK for a target - gated in `ci/scripts/build.sh` by both the matrix entry's `sdk:` flag and `SDK_ALLOWED`. |
| `bitbake-layers show-layers` | List every loaded layer with its path and priority - fast way to confirm a kas config change actually loaded the layers you expect (run via `kas-container shell KASFILE -c "bitbake-layers show-layers"` for a non-interactive check). |

## 6. Misc real gotchas worth remembering

- **git fetcher branch reachability**: bitbake's git fetcher requires a `SRCREV` to be reachable
  from the declared `branch=` by default. An upstream force-push can leave a previously-good
  `SRCREV` still valid as a *tag* but no longer reachable from the branch name - fetch then fails
  even though the commit still exists. Fix is a `.bbappend` adding `nobranch=1` to that recipe's
  `SRC_URI` (seen in this repo: `meta-openembedded`'s `grpc_1.80.0.bb`, fixed via
  `meta-agl/meta-agl-core/recipes-devtools/grpc/grpc_%.bbappend`).
- **`oe-init-build-env`/`TEMPLATECONF`**: the stock Yocto build-dir bootstrap (sourced by classic
  `aglsetup.sh`, not used directly by this repo's kas-based flow, but worth knowing if you ever
  touch anything derived from classic AGL tooling) - copies `local.conf.sample`/
  `bblayers.conf.sample` into a new build dir's `conf/` on first run, no-ops (just `cd`s in) if
  `conf/local.conf` already exists.
- SPDX/SBOM generation tasks (`do_create_spdx`, `do_create_package_spdx`, `do_create_image_spdx`,
  `do_create_image_sbom_spdx`) appear near the end of a successful image build's task list - normal,
  not a sign bitbake is doing something unusual, just part of the default task graph.
