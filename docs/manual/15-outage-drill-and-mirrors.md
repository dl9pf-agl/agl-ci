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
- After one fetch of all four images (`mode: fetch`, `tier: dispatch`, below) the drill reports **0 misses for all four**:
  recipe sources and the uninative tarball come from `DL_DIR` with the network off. The fetch left 109 `git2_*.tar.gz`
  mirror tarballs in `DL_DIR`. What the drill does not prove: fetches inside `do_compile` (drill B, build mode) and
  offline layer checkout (drill C).

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
a web server. Final: a separate web machine; the transport for writing (staging directory on NFS, or the server pulls) is
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

The nightly of `meta-agl` runs it as the scheduled job `fetch` next to the build (the other layer repos get the same job
with their caller, M18). When the source mirror is wired in (M4), the fill job must set `PREMIRRORS = ""`, like the
Yocto autobuilder fragment `fragments/yocto-autobuilder/autobuilder.conf` (it sets `BB_GENERATE_MIRROR_TARBALLS = '1'` and
`PREMIRRORS = ''`): the fill reads from the real upstream, never from our own mirror, so that a stale mirror cannot hide
an upstream change. Other fetchers (npm, cargo, go, pip) are not covered by this switch; drill B shows which recipes need
more.

### Mirror design (decided 2026-10-26)
**The cache of the trusted pool is the mirror.** Only trusted hosts (`agl-pr`: same-repo pull requests, nightly, push,
release) write `/srv/agl-cache` (chapter 05, "Pools"); a web server serves it read-only, so there is no copy step and no
publisher script on one host. Fork pull requests run on separate untrusted hosts (`agl-fork`) with a private cache and
read the mirror over HTTPS through the same `PREMIRRORS` / `SSTATE_MIRRORS` settings (`AGL_MIRROR_URL`); outside users and
a clean rebuild (T2) use the same URL. One mechanism for every consumer. Downloads are protected by the `SRC_URI`
checksums; sstate objects have no integrity check, which is why only the trusted pool may write what is served.

Web server (step 4): an nginx container, `kit/mirror/run.sh` with `kit/mirror/nginx.conf`, image pinned by digest. It
mounts `$CACHE_DIR/dl` and `$CACHE_DIR/sstate` read-only (enforced by the kernel) and serves them as `/dl/` and
`/sstate/`, nothing else; it runs unprivileged with a read-only root, no capabilities and `no-new-privileges`. Served:
tarballs, `git2_*.tar.gz`, `uninative/<sha256>/...`, sstate objects and their `.siginfo`, range requests (`wget
--continue`) and `HEAD`. Not served (404): `*.lock`, `*.tmp`, `*.done`, `hashserv.db*`, the `git2/` clone directories
and dotfiles; directory listings are off (403) and every method except `GET` and `HEAD` returns 405. Tested with a fake
cache tree on 2026-10-26. Start: `kit/mirror/run.sh` (env `CACHE_DIR`, `PORT`, default 8080). TLS is not in the container
yet: terminate it in front, or add a `listen 8443 ssl` server block with a mounted certificate; until then a consumer
reaches the mirror over plain HTTP, which is fine for the checksummed downloads and the weak point for sstate (no
integrity check), so use it on a network you control. Any other web server works if it follows the same rules (Apache:
`Alias` plus `Require method GET HEAD` and `FilesMatch` denies). The sstate directory has one folder per tune
(`sstate/corei7-64/...`); the consumer URL in M4 must contain `${DEFAULTTUNE}`. Hash equivalence: read-write port only
for the trusted pool, read-only port public (chapter 14).

**Consumer settings (M4).** `kas/local/mirrors.yml` in agl-ucb is included by the engine when `AGL_MIRROR_URL` is set (an
http(s) URL without a trailing slash; the engine strips one and refuses other schemes). It puts `$AGL_MIRROR_URL/dl/` in
front of the upstream URL of every recipe (`PREMIRRORS` for git, gitsm, ftp, http, https; the uninative tarball is found
through the http line) and `$AGL_MIRROR_URL/sstate/${DEFAULTTUNE}/PATH` in front of the sstate lookup (`SSTATE_MIRRORS`),
captured with `:=` like `AGL_SSTATE_DIR` (tested with bitbake 2.18: both variables expand to the mirror). The variable is
forwarded into the container; no mount is needed. Who sets it: the kit on an untrusted host (`MIRROR_URL`, chapter 05),
a developer by hand, a clean rebuild (T2). A trusted host leaves it empty and uses its own cache. `fetch.sh` (the fill) and
`drill.sh` (offline) unset it on purpose: the fill reads the real upstreams, and a network-off drill can only produce
misses through a URL. AGL's own `MIRRORS` in `agl.conf` stay as the last line. AGL's public mirror
`download.automotivelinux.org/AGL/mirror/` (and `sstate-mirror/master/<tune>/`) answers today; it is not used as a primary
and whether its sstate objects match our hashes is not checked.

**Order of reports, checked in oe-core:** `sstate.bbclass` runs `sstate_report_unihash` before
`sstate_create_and_sign_package` in the same postfunc. The hashserv learns a result seconds before the object exists.
A consumer that gets a unihash without its object misses and rebuilds that task; without hashserv it would miss as well,
so a hashserv that is ahead of the mirror is never worse than no hashserv.

**Rules that keep it correct when the web server runs on another host and the mirror is a copy:**
1. Only trusted builds report to the hashserv, and every trusted host's cache is synced.
2. Sync after every trusted job, not only nightly, with retries. Objects are content-addressed, so a re-sync is safe.
3. Prune the mirror by age only; an old equivalence that points at a pruned object is a benign miss.

Sync model for a separate web host: the web host pulls (`rsync -a --ignore-existing --delay-updates`, read-only rsync
module or forced-command key, filters as above, every few minutes and after the nightly) from each trusted host, so no
build host holds a credential for the web host, and several hosts merge into one tree without conflicts. It writes a
timestamp file after each pull, so a stalled sync is visible. `AGL_MIRROR_URL` does not change.

Steps: 1 this design; 2 kit pools (`POOL`, `SLOTS`, `MIRROR_URL`, done in the kit); 3 routing in `layer-ci.yml` (done: fork pull
requests to `agl-fork`, everything else to `agl-pr`); 4 nginx container on this host (`kit/mirror`, done; TLS open); 5 consumer settings (M4); 6 hashserv wiring
(M13b); 7 drill from the mirror alone (empty `DL_DIR` and sstate, `BB_FETCH_PREMIRRORONLY`); 8 pull sync to a separate
web host, pruning and monitoring (M11), git mirrors (M6), the other layer repos (M18), off-site copy (M16).

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
| M1 | Web server: /dl and /sstate done (nginx container, `kit/mirror`, read-only; start it on the host: user); TLS, /artifacts and the write path open | partly done |
| M2 | `publish-artifacts.sh` copying a whitelist plus manifest to `ARTIFACT_DEST=dir:`; staging, published, rejected trees; routing by pool | open |
| M3 | Mirror publisher step in nightly and release (rsync sstate and dl, single writer) | open |
| M4 | `kas/local/mirrors.yml` in agl-ucb: `SSTATE_MIRRORS`, `PREMIRRORS` from `AGL_MIRROR_URL`, AGL's `MIRRORS` stays as last line | fragment and engine wiring done (agl-ucb first, then agl-ci); proof by the drill from the mirror alone (step 7) pending |
| M5 | `BB_GENERATE_MIRROR_TARBALLS=1` and a fetch of all matrix targets in nightly and release | `fetch.sh`, `mode: fetch` and the scheduled `fetch` job in `meta-agl` done (2026-10-26); the same job for the other layer repos with M18; the fill job reads no mirror (`fetch.sh` unsets `AGL_MIRROR_URL`); git tarballs for sources that were already cloned to be checked (compare `git2_*.tar.gz` with `git2/`) |
| M6 | Git mirrors for the 18 kas repos and `KAS_PREMIRRORS` | open |
| M7 | Outage drill | fetch drill A done on real bitbake (2026-10-26): 0 misses for all four meta-agl images after a fetch. Drill B (full offline build) and drill C (offline layers) open |
| M8 | No per-job builder pull (`KAS_EXEC=kas` in the runner image or pull-through registry) | open |
| M9 | Registry experiment zot and registry:3, `mirror-image.sh`, optional mirror job, OCI archive per release | open |
| M10 | Break-glass procedure, YubiKey release signing, Sigstore offline bundles | open |
| M11 | Pruning, quotas, monitoring, backups (hashserv DB, release artifacts) | open |
| M12 | Production cache split: trusted hosts (`agl-pr`) and untrusted hosts (`agl-fork`, private cache, mirror over HTTPS) | kit part and routing in `layer-ci.yml` done (`POOL`, chapter 05; chapter 13); an untrusted host to be provisioned and fork pull requests to be tested on it (user, then me) |
| M13a | Deploy the wrynose hashserv/prserv container (chapter 14, "Deployment on the build host") | image done and tested for liveness; deployment on the host: user |
| M13b | Wire `BB_HASHSERVE` into the builds (trusted: read-write server; PR: `auto` + upstream read-only), selected by the runner pool | open, needs a test with real bitbake |
| M14 | Input mirror for image rebuild inputs | low |
| M15 | Unverified claims to test: kas with a present pinned commit and no network; `own-mirrors` conversion; sstate prune without access times; `cosign verify --local-image` on a skopeo-made archive | open |
| M16 | Off-site second copy of releases for T2 and T3 | decide later |
| M17 | Release bundle for T3 (images, kernels, builder and runner OCI archives, sources, pins, SBOM, signatures, bundles, provenance, hashserv and prserv snapshot) | open |
| M18 | Caller workflow, `ci/build-matrix.yaml` and ruleset (`CHECK='ci / result' scripts/github-settings.sh`, required check, rebase merge only) for `meta-agl-demo`, `meta-agl-devel` and `agl-ucb`; `meta-agl` already has them. The ruleset only goes on together with the caller (a required check that never reports blocks every merge). Callers use the nightly schedule, not a push trigger | earmarked |
