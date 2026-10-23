# 14 Hash equivalence server and PR server

Status: **decided 2026-10-23**, not yet deployed. The cache trial (chapter 05, "Shared cache") works without either
server. The container image for both servers is the `wrynose` branch of `dl9pf/docker-yp-prserv` (bitbake 2.18).

## Decision
- **Hash equivalence server (hashserv): used everywhere**, as a read-write and a read-only instance.
- **PR server (prserv): only on release runners, and only when CI builds a binary package feed.** Not used by PR,
  push or nightly validation builds.

| Service | Role | Port (wrynose container) | Who may use it |
|---|---|---|---|
| hashserv read-write | records equivalences | 9393 | trusted builds only (release, nightly, push to the default branch) |
| hashserv read-only | answers lookups | 9494 | every build, including PR builds |
| prserv read-write | hands out package revisions | 9191 | release runners that publish a feed |
| prserv read-only | answers lookups | 9292 | only if a consumer needs to resolve existing revisions |

## What each server does
**Hash equivalence.** Every task has a task hash, derived from its inputs. When a task finishes, the client reports
the hash of its *output* to the server. If another task hash produced the same output, the server gives both the same
*unihash*, and downstream task hashes are computed from unihashes. A change that does not alter the output (a
comment, a reformatting) therefore leaves all downstream hashes unchanged and the build reuses their sstate objects.
Sstate objects are stored under the unihash (`sstate.bbclass`: `SSTATE_PKGNAME` uses `BB_UNIHASH`), so the sstate cache
and the equivalence database have to be consistent. It only affects build time, never the content of an image.

**PR service.** It assigns an increasing revision to a package whenever its content changes, so `r0` becomes `r0.1`,
`r0.2`, and a package manager sees an upgrade path. Without it, builds are "self consistent" (Yocto manual): images are
correct, but there is no guarantee of upgrade order across builds. The key is (version, package architecture,
checksum); the checksum is the unihash of `do_package` (`package.bbclass` takes `taskdepdata[dep][6]`, which is the
`unihash` field of bitbake's `TaskData`), so PR numbers depend on hash equivalence being consistent.

## When the PR service is needed
Needed: CI publishes an rpm/opkg/deb feed and devices update packages from it, or several builders feed one feed (they
must share one PR service). Not needed: validation, image builds, boot tests, and whole-image updates (OSTree, RAUC,
SWUpdate). AGL's `agl-package-management.inc` only enables the feature on demand.

If a release job does publish a feed:
- one read-write instance, reachable only from the release runner;
- keep its database (the revision history is part of what makes the feed upgradeable) and back it up;
- share it only together with the sstate cache: the Yocto manual warns that a shared PR service without shared sstate
  gives "diverging" hashes and many unnecessary package upgrades;
- an unreachable PR service fails the build (`bb.fatal("Can NOT get PRAUTO from remote PR service")`), so do not set
  `PRSERV_HOST` in jobs that do not need it.

## Why PR builds must not write to the hashserv
`handle_report` in `hashserv/server.py` stores the unihash the *client* sends when no equivalent output is known, and
later builds that compute the same task hash receive it. Sstate objects are looked up by that unihash. A build that
may write both the hashserv and the sstate cache can therefore bind a task hash to an object of its choosing, which a
release build would then use. PR builds (including approved fork PRs) read only.

PR builds use a local server that reads from the read-only one:
```
BB_HASHSERVE = "auto"
BB_HASHSERVE_UPSTREAM = "<host>:9494"
BB_SIGNATURE_HANDLER = "OEEquivHash"
```
Their own reports go to a database private to the run; known outputs still map to the shared unihashes
(`report_readonly` returns an existing unihash when the output hash is known). This is the pattern of AGL's
`agl-prhash-public` template. Release and nightly builds use `BB_HASHSERVE = "<host>:9393"`.

## Operating rules
- The read-write hashserv grants anonymous clients `@read @report @db-admin` by default (`DEFAULT_ANON_PERMS`), which
  includes deleting entries and garbage collection. Bind port 9393 to the release runner's network only; do not
  publish it. The read-only instance (`-r`) has no write or admin handlers.
- A missing or unreachable hashserv is not fatal: bitbake warns ("Error contacting Hash Equivalence Server") and uses
  the task hash as unihash, so builds get slower, not red. An unreachable `BB_HASHSERVE_UPSTREAM` with `auto` is also
  a warning, and the upstream is dropped.
- `BB_HASHSERVE_DB_DIR` on NFS is fatal. The local `auto` server opens its sqlite file with `sync=False`; two bitbake
  servers on one file work on one host but are not the supported way to share. The trial still does this (the database
  sits in the shared sstate directory via `kas/local/sstate-shared.yml`); the supported way is the network server.
- Keep the sstate cache and the hashserv database together: delete or restore both. A mapping to an unihash with no
  sstate object only causes a rebuild of that task (inference from `get_unihashes` and the sstate lookup, not tested).
- Run all servers from one pinned image. The wrynose image uses bitbake 2.18, the branch that `agl-ucb` pins.

## Deployment on the build host (test phase)
The container comes from the `wrynose` (= `master`) branch of `dl9pf/docker-yp-prserv`, Debian 13 slim, bitbake 2.18.
```
git clone https://github.com/dl9pf/docker-yp-prserv && cd docker-yp-prserv      # branch master
RW_BIND=<private address> RO_BIND=<build network address> ./build-and-run.sh
docker ps --filter ancestor=prhashserv:production-wrynose-$(date +%F)
ss -ltn | grep -E ':(9191|9292|9393|9494) '
```
- Data lives in the named volume `prhashserv-wrynose` (hashserv.db, prserv.db, logs). Back it up: stop the container
  (`docker stop`, a clean stop takes about a second), then `docker run --rm --network none -v
  prhashserv-wrynose:/v -v $PWD:/b debian:trixie-slim tar -C /v -czf /b/prhash-$(date +%F).tgz .`.
- `RW_BIND` / `RO_BIND` set the address on which the read-write ports (9191, 9393) and the read-only ports (9292, 9494)
  are published. On one test host the jobs reach the container through the host's own address (the per-job Docker
  networks are created afresh, so the bridge address is not stable); there is then no isolation between PR and release
  jobs, as with the cache trial. Docker publishes around ufw and firewalld: use the bind addresses or the `DOCKER-USER`
  chain.
- Check from a job container (no tools needed): `bash -c 'exec 3<>/dev/tcp/<host>/9494 && echo open'`. A real check
  with the client library needs bitbake (`external/bitbake` in a CI tree): `hashserv.create_client("<host>:9494").ping()`
  returns `{'alive': True}`.
- Updating: run `./build-and-run.sh` again. It builds, stops and removes the container of the previous run and starts a
  new one on the same volume. Old setups started with an anonymous volume are migrated by the same script (asks once).
- Wiring into the builds is **not done yet** (open item M13b, chapter 15): the trial keeps the local `auto` server with
  its database in the shared sstate directory. Planned: an env-driven fragment in agl-ucb (`BB_HASHSERVE` for trusted
  builds, `auto` + `BB_HASHSERVE_UPSTREAM` for PR builds) selected by the runner pool. It has to be tested with real
  bitbake: the existing `sstate-shared.yml` shows that a variable from the OS environment must be captured with `:=`
  before it is used in another assignment.

## Roll-out
1. Now: trial as in chapter 05. Local `auto` server, database in the shared sstate directory, every slot read-write.
2. Start the wrynose container on the build host (read-write on a private interface, read-only on the cache network).
3. Production round, together with the read-only/read-write cache split of chapter 05: release runner on 9393 with
   read-write cache; `agl-pr` runners on `auto` + upstream 9494 with a read-only cache.
4. Only when a feed is published: add `PRSERV_HOST = "<host>:9191"` to the release job and nothing else.

## Verified against
Yocto manual (PR service, hash equivalence); bitbake 2.18 `siggen.py`, `cooker.py`, `hashserv/server.py`,
`prserv/db.py`, `prserv/serv.py`; wrynose `sstate.bbclass`, `package.bbclass`, `sanity.bbclass`, `oe/prservice.py`.
The behaviour of the wrynose container is tested only for liveness (all four ports answer), not with a real build.
