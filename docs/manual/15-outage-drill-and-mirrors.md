# 15 Outage drill, mirrors and open items

Status: drill script **tested with a stand-in `kas` only** (flow, exit codes, miss list); not yet run with real bitbake.
Mirrors are **decided, not built**. The open-items table at the end is the single list of what is still missing.

## Requirement
Builds must survive an upstream outage at three levels:
- **T1** keep building on the existing builder (incremental builds, warm cache);
- **T2** clean rebuild on a new or rebuilt builder (disk loss, new host);
- **T3** rebuild or verify an old release years later.

## What a CI build depends on, and the answer for each
Marked V = verified in documentation or source; the rest is proven by the drill.

| # | Dependency | Answer |
|---|---|---|
| L1 | kas layer clones: 18 distinct repo URLs on git.yoctoproject.org, github.com, git.openembedded.org (V) | Own git mirrors and `KAS_PREMIRRORS` (V: "alternatives for repo URLs", regular expression plus replacement, forwarded by kas-container). `KAS_REPO_REF_DIR` (V: directories named `host.org.repo.git`, missing repos are cloned below it) is the alternative; whether kas still contacts the remote for a pinned commit that is already present is **not stated**, test it (drill C). |
| L2 | Recipe sources: `SRC_URI` hosts in meta-agl alone are github.com (39), gerrit.automotivelinux.org (9), strlcat.eu (11), gitlab.freedesktop.org (2) and more (V), plus every upstream of oe-core and meta-openembedded | `PREMIRRORS` pointing at our mirror, tried before upstream (V order: DL_DIR, PREMIRRORS, upstream, MIRRORS). `agl.conf` only has `MIRRORS` to download.automotivelinux.org, which is tried last and is AGL's server, not ours. Nightly and release jobs set `BB_GENERATE_MIRROR_TARBALLS = "1"` (V: git tarballs into DL_DIR) and run `fetchall` for every matrix target. |
| L3 | sstate | `SSTATE_MIRRORS` to our HTTP mirror, filled by nightly and release jobs. |
| L4 | Proof that L1-L3 are complete | The drill below. |
| L5 | Builder image pulled by `kas-container` into the fresh DinD of every job from GHCR | Run the build with `KAS_EXEC=kas` inside the runner image (it is built `FROM` the builder), or a pull-through registry cache on the host. |
| L6 | GitHub (scheduling, `uses:` actions, OIDC for keyless signing) | Cannot be removed. Break-glass: run the engine scripts by hand on the runner host; release signing falls back to the YubiKey path of chapter 06. |
| L7 | Sigstore (Fulcio, Rekor, TUF) for verification | Keep the Rekor bundle with the release; cosign supports offline verification with a bundle (README: `cosign save`, `--offline`, `--local-image`). |
| L8 | Image rebuild inputs (snapshot.debian.org, PyPI, GitHub release binaries, base image) | Releases keep the image files themselves (OCI archive), so a rebuild is not needed for T3. An input mirror stays a low-priority item. |
| L9 | Runner kit deploy (apt, cosign binary, GHCR) | Keep local copies, document. |

## The drill
`ci/scripts/drill.sh --machine M --features F --target T [--mode fetchall|build]` adds `build/ci-kas/ci-offline.yml`
(`BB_NO_NETWORK = "1"`: any network access in the bitbake fetcher is an error) and runs:
- **fetchall** (minutes): `bitbake -k --runall=fetch <target>` (image recipes have no `do_fetchall`, `--runall` runs the task for every recipe in the target's task graph). Every `SRC_URI` of the target closure must come from DL_DIR or a
  mirror. `-k` makes one run list every miss. It cannot see fetches inside `do_compile`.
- **build** (hours): the full build. Use an empty sstate dir so every task runs; this finds recipes that fetch while
  compiling (npm, pub, cargo, flutter).

Results go to `build/drill-results/`: `<mode>.log`, `misses.txt` (distinct "Network access disabled", "Fetcher failure"
lines). Exit status is non-zero when bitbake fails or any miss is listed. kas still clones the layers from the network
in this drill; offline layers are drill C (see M6, M15).

Run it from GitHub: call the reusable workflow with `mode: drill` (a `workflow_dispatch` input in the caller); the build
job then runs `drill.sh` instead of `validate.sh` and `build.sh`. For a `pull_request` the mode is always `build` (a pull
request must not replace validate and build by a drill and still get a green `result`). By hand on the runner host,
inside a tree: `AGL_TREE=... KAS_EXEC=kas CI=true ci/scripts/drill.sh ...`.

Optional hardening: add `BB_FETCH_PREMIRRORONLY = "1"` to the offline fragment (V: only PREMIRRORS are searched) to test
the mirrors alone, ignoring the upstream URL of every recipe.

## First drill results (2026-10-26, meta-agl, qemux86-64)
- `agl-image-minimal` (warm cache): every recipe source comes from DL_DIR offline. One miss: the **uninative tarball**.
- weston, compositor, core-autobuilder (cold cache, never built here): 24 to 38 misses, all recipe sources. They show what
  the mirror must hold: github.com, gitlab.freedesktop.org, git.sr.ht, git.yoctoproject.org, gerrit.automotivelinux.org,
  download.gnome.org, x.org, freedesktop.org and a few single-project hosts. Git sources need
  `BB_GENERATE_MIRROR_TARBALLS` to become mirrorable files.
- Image recipes have no `do_fetchall`; the drill uses `bitbake --runall=fetch`.

Uninative (V: `uninative.bbclass`): on `BuildStarted` the handler returns early if the loader is already extracted in
`${TMPDIR}/sysroots-uninative`; otherwise it fetches `${UNINATIVE_DLDIR}/<sha256>/<tarball>` (`UNINATIVE_DLDIR` is
`${DL_DIR}/uninative/`), tries `PREMIRRORS` lines starting with `http` first (rewritten to
`<mirror>/uninative/<sha256>/<tarball>`, so the mirror needs that layout) and extracts it. In a CI job the first bitbake
run is `yocto-check-layer` of `validate.sh`; it used the bare `_validate-base.yml` without `dl-shared.yml`, so the
tarball went to the throw-away `build/downloads` and the build step then found the loader and never touched the shared
`DL_DIR`. The shared cache therefore never held it. Fixed by giving the `yocto-check-layer` step the shared downloads
(`kas_dl_include`; sstate stays private to it). The drill skips `validate.sh`, so it is the first run to need the file
from `DL_DIR`.

## Mirrors in the build path (decided)
No NFS server (verified in bitbake: `BB_HASHSERVE_DB_DIR` on NFS is fatal, the sqlite file must stay local). Every
builder keeps its permanent local cache (`CACHE_DIR`, chapter 05) and reads the shared HTTP mirrors; **nightly and
release jobs fill the mirrors** (single writer). Test phase: the mirror is a directory on the runner host served by
Apache. Final: a separate Apache machine; the transport for writing (staging directory on NFS, or the server pulls) is
decided at provisioning.

### Filling the download cache (`mode: fetch`)
`ci/scripts/fetch.sh --machine M --features F --target T` runs `bitbake -k --runall=fetch <target>` with the network
on and `build/ci-kas/ci-mirror.yml` (`BB_GENERATE_MIRROR_TARBALLS = "1"`). It fetches every source of the target into
`AGL_DL_DIR` and writes a `git2_*.tar.gz` for every git source, because a plain `git2/` clone cannot be served as a
file over HTTP. The reusable workflow runs it for `mode: fetch`; a caller adds a scheduled job with `tier: dispatch`
(selects every image of the matrix, also the ones that are not built nightly) and `mode: fetch`. Only trusted events
can use it: a `pull_request` is always `mode: build`.

V (`fetch2/__init__.py`, `fetch2/git.py`): `build_mirror_data` runs only after an upstream `download`, and the git
tarball is written only when `BB_GENERATE_MIRROR_TARBALLS` is not `0`. Not verified: whether a source that is already
cloned in `DL_DIR` gets its tarball on the next run. Check after the first fill: `ls $AGL_DL_DIR/git2_*.tar.gz | wc -l`
against the number of `git2/` directories; if they differ, fill into an empty directory once.

## Folder growth
`/srv/mirror/{sstate,dl}`, `/srv/artifacts` and `CACHE_DIR` each get their own filesystem or volume, so a full mirror
cannot stop Docker. One writer per area. sstate: prune with `sstate-cache-management` or by age (check whether the
filesystem keeps access times first). dl: keep the files that the pins of the last N releases and the current nightly
need (compare with the `fetchall` list), delete the rest. Artifacts follow the retention of the artifact chapter
(PR: while open and 14 days after close or merge, nightly 8 days, release forever). Alert at 80 and 90 percent; the
size report belongs in the job summary.

## Open items (keep current)
| ID | Item | Status |
|---|---|---|
| M1 | Apache vhost: /artifacts, /sstate, /dl, TLS, write path | open (server side) |
| M2 | `publish-artifacts.sh` copying a whitelist plus manifest to `ARTIFACT_DEST=dir:`; staging, published, rejected trees; routing by pool | open |
| M3 | Mirror publisher step in nightly and release (rsync sstate and dl, single writer) | open |
| M4 | `kas/local/mirrors.yml` in agl-ucb: `SSTATE_MIRRORS`, `PREMIRRORS` from `AGL_MIRROR_URL`, AGL's `MIRRORS` stays as last line | open |
| M5 | `BB_GENERATE_MIRROR_TARBALLS=1` and a fetch of all matrix targets in nightly and release | `fetch.sh` and `mode: fetch` done; the scheduled call in the layer callers pending; git tarballs for already cloned sources to be checked on the first run |
| M6 | Git mirrors for the 18 kas repos and `KAS_PREMIRRORS` | open |
| M7 | Outage drill | script done (stand-in kas); run on real bitbake pending |
| M8 | No per-job builder pull (`KAS_EXEC=kas` in the runner image or pull-through registry) | open |
| M9 | Registry experiment zot and registry:3, `mirror-image.sh`, optional mirror job, OCI archive per release | open |
| M10 | Break-glass procedure, YubiKey release signing, Sigstore offline bundles | open |
| M11 | Pruning, quotas, monitoring, backups (hashserv DB, release artifacts) | open |
| M12 | Production cache split (agl-pr read-only, agl-release read-write) | later |
| M13a | Deploy the wrynose hashserv/prserv container (chapter 14, "Deployment on the build host") | image done and tested for liveness; deployment on the host: user |
| M13b | Wire `BB_HASHSERVE` into the builds (trusted: read-write server; PR: `auto` + upstream read-only), selected by the runner pool | open, needs a test with real bitbake |
| M14 | Input mirror for image rebuild inputs | low |
| M15 | Unverified claims to test: kas with a present pinned commit and no network; `own-mirrors` conversion; sstate prune without access times; `cosign verify --local-image` on a skopeo-made archive | open |
| M16 | Off-site second copy of releases for T2 and T3 | decide later |
| M17 | Release bundle for T3 (images, kernels, builder and runner OCI archives, sources, pins, SBOM, signatures, bundles, provenance, hashserv and prserv snapshot) | open |
| M18 | Caller workflow, `ci/build-matrix.yaml` and ruleset (`CHECK='ci / result' scripts/github-settings.sh`, required check, rebase merge only) for `meta-agl-demo`, `meta-agl-devel` and `agl-ucb`; `meta-agl` already has them. The ruleset only goes on together with the caller (a required check that never reports blocks every merge). Callers use the nightly schedule, not a push trigger | earmarked |
