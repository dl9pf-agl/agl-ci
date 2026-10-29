# 15 Outage drill, mirrors and open items

*Read this if you work on mirrors, offline builds or outage drills, or look for what is still open.*

Status: the fetch drill (A) ran on real bitbake; the web server, pull sync, git mirrors, TLS options, pruning, hash server wiring and the uninative check are written and tested as described below. Not done: the full offline drill B, drill C, and a mirror fed from a second machine. The open-items table at the end is the single list of what is still missing.

Contents: Requirement; What a CI build depends on; The drill (offline, from the mirror alone); First drill results and uninative; Mirrors in the build path (fetch mode, mirror design, web server, transport, consumer settings M4, git mirrors M6, sync to a download server M3, trying it on one host); Folder growth and pruning; Open items.

## Requirement
Builds must survive an upstream outage at three levels:
- **T1** keep building on the existing builder (incremental builds, warm cache);
- **T2** clean rebuild on a new or rebuilt builder (disk loss, new host);
- **T3** rebuild or verify an old release years later.

## What a CI build depends on, and the answer for each
Marked V = verified in documentation or source; the rest is proven by the drill.

| # | Dependency | Answer |
|---|---|---|
| L1 | kas layer clones: 18 distinct repo URLs in agl-ucb (23 with the layers' own feature fragments) on git.yoctoproject.org, github.com, git.openembedded.org (V) | Own git mirrors and `KAS_PREMIRRORS` (V: "alternatives for repo URLs", regular expression plus replacement, forwarded by kas-container). `KAS_REPO_REF_DIR` (V: directories named `host.org.repo.git`, missing repos are cloned below it) is the alternative; whether kas still contacts the remote for a pinned commit that is already present is **not stated**, test it (drill C). |
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

### Drill from the mirror alone (tier T2)
 `drill.sh --mode mirror` (sources only, minutes) and `--mode mirror-build` (the
whole build, sstate from the mirror too) prove that a clean rebuild on a new builder works with upstream gone. They run with
an EMPTY private download and sstate directory (`build/drill-cache` in the workspace, so nothing of the shared cache can help),
`AGL_MIRROR_URL` required, and `BB_ALLOWED_NETWORKS` set to the host of the mirror (V, `fetch2`: any other host is an untrusted URL
and the fetch fails; the port is ignored). The network stays on because the mirror is reached over it. `BB_FETCH_PREMIRRORONLY`
looks like the obvious choice but is wrong here: tested, a `gitsm://` recipe (p11-kit) cannot fetch its submodules from the mirror
with it (bitbake disables the network for the submodule fetch, mirror included). A source that is not on the mirror fails with
"Fetcher failure", which the drill lists in `misses.txt` like the offline drill. From GitHub: the
reusable workflow takes `mode: drill-mirror`; the mirror comes from the repository variable `AGL_MIRROR_URL` (maintainers only;
deliberately not an input of the dispatch), and the callers must offer the value in their `workflow_dispatch` choice. The
variable belongs to the **calling** repo (a reusable workflow reads `vars` of its caller), so set it in every repo that runs the
drill: Settings > Secrets and variables > Actions > Variables, or `gh variable set AGL_MIRROR_URL -R <org>/<repo> --body <url>`.
It is the way to test a mirror that is not published yet. Once the production mirror exists its URL is meant to be committed
as the default in the distro configuration or a kas fragment (a public site for AGL; a member may keep a private one and
override it), and the variable is no longer needed. A GitHub run log is public in a public repo and shows the host name;
delete the run afterwards if the host is not meant to be known. Tested through GitHub on 2026-10-28 (trusted pool,
`agl-image-minimal` on qemux86-64, 4.5 minutes, 0 failures); that run is no longer in the run list of `meta-agl`, so this result cannot be
re-checked there (repeat the drill to confirm it). The offline `fetchall` drill through GitHub is still visible: run 40556908726 of
2026-10-27, four images, 3.7 to 3.9 minutes each, 0 fetch failures. By hand
or on a desk: `AGL_MIRROR_URL=http://host:8080 ci/scripts/drill.sh --machine M --features F --target T --mode mirror`.

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

The fill (`fetch.sh`) now fails when `DL_DIR/uninative/<sha256>/*.tar.xz` is missing after the run, so a nightly cannot stay green
with an incomplete mirror. Keep in mind for the release bundle (M17): the tarball belongs to the pin (`UNINATIVE_VERSION` of
oe-core), so a bundle that must rebuild an old release years later has to carry its `dl/uninative/` folder; `prune-cache.sh`
never prunes `dl/`. A new `UNINATIVE_VERSION` (an oe-core pin bump) is fetched by the next fill and invalidates the
native sstate once (a slow nightly, nothing to do).

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

#### Web server (M1)
An nginx container, `kit/mirror/run.sh` with `kit/mirror/nginx.conf`, image pinned by digest. It
mounts `$CACHE_DIR/dl` and `$CACHE_DIR/sstate` read-only (enforced by the kernel) and serves them as `/dl/` and
`/sstate/` and, when `$CACHE_DIR/git` exists, `/git/` (bare layer mirrors), nothing else; it runs unprivileged with a read-only root, no capabilities and `no-new-privileges`. Served:
tarballs, `git2_*.tar.gz`, `uninative/<sha256>/...`, sstate objects and their `.siginfo`, range requests (`wget
--continue`) and `HEAD`. Not served (404): `*.lock`, `*.tmp`, `*.done`, `hashserv.db*`, the `git2/` clone directories
and dotfiles; directory listings are off (403) and every method except `GET` and `HEAD` returns 405. Tested with a fake
cache tree on 2026-10-26. Start: `kit/mirror/run.sh` (env `CACHE_DIR`, `PORT`, default 8080).

#### Transport: plain HTTP, HTTPS terminator, own TLS
Three modes:

(1) **Plain HTTP, the default** and what the development and test setup uses: no TLS variable, nothing changes. Fine for the
checksummed downloads, the weak point for sstate (no integrity check) and for the unpinned `branch:` layers, so only on a
network you control.
(2) **Production: a separate nginx with an HTTPS terminator in front** (decided 2026-10-28; set up outside this kit). The rule
set of the mirror is one file, `kit/mirror/locations.conf`, which that nginx can include so that it serves exactly what this
container serves.
(3) **Optional: this container terminates TLS.** `TLS_CERT=/path/fullchain.pem TLS_KEY=/path/privkey.pem kit/mirror/run.sh` also
serves HTTPS on port 8443 (`TLS_PORT`; TLSv1.2 and 1.3 only) with the same rules. With a Let's Encrypt certificate use
`kit/mirror/certbot.sh`: `TLS_NAME=mirror.example.org LE_EMAIL=ops@example.org kit/mirror/certbot.sh issue` once (try
`LE_STAGING=1` first), then `TLS_NAME=mirror.example.org kit/mirror/certbot.sh renew` daily from cron. It runs the official
certbot container (pinned by digest; read-only root file system, no capabilities except binding port 80, sees only
`/etc/agl-runner/letsencrypt`), HTTP-01 on port 80, which must be reachable from the internet and resolve to this host; `renew`
asks Let's Encrypt only within 30 days of expiry and restarts the mirror only when the certificate changed. The nginx container
user (uid 101) cannot read a key that only root may read, so `run.sh` keeps a copy readable by that uid only in the root-only
folder `/etc/agl-runner/mirror-tls` (`TLS_COPY_DIR`); `certbot.sh` refreshes it through `run.sh`. A consumer then uses
`AGL_MIRROR_URL=https://mirror.example.org:8443`.
Tested: with a self-signed certificate HTTPS and HTTP return the same results, TLS 1.1 is refused, a key readable only by its
owner fails without the copy; `certbot.sh` argument checks, the certbot command line, the restart with the new certificate, no
restart when unchanged and a restart when changed, with a shim in place of the certbot container and a real nginx; the real
certbot image runs with the container flags on an empty state directory. Not tested: an actual issuance or renewal at Let's
Encrypt (needs a public name and port 80), DNS-01, the whole chain in production.
Any other web server works if it follows the same rules (Apache:
`Alias` plus `Require method GET HEAD` and `FilesMatch` denies). The sstate directory has one folder per tune
(`sstate/corei7-64/...`); the consumer URL in M4 must contain `${DEFAULTTUNE}`. Hash equivalence: read-write port only
for the trusted pool, read-only port public (chapter 14).

#### Consumer settings (M4)
 `kas/local/mirrors.yml` in agl-ucb is included by the engine when `AGL_MIRROR_URL` is set (an
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

#### Git mirrors for the layers (M6)
 kas clones the layers (oe-core, meta-openembedded, the AGL layers: 18 repositories in
agl-ucb, 23 with the layer feature fragments) from github.com, git.yoctoproject.org and git.openembedded.org, so a clean checkout needs
them. `kit/mirror/git-repos-from-kas.py <dirs>` lists the URLs from the kas files; `kit/mirror/git-mirrors.sh` keeps bare mirrors of
them in `CACHE_DIR/git/<host>/<path>` (first run clones, later runs update, then `git update-server-info`); nginx serves them as
`/git/` over plain dumb HTTP (`run.sh` mounts the folder when it exists). Run it as root on the trusted host, from cron or after the
nightly: `kit/mirror/git-repos-from-kas.py <agl-ucb tree> | CACHE_DIR=/srv/agl-cache kit/mirror/git-mirrors.sh`. A consumer sets
`AGL_GIT_MIRROR=1` with `AGL_MIRROR_URL`; the engine then exports `KAS_PREMIRRORS="^https?://([^/]+)/ $AGL_MIRROR_URL/git/\1/"` (kas
rewrites the clone URL; the kas-container script forwards the variable). It is opt-in because kas has **no fallback**: tested with
kas 5.5 in the builder image, a mirror that lacks the repository fails the checkout ("repository ... not found") instead of using the
original URL, so enable it only where the mirror is complete, e.g. the T2 rebuild and the untrusted hosts. Also tested with real kas: a
checkout whose pinned commit is already present does **not** contact any remote (second run with the network off), so a warm
workspace survives an outage by itself. Integrity: the layers are pinned by commit, so a damaged mirror fails the checkout instead of
changing the build; only a `branch:` without `commit:` trusts the mirror to be current. The repo under test is the exception: the engine
puts a line first that maps `AGL_PIN_URL` (for a fork pull request the fork) to itself, so it is cloned from where it is, while all
other layers use the mirror (tested with real kas: without that line the checkout fails with "repository ... not found"). Not
done: the first clone in `checkout.sh` of the workflow uses the original URLs (the mirror drill covers the sources, not yet this clone).

#### Order of reports and sync rules
**Order of reports, checked in oe-core:** `sstate.bbclass` runs `sstate_report_unihash` before
`sstate_create_and_sign_package` in the same postfunc. The hashserv learns a result seconds before the object exists.
A consumer that gets a unihash without its object misses and rebuilds that task; without hashserv it would miss as well,
so a hashserv that is ahead of the mirror is never worse than no hashserv.

**Rules that keep it correct when the web server runs on another host and the mirror is a copy:**
1. Only trusted builds report to the hashserv, and every trusted host's cache is synced.
2. Sync after every trusted job, not only nightly, with retries. Objects are content-addressed, so a re-sync is safe.
3. Prune the mirror by age only; an old equivalence that points at a pruned object is a benign miss.

Sync model for a separate web host: the web host pulls (`rsync -a --ignore-existing --delay-updates`, read-only rsync
daemon in a container (`kit/mirror/rsyncd.sh`), filters as above, every few minutes and after the nightly) from each trusted host, so no
build host holds a credential for the web host, and several hosts merge into one tree without conflicts. It writes a
timestamp file after each pull, so a stalled sync is visible. `AGL_MIRROR_URL` does not change.

#### How the download server gets the cache (M3)
 No account, key or password on either side, and the download server never gets
a login on a build host. Each trusted build host runs a read-only rsync daemon in a container (`kit/mirror/rsyncd.sh`); the
download server pulls with `kit/mirror/pull-sync.sh`.
- Build host: `RSYNCD_BIND=<private address> RSYNCD_ALLOW=<address of the download server> kit/mirror/rsyncd.sh`. Both are required.
  The port (873, `RSYNCD_PORT`) is published on that one address only, which must be on a private network (physical or VPN);
  `0.0.0.0` is refused. The container uses the signed builder image of the checkout (it has rsync and is on the host anyway),
  a read-only root file system, no capabilities except the three the daemon needs to chroot and drop to uid 1001, and
  read-only mounts of `dl/`, `sstate/` and `git/`. The module is `read only`, refuses `--delete`, and offers neither
  `*.lock`, `*.tmp`, `*.done`, `hashserv.db*`, dotfiles nor `dl/git2/`. Access control is the network plus `hosts allow`; the
  transfer is not encrypted, which is why the network must be private. Stop it with `docker rm -f agl-rsyncd`.
- Download server: `SOURCES="rsync://10.0.0.5/agl/ rsync://10.0.0.6/agl/" MIRROR_ROOT=/srv/mirror kit/mirror/pull-sync.sh [-n]`,
  from cron, as any user that may write `MIRROR_ROOT`. Per source and per area (`dl`, `sstate`, `git`; `git` only if offered) it
  runs rsync with `--ignore-existing --delay-updates`, so an existing file is never replaced (the objects are content-addressed,
  and a damaged copy on a build host cannot overwrite a good one), and writes `MIRROR_ROOT/LAST_SYNC` after a successful run
  (alert when it gets old). `-n` is a dry run and creates nothing.
Tested with rsync 3.5 and the pinned builder image on a fake root-only cache tree: the daemon lists only `dl`, `sstate` and
`git`; excluded names are not retrievable even when asked for by name; writes and `--delete` are refused; the container runs with
all capabilities dropped but three, and the worker has dropped to uid 1001 (a root-only 0600 file is refused); `hosts allow`
refuses a client that is not listed and accepts a list or a CIDR; the pull does not replace an existing file, copies new ones,
skips an area that is not offered and writes `LAST_SYNC`; bad addresses and URLs are refused. Found by that test: an `&include`
of the allowed address did not take effect in rsync 3.5, so `rsyncd.sh` assembles the config in the container instead. Not
tested: two hosts and a real private network or VPN, the volume of a real sstate tree, and the container with published ports
(the test used host networking).
Decision recorded: the first draft pulled over ssh with an `rrsync` key of root; it was dropped, because a key to a root account
on a build host is not acceptable even when restricted.

#### Trying it on one host
 `kit/mirror/sync-selftest.sh` runs the whole chain on the trusted host before the download server is a
separate machine: daemon (container `agl-rsyncd-test`, published on 127.0.0.1) -> pull as the normal user with the client of the
builder image into a scratch tree (`~/agl-sync-selftest`) -> an nginx container on that tree (`agl-mirror-test`, port 18080) ->
checks (LAST_SYNC, nothing excluded in the tree, a second pull changes nothing, a write is refused, a file through nginx is
byte-equal, listing is 403). It touches neither the real `agl-mirror` nor a real `agl-rsyncd` (`RSYNCD_NAME` and `MIRROR_NAME`
exist for that), and by default pulls only files up to 200 KB (`RSYNC_EXTRA=--max-size=200K`), so a 30 GB cache costs a few
hundred MB; `RSYNC_EXTRA=` pulls everything. Run it as the normal user; it asks sudo only where `rsyncd.sh` and `run.sh` do, to
read the root-only cache. `kit/mirror/sync-selftest.sh cleanup` removes the containers and the scratch tree. On one host, docker's
port mapping makes the daemon see the address of the bridge gateway, not 127.0.0.1, so the script allows that address; the log
lines printed at the end show what the daemon saw. A separate download server comes from its own address, which is what
`RSYNCD_ALLOW` is for. Tested locally with host networking (`SELFTEST_NETWORK=host`); the default bridge path (published
port, gateway address) is not tested here and is what the first run on the trusted host shows.

#### Build order
Steps: 1 this design; 2 kit pools (`POOL`, `SLOTS`, `MIRROR_URL`, done in the kit); 3 routing in `layer-ci.yml` (done: fork pull
requests to `agl-fork`, everything else to `agl-pr`); 4 nginx container on this host (`kit/mirror`, done; TLS optional); 5 consumer settings (M4); 6 hashserv wiring
(M13b); 7 drill from the mirror alone (empty `DL_DIR` and sstate, `BB_ALLOWED_NETWORKS`; done, `drill.sh --mode mirror`); 8 pull sync to a separate
web host, pruning and monitoring (M11), git mirrors (M6), the other layer repos (M18), off-site copy (M16).

## Folder growth
`/srv/mirror/{sstate,dl}`, `/srv/artifacts` and `CACHE_DIR` each get their own filesystem or volume, so a full mirror
cannot stop Docker. One writer per area. sstate: prune with `sstate-cache-management` or by age (check whether the
filesystem keeps access times first). dl: never pruned (decision 2026-10-28): the downloads are the premirror for rebuilding old
builds during an outage, and they grow slowly; what grows is sstate and the binary releases. Artifacts follow the retention of the artifact chapter
(PR: while open and 14 days after close or merge, nightly 8 days, release forever). Alert at 80 and 90 percent; the
size report belongs in the job summary.

`kit/prune-cache.sh` is the tool for sstate (of the cache, and of a mirror tree): `sudo kit/prune-cache.sh` is a dry run that says
how many files and GiB have not been used for 60 days; `--apply` deletes them. It never touches `hashserv.db*` or `LAST_SYNC`,
never a file changed in the last day, never follows a symlink, and removes empty directories. **It does not prune `dl/` and has no
option for it.** It uses access times and refuses to run on a `noatime` mount (`--mtime` is the explicit alternative; `relatime`,
the default, refreshes an access time at most once a day, which is enough). Pruning by age is safe for the hash equivalence
database: an old equivalence that points at a deleted object costs one rebuild. Binary releases are not pruned by it; their
retention is the artifact retention above. Tested on a fake tree (old, recent, read-only-recently, symlinked and protected
files, `dl/` untouched, dry run, apply, `--mtime`); not run on a real cache, so start with the dry run and look at the numbers.

## Open items (keep current)
| ID | Item | Status |
|---|---|---|
| M1 | Web server: /dl, /sstate and /git done (nginx container, `kit/mirror`, read-only; start it on the host: user); TLS optional (plain HTTP by default; production plans a separate HTTPS terminator; `certbot.sh` for Let's Encrypt, issuance untested); /artifacts and the write path open | partly done |
| M2 | `publish-artifacts.sh` copying a whitelist plus manifest to `ARTIFACT_DEST=dir:`; staging, published, rejected trees; routing by pool | open |
| M3 | Mirror publisher step in nightly and release (rsync sstate and dl, single writer) | read-only rsync daemon container (`kit/mirror/rsyncd.sh`) and pull script (`kit/mirror/pull-sync.sh`) written and tested locally; only needed once the download server is another machine (user: private network, start the daemon, cron) |
| M4 | `kas/local/mirrors.yml` in agl-ucb: `SSTATE_MIRRORS`, `PREMIRRORS` from `AGL_MIRROR_URL`, AGL's `MIRRORS` stays as last line | fragment and engine wiring done (agl-ucb first, then agl-ci); proof by the drill from the mirror alone (step 7) pending |
| M5 | `BB_GENERATE_MIRROR_TARBALLS=1` and a fetch of all matrix targets in nightly and release | `fetch.sh`, `mode: fetch` and the scheduled `fetch` job in `meta-agl` done (2026-10-26); the same job for the other layer repos with M18; the fill job reads no mirror (`fetch.sh` unsets `AGL_MIRROR_URL`); git tarballs for sources that were already cloned to be checked (compare `git2_*.tar.gz` with `git2/`) |
| M6 | Git mirrors for the kas repos (18 in agl-ucb, 23 with the layers' own fragments) and `KAS_PREMIRRORS` | scripts and engine switch (`AGL_GIT_MIRROR=1`) done and tested with real kas and a local dumb-HTTP mirror; to run on the host: user (cron); not yet used by `checkout.sh`; TODO later: after the routine nightly fetch, a scheduled check with `AGL_GIT_MIRROR=1` (layers cloned and sources fetched through the mirror only) so that the upstream-outage case is exercised regularly |
| M7 | Outage drill | fetch drill A done on real bitbake (2026-10-26): 0 misses for all four meta-agl images after a fetch. Drill B (full offline build) and drill C (offline layers) open |
| M8 | No per-job builder pull (`KAS_EXEC=kas` in the runner image or pull-through registry) | open |
| M9 | Registry experiment zot and registry:3, `mirror-image.sh`, optional mirror job, OCI archive per release | open |
| M10 | Break-glass procedure, YubiKey release signing, Sigstore offline bundles | open |
| M11 | Pruning, quotas, monitoring, backups (hashserv DB, release artifacts) | sstate pruning script `kit/prune-cache.sh` written and tested on a fake tree (dry run by default; `dl/` is never pruned); quotas, alerts, backups, release retention open |
| M12 | Production cache split: trusted hosts (`agl-pr`) and untrusted hosts (`agl-fork`, private cache, mirror over HTTPS) | kit part and routing in `layer-ci.yml` done (`POOL`, chapter 05; chapter 13); the untrusted host is provisioned (runner online, label `agl-fork`); fork pull requests still to be tested on it (needs a second GitHub account) |
| M13a | Deploy the wrynose hashserv/prserv container (chapter 14, "Deployment on the build host") | image done and tested for liveness; deployment on the host: user |
| M13b | Wire `BB_HASHSERVE` into the builds (trusted: read-write server; PR: `auto` + upstream read-only), selected by the runner pool | wiring done and tested against a local hash server (chapter 14); switched on by `HASHSERV_RW` / `HASHSERV_UPSTREAM` once the container (M13a) runs on the host |
| M14 | Input mirror for image rebuild inputs | low |
| M15 | Unverified claims to test: ~~kas with a present pinned commit and no network~~ (verified 2026-10-27: no remote contact); `own-mirrors` conversion; sstate prune without access times; `cosign verify --local-image` on a skopeo-made archive | open |
| M16 | Off-site second copy of releases for T2 and T3 | decide later |
| M17 | Release bundle for T3 (images, kernels, builder and runner OCI archives, sources, pins, SBOM, signatures, bundles, provenance, hashserv and prserv snapshot) | open |
| M18 | Caller workflow, `ci/build-matrix.yaml` and ruleset (`CHECK='ci / result' scripts/github-settings.sh`, required check, rebase merge only) for `meta-agl-demo`, `meta-agl-devel` and `agl-ucb`; `meta-agl` already has them. The ruleset only goes on together with the caller (a required check that never reports blocks every merge). Callers of demo and devel have no schedule (the nightly of `meta-agl` builds them through `needs`) and no push trigger | matrices and callers pushed as meta-agl-demo#1 and meta-agl-devel#1 (shared names, chapter 13); their first cold builds are running (2026-10-29); no ruleset yet for agl-ucb, demo and devel |
| M19 | Enable `yocto-check-layer` by default for the layers of `meta-agl-demo` and `meta-agl-devel` (`check_layers.default` in their matrices) | prepared but NOT active: the layers are listed, `default: []`. TODO: run `make validate CHECK_LAYERS="<layers>"` per layer, fix or waive what fails, then list the passing layers in `default`; one layer at a time is fine |
| M20 | Written-out pin for releases: store `resolved-pins.yml` (`ci/scripts/resolved-pins.sh`) with every nightly and release artifact and use it as the pins file to rebuild; today only the job summary of the `matrix` job has it | script and job summary done; storing it in the release bundle (M17) open |
| M21 | Restrict the trusted runners (`agl-pr`) to the reusable workflows of agl-ci: org runner group `agl-ci` (id 3) is workflow-restricted and empty, the runners sit in `Default`; make `kit/deploy.sh` take the runner group per pool (it hardcodes 1) | open (last item). The GitHub docs say custom runner groups need the Team plan; the org is on the free plan, yet group `agl-ci` (id 3) exists, so enforcement is unknown. Alternative that needs no plan: a job-started hook (`ACTIONS_RUNNER_HOOK_JOB_STARTED`) in the runner image that refuses a pull request from a fork on a trusted host. First test how GitHub matches a SHA-pinned reusable workflow against an allowed entry, with a same-repo PR and a fork PR |
