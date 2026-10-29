---
name: agl-ci-mirror-and-cache
description: How the AGL CI cache and mirror stack works - CACHE_DIR layout and permissions, the read-only nginx mirror, pull-sync over a read-only rsync daemon, git mirrors, TLS/certbot, fetch and drill modes (outage drill T1/T2/T3), uninative, pruning rules, and the hash equivalence server wiring. Consult BEFORE editing kit/mirror/*, kit/prune-cache.sh, ci/scripts/{fetch,drill}.sh, kas mirror or hashserv fragments, or when a build needs the network it should not.
---

# Mirror and cache (agl-ci)

Long form: manual chapters 14 and 15. Verified unless marked.

## Layout
`CACHE_DIR` (default `/srv/agl-cache`, `root:root 0700`): `sstate/` and `dl/`, both owned by uid 1001 (the runner user inside the image). The sqlite hash equivalence db sits in `sstate/` in the trial setup; keep sstate and hashserv db together (delete or restore both). **`BB_HASHSERVE_DB_DIR` on NFS is fatal**: no NFS for the shared cache.
Trusted host: its `CACHE_DIR` **is** the mirror (single writer: trusted pool). Untrusted host: private cache, reads the mirror via `AGL_MIRROR_URL` (`PREMIRRORS` / `SSTATE_MIRRORS`, `kas/local/mirrors.yml` in agl-ucb).

## Pieces in `kit/mirror/`
- `run.sh` + `nginx.conf` + `locations.conf`: unprivileged nginx container, mounts `dl/` and `sstate/` (and `git/` when it exists) read-only, serves `/dl/`, `/sstate/` and `/git/` (bare layer mirrors for kas) only; `GET`/`HEAD` only; no listings; 404 for `*.lock *.tmp *.done hashserv.db* git2/` clones and dotfiles. Env `CACHE_DIR`, `PORT` (8080). Restart (`./kit/mirror/run.sh`) after changing it.
- TLS is optional: default plain HTTP (dev network only); production = separate nginx + HTTPS terminator including `locations.conf`; optional in-container TLS (`TLS_CERT`/`TLS_KEY`, port 8443); `certbot.sh` for Let's Encrypt via container.
- `rsyncd.sh` + `rsyncd.conf` + `pull-sync.sh`: a **read-only rsync daemon container** (read-only mounts, no credentials, `hosts allow`) lets another machine pull the cache. The config is assembled inside the container because `&include` did not apply `hosts allow`. No ssh key, no `rrsync`.
- `git-mirrors.sh` + `git-repos-from-kas.py`: bare git mirrors of every repo kas fetches (`AGL_GIT_MIRROR=1` makes a build use them). TODO: scheduled mirror-only check after the nightly fetch.
- `sync-selftest.sh`: self test of the sync.
- `kit/prune-cache.sh`: prunes **sstate only. `dl/` is never pruned** (user rule: sources must survive an upstream disappearing).

## Modes of the reusable workflow
- `mode: fetch` (+ `tier: dispatch`): `ci/scripts/fetch.sh` runs `bitbake -k --runall=fetch <target>` with network on and `BB_GENERATE_MIRROR_TARBALLS=1`, writing `git2_*.tar.gz` (a bare `git2/` clone cannot be served over HTTP). Fill reads from the real upstream, never from our mirror (`PREMIRRORS=""` once the mirror is wired). Trusted events only.
- `mode: drill` / `drill-mirror` (`drill.sh`): builds with upstream blocked (`BB_ALLOWED_NETWORKS`) to prove T1/T2/T3 survival: `fetchall` offline from `DL_DIR`, or `mirror` through `AGL_MIRROR_URL`. `drill-mirror` needs the repo variable `AGL_MIRROR_URL`; it is temporary for tests, delete after.
- **uninative:** the tarball is a hidden network fetch into `DL_DIR/uninative/<sha256>/`. `fetch.sh` counts `uninative/*/*.tar.xz` and fails with "no uninative tarball" when there is none, so a fill cannot leave an incomplete mirror. The first scheduled run of that check is still to come; without the tarball an offline build fails at the first recipe.
- Not covered by the fetch switch: npm, cargo, go, pip fetchers (drill B shows which recipes need more).

## Hash equivalence server
Off by default. Wiring: `kas/local/hashserv-rw.yml` (trusted, `AGL_HASHSERV_RW`) and `hashserv-upstream.yml` (untrusted, `AGL_HASHSERV_UPSTREAM`), from `HASHSERV_RW` / `HASHSERV_UPSTREAM` in `runner.env`. The RW server (port 9393) grants anonymous `@db-admin`: bind it to a private address only. Unreachable server = slower builds, not red. Run all servers from one pinned image (bitbake 2.18 in the wrynose branch of agl-ucb). The container deployment on the test builder is the next planned step.

## Rules
- Never commit the dev mirror's address; keep `AGL_MIRROR_URL` env-driven and overridable (see `agl-ci-trust-and-security`).
- A cold cache empties the mirror and the hashserv db; refill with `mode: fetch`, then a build or the next nightly.
- Check after the first fill: `ls $AGL_DL_DIR/git2_*.tar.gz | wc -l` against the number of `git2/` dirs (a source cloned before may lack its tarball; not verified).
