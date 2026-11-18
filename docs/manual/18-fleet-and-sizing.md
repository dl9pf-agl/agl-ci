# 18 Fleet, sizing and moves

*Read this if you add a build node, move a runner to another host, debug a stuck host, or have to say how many machines the CI needs and what they cost.*

Status: the three hosts of the first section are **in use** (since 2026-11-13). The 10 Gbit network, the staging per machine
and every node beyond the first builder are **decided** or **planned**, not built. No host address is written down here: `<builder>`,
`<mirror>` and `<fork>` stand for the addresses you use.

How to read the numbers: unmarked figures are **measured** on our hosts (date given). *(Projection)* extrapolates a measurement to a case that was not run;
*(inference)* is a conclusion that was not tested; *(observed)* is a single observation whose cause was not analysed; *(decision)* is a choice, not a fact.

## The fleet today
| Host | Pool, label | What it does | Does not do |
|---|---|---|---|
| Builder (Hetzner AX102 class, Debian 13, 32 threads, 125 GB RAM, one 1.7 TB disk) | `trusted`: `agl-pr` slots 1 and 2, `agl-lint` slot 3 | Builds and checks of pull requests from the same repo, nightly, push, release; owns the build cache `/srv/agl-cache` and offers it read-only to the mirror host | Mirror web server, hash server |
| Mirror host (the former trusted host, Debian 13) | none | nginx container `agl-mirror` on port 8080 (`/dl`, `/sstate`, `/git`), hash server container (ports 9191/9393 read-write, 9292/9494 read-only), rsync pull from the builder, git mirror refresh | Any runner |
| Fork host (Debian 10, older machine) | `untrusted`: `agl-fork`, `agl-fork-lint` | Pull requests from forks only; private cache; reads the public mirror and the read-only hash server (9494) | Anything with write access to the shared cache |

Slot limits on the builder: runner container 24 GB, Docker sidecar `MEM_LIMIT_SIDECAR=55g`, lint sidecar 2 GB (chapter 05, "Limits of a slot").
The host that runs trusted jobs and the host that runs fork code are different machines; never merge the roles (chapter 05, "Host roles").

### Data flows between the hosts
| From | To | What | How it is kept closed |
|---|---|---|---|
| Builder | Mirror host | New `dl/` and `sstate/` objects | The builder runs a read-only rsync daemon (`kit/mirror/rsyncd.sh`, container `agl-rsyncd`) bound to its tunnel address; `hosts allow` admits the mirror host only. The mirror host pulls every 5 minutes (`kit/mirror/pull-sync.sh` from `/etc/cron.d/agl-pull-sync`, `--ignore-existing --delay-updates`) |
| Mirror host | Builder | Hash server read-write (9393), mirror web (8080), git mirror (`/git`) | Private tunnel (WireGuard) between the two hosts; the read-write ports are dropped on the public interface by a `DOCKER-USER` rule in `/etc/ufw/after.rules` (it survives a reboot: ufw is enabled) |
| Mirror host | Everybody | Mirror web (8080), hash server read-only (9292/9494) | Public, read-only |
| Upstreams | Mirror host | Layer repositories, every 30 minutes (`/etc/cron.d/agl-git-mirrors`, 23 repositories) | Outbound only |
| Builder | Upstreams | Only the fetch pass: sources (`mode: fetch` reads the real upstreams); layers come from the git mirror when `GIT_MIRROR=1` (chapter 15) | Outbound only |

Ufw does not see ports that Docker publishes. The walls are therefore the bind address of the published port, `hosts allow` of the rsync daemon and the
`DOCKER-USER` rule, not ufw rules for those ports. Check from outside: the read-write port must time out on the public address and open through the
tunnel (`timeout 3 bash -c '</dev/tcp/<address>/9393'`).

## Moving the trusted runner to another host
Done on 2026-11-13 and 2026-11-16 (the mirror stayed where it was). In this order, one step at a time; every step has a check before the next.
1. **Bare host:** Debian 13, a user for the runners, the disk for `CACHE_DIR`, SSH keys. Nothing else.
2. **Tunnel:** a WireGuard interface between the new builder and the mirror host (a private /24, one address each); a ping both ways. The
   hash server read-write ports and the rsync daemon are reachable only through it.
3. **Kit:** `sudo POOL=trusted SLOTS=2 LINT_SLOTS=1 MEM_LIMIT_SIDECAR=55g MIRROR_URL=http://<mirror-tunnel-address>:8080 HASHSERV_RW=<mirror-tunnel-address>:9393 ./kit/deploy.sh <token-file>`
   (chapter 05; the values are kept in `/etc/agl-runner/runner.env`, a later `kit/update.sh` reuses them). The host needs the gid of `/dev/kvm`: the kit reads it
   (`--group-add`, trusted pool only).
4. **Cache:** the new builder starts empty and restores from the mirror (`MIRROR_URL`); the first gate is cold (16 minutes for meta-agl instead of 7).
5. **Feed the mirror back:** `kit/mirror/rsyncd.sh` on the builder, the pull cron on the mirror host (above). Without it new objects never reach the other hosts.
6. **Git mirror:** `GIT_MIRROR=1 ./kit/update.sh` on the builder, when no job runs (chapter 15).
7. **Retire the old runners:** `systemctl disable --now agl-runner@1 agl-runner@2 agl-runner@3` on the old host (stopping is not enough, a restart brings them back),
   delete their registrations (`gh api -X DELETE orgs/<org>/actions/runners/<id>`), remove `/etc/agl-runner/runner.env`, revoke the token that registered them.

### Add a node (checklist)
1. Steps 1 to 3 above on the new host; the same `MIRROR_URL` and `HASHSERV_RW`. A second builder joins the same org runner group; labels stay `agl-pr` (no label per machine).
2. Step 5 per node: each builder needs its own read-only rsync daemon and an entry in the pull cron of the mirror host, or a node's objects reach no other node.
3. Until the pull is prompt (5 minutes today), stage 2 of a pipeline that runs on another node starts cold; this is the reason the mirror hand-off must be fast
   before the fleet grows (see "Open").
4. Check `systemctl is-active 'agl-runner@*'`, the runners in the org (one per slot, labels `self-hosted Linux X64 agl-pr`), one gate.
5. Write down the node in your inventory (the manual does not list addresses).

## Debugging a host
| Symptom | Look at | Likely cause |
|---|---|---|
| Builds on the builder show no progress for hours | `timeout 3 bash -c '</dev/tcp/<mirror-tunnel-address>/9393'` from the builder; `docker ps` on the mirror host | The hash server container is down (2026-11-16: it stopped with a restart of the mirror host, had no restart policy, and two builds idled about 17 hours; they went on a few minutes after the server was up again *(observed; why they resumed was not analysed)*). Fix: start it and `docker update --restart unless-stopped <container>` |
| A cancelled run keeps running | `docker exec agl-d1 docker ps` | A normal cancel did not stop a build in two tests (chapter 13, "Cancelling a run"; cause unknown); `force-cancel` stops it and the slot re-registers after about 25 minutes *(observed earlier, not re-measured)* |
| Offline runners accumulate in the org | `gh api orgs/<org>/actions/runners` | Three offline registrations were found on 2026-11-18, one per slot; a slot restart leaves one *(inference from that count)*; delete the offline ones whose slot has an online replacement |
| Fetch jobs fail with `early EOF` or 429 | Job log of the fetch pass | Upstream drops or throttles parallel clones; since agl-ci#65 and agl-ci#66 the layers come from the git mirror, the fill retries once and at most three jobs run at the same time. One fetch pass ran green with that (13 of 13, 2026-11-18); it was mostly cache hits, so it did not test the throttle *(not yet shown)* |
| Hosts cannot reach the mirror | `curl -s -o /dev/null -w '%{http_code}\n' http://<mirror>:8080/dl/` (403 is right), `docker logs --since 20m agl-mirror` | Tunnel down, container stopped |

## How many machines? (measured 2026-11-13/14)
The benchmark built 18 images on **one** builder with two slots: `agl-image-minimal` and `agl-image-compositor` on qemux86-64, qemuarm64, qemuriscv64,
raspberrypi5 and sparrow-hawk, plus the Flutter and Qt demo images on all of them but qemuriscv64. Throw-away branches, one run per repo per stage.

| Stage | Jobs | Makespan | Slot time | Slots busy | Longest wait for a slot |
|---|---|---|---|---|---|
| Fetch | 13 of 18 ok (the rest: GitHub clone throttle) | 0.52 h | 0.85 h | 83% | 27 min |
| Cold build | 18 of 18 | **6.66 h** | 12.67 h | 95% | 390 min |
| Warm build | 18 of 18 | **1.29 h** | 2.11 h | 82% | 69 min |

Cold jobs, the longest first (minutes, with the share of sstate objects restored): `agl-image-minimal` on qemuriscv64 106 (10.8%), Flutter demo on sparrow-hawk 77 (88%),
compositor on sparrow-hawk 77 (60%), Qt demo on qemuarm64 62 (87%), Flutter demo on raspberrypi5 61 (91%). Warm jobs take 3 to 9 minutes with 99.8 to 99.9%
restored, except `agl-image-minimal` on raspberrypi5: **23 minutes**, 94.9%, 165 tasks missed against about 5 for every other image *(inference: signatures that change between runs; the
tasks are not identified yet)*.

What this means:
- **Warm is the normal day.** A full warm matrix is 2.1 slot hours: one builder with two slots does it in 1.3 hours (measured); two or three builders in about half an hour
  *(projection: 2.1 slot hours divided by four to six slots; the 23 minute raspberrypi5 job is the floor; not run)*. More nodes shorten the queue of several pull requests
  that arrive together, not a single gate *(inference)*.
- **A cold event has a floor of about two hours** *(inference: the longest job, 106 minutes, and the images that wait for its sstate; not run on several nodes)*, however many
  nodes are added. Three to four builders reach that floor for today's matrix *(projection: 12.7 slot hours over six to eight slots)*.
- **The cold figure is optimistic for a fleet.** The "cold" run was not an empty cache (qemux86-64 sstate from earlier nights) and the images of one node share sstate
  through the same directory. On several nodes the sharing goes through the mirror hand-off, so a real cold event costs more slot time than 12.7 hours *(inference, not measured)*.
- Load of one builder: about 46% CPU average with two builds, bursts of 25 cores, memory peak 11 GB of 125 (measurement of 2026-11-13).

### Decision and cost (2026-11-16)
| Node | Count | Role |
|---|---|---|
| Builders (AX102 class, 259 EUR net per month each) | 6 (today 1) | Pull requests, nightly, release |
| Fork and debug node | 1 | Fork pull requests, manual debugging; can be switched off |
| Mirror, hash server, cache | 1 (today the former trusted host) | Mirror, hash server, rsync pulls |

*(Decision)* About 8 nodes, about 2070 EUR net per month (8 x 259, calculated); a growth option of 4 more builders (12 nodes, about 3110 EUR, calculated) was kept open. The sizing above
suggests *(projection)* that today's matrix needs three to four builders; the other two to three are headroom for parallel pull requests in the morning, a bigger matrix, hardware-in-the-loop work and redundancy.
Planned for every node: a second, private 10 Gbit network next to the public 1 Gbit one *(decision, not built)* (a switch with 12 ports; an address plan such as 10.20.0.0/24 with names for the
mirror and each builder is proposed, **not confirmed**); on the fork node that link is down while it runs fork code. The tunnel between the builder and the mirror host would
then move onto it.

### GitHub plan and cost
The org is on the **free plan** and all five repositories are public (checked 2026-11-18). November so far (to the 18th): 434 hosted Linux minutes (about 60% the `images`
workflow of agl-ci *(my sum of the job times: 449 against 434 billed)*, the rest the small `matrix` and `result` jobs of every CI run; builds, `check-layer` and fetch run on our hosts and use no minutes) and about 63,800
GB-hours of Actions storage; the net cost is 0 for both, because public repositories carry a discount. The storage came from build artifacts (232 GB live: demo and minimal images,
nightly retention 30 days). Since 2026-11-18 the build job uploads no artifact (chapter 13, "Build artifacts are off"). **If a repository becomes private** the free plan
gives 500 MB of storage and 2,000 hosted minutes a month *(GitHub's published limits, not looked up in the account)*, and October (2,337 minutes, billing) already exceeded the minutes: before that, shorten the `images` workflow runs and keep artifacts off.

## Open
- The 10 Gbit network, the names and the move of the tunnel onto it.
- A prompt hand-off between nodes (pull every 5 minutes today) and the staging per machine ("way B": a canary image first, then the rest of that machine) before more than one builder runs.
- Identify the 165 unstable tasks of `agl-image-minimal` on raspberrypi5.
- A cold event on several nodes, measured.
- Backups of the hash server database, pruning, log rotation of `/var/log/agl-pull-sync.log` and `/var/log/agl-git-mirrors.log`.
- A fix for cancelling a run (a different approach than a `cancelled()` step, chapter 13).
