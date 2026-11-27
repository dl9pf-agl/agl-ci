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
| Fork host (Debian 13; its provider image name still says buster) | `untrusted`: `agl-fork`, `agl-fork-lint` | Pull requests from forks only; private cache; reads the public mirror and the read-only hash server (9494) | Anything with write access to the shared cache |

Slot limits on the builder: runner container 24 GB, Docker sidecar `MEM_LIMIT_SIDECAR=55g`, lint sidecar 2 GB (chapter 05, "Limits of a slot").
The host that runs trusted jobs and the host that runs fork code are different machines; never merge the roles (chapter 05, "Host roles").

### Data flows between the hosts
| From | To | What | How it is kept closed |
|---|---|---|---|
| Builder | Mirror host | New `dl/` and `sstate/` objects | The builder runs a read-only rsync daemon (`kit/mirror/rsyncd.sh`, container `agl-rsyncd`) bound to its tunnel address; `hosts allow` admits the mirror host only. The mirror host pulls every 5 minutes (`kit/mirror/pull-sync.sh` from `/etc/cron.d/agl-server`, `--ignore-existing --delay-updates`) |
| Mirror host | Builder | Hash server read-write (9393), mirror web (8080), git mirror (`/git`) | Private tunnel (WireGuard) between the two hosts; the read-write ports are dropped on the public interface by a `DOCKER-USER` rule in `/etc/ufw/after.rules` (it survives a reboot: ufw is enabled) |
| Mirror host | Everybody | Mirror web (8080), hash server read-only (9292/9494) | Public, read-only |
| Upstreams | Mirror host | Layer repositories, every 30 minutes (`kit/server.cron`, 23 repositories) | Outbound only |
| Builder | Upstreams | Only the fetch pass: sources (`mode: fetch` reads the real upstreams); layers come from the git mirror when `GIT_MIRROR=1` (chapter 15) | Outbound only |
| Builders | Mirror host (download server) | `staging/release/<branch>/<version>/` of every build host, every 5 minutes (`kit/release/run.sh`, `/etc/cron.d/agl-server`) | Same rsync daemon and walls as `dl/` and `sstate/`; the mirror host is a build host too and fills the same tree directly |
| Mirror host | GitHub | `git pull` of agl-ucb (engineer signatures), download of the signed release asset | Outbound only, anonymous (public repository) |

Ufw does not see ports that Docker publishes. The walls are therefore the bind address of the published port, `hosts allow` of the rsync daemon and the
`DOCKER-USER` rule, not ufw rules for those ports. Check from outside: the read-write port must time out on the public address and open through the
tunnel (`timeout 3 bash -c '</dev/tcp/<address>/9393'`).

### IPv6 (second path, check it with every wall)
Every wall above has an IPv4 and an IPv6 side, and the walls of the published ports are IPv4 rules (`DOCKER-USER`, `hosts allow`, bind address). State on 2026-11-18, measured:

| Host | Global IPv6 address | Listening on `[::]` | ufw IPv6 | `ip6tables` INPUT |
|---|---|---|---|---|
| Builder | yes (not recorded here) | only SSH; the rsync daemon is bound to one IPv4 tunnel address, so it has no IPv6 listener | `IPV6=yes`, two `(v6)` rules (not looked at) | policy `DROP` |
| Mirror host | **no** (link-local only) | SSH, 8080, 9191, 9292, 9393, 9494 (Docker publishes both families) | `IPV6=yes`, allows 22, 80 and 8080 | policy `DROP` |
| Fork host | no (link-local only) | only SSH | `IPV6=yes`, six `(v6)` rules (not looked at) | policy `DROP` |

So nothing sensitive is reachable over IPv6 today: the one host that publishes the hash server ports has no global address, and even with one the default policy would drop 9191 and 9393
*(inference from the rules, not tested; there is no address to test against)*. The builder has a global address but listens there only with SSH.
Rules that stay true for every host and every new service:
1. A new published port is checked for both families: `ss -ltn | grep '\[::\]'`, `ip -6 addr show scope global`, `grep ^IPV6 /etc/default/ufw`, `ufw status` (the `(v6)` lines), `ip6tables -S INPUT`.
2. A port that must not be public is not published on all addresses: bind it to one IPv4 address (`RSYNCD_BIND`, `RW_BIND`), as the rsync daemon is. A bind address needs no firewall twin.
3. The read-write hash ports (9191, 9393) over IPv6: test from outside once a global address exists; expected result: timeout. A link-local `fe80::` address is not a test target (it needs a zone and is not routed).
4. When Docker's `ip6tables` is enabled, the `DOCKER-USER` rule needs a twin in `/etc/ufw/after6.rules` *(not checked on our hosts, untested)*.

## Moving the trusted runner to another host
Done on 2026-11-13 and 2026-11-16 (the mirror stayed where it was). In this order, one step at a time; every step has a check before the next.
1. **Bare host:** Debian 13, a user for the runners, the disk for `CACHE_DIR`, SSH keys. Nothing else.
2. **Tunnel:** a WireGuard interface between the new builder and the mirror host (a private /24, one address each); a ping both ways. The
   hash server read-write ports and the rsync daemon are reachable only through it.
3. **Kit:** `sudo POOL=trusted SLOTS=2 LINT_SLOTS=1 MEM_LIMIT_SIDECAR=55g MIRROR_URL=http://<mirror-tunnel-address>:8080 HASHSERV_RW=<mirror-tunnel-address>:9393 ./kit/deploy.sh <token-file>`
   (chapter 05; the values are kept in `/etc/agl-runner/runner.env`, a later `kit/update.sh` reuses them).
4. **Cache:** the new builder starts empty and restores from the mirror (`MIRROR_URL`); the first gate is cold (16 minutes for meta-agl instead of 7).
5. **Feed the mirror back:** `kit/mirror/rsyncd.sh` on the builder, the pull cron on the mirror host (above). Without it new objects never reach the other hosts.
6. **Git mirror:** `GIT_MIRROR=1 ./kit/update.sh` on the builder, when no job runs (chapter 15).
7. **Retire the old runners:** `systemctl disable --now agl-runner@1 agl-runner@2 agl-runner@3` on the old host (stopping is not enough, a restart brings them back),
   delete their registrations (`gh api -X DELETE orgs/<org>/actions/runners/<id>`), remove `/etc/agl-runner/runner.env`, revoke the token that registered them.

### Add a node (checklist)
After the tunnel (step 2 above), `kit/trusted-pr-install-host.sh --run` covers steps 3 to 5 for the new node and the SCTP block (chapter 05,
"Host scripts"; not run on a real host yet).

1. Steps 1 to 3 above on the new host; the same `MIRROR_URL` and `HASHSERV_RW`. A second builder joins the same org runner group; labels stay `agl-pr` (no label per machine).
2. Step 5 per node: each builder needs its own read-only rsync daemon and an entry in the pull cron of the mirror host, or a node's objects reach no other node.
3. Until the pull is prompt (5 minutes today), stage 2 of a pipeline that runs on another node starts cold; this is the reason the mirror hand-off must be fast
   before the fleet grows (see "Open").
4. Block the SCTP module (below, "Host CVE watch"), on every host.
5. Check `systemctl is-active 'agl-runner@*'`, the runners in the org (one per slot, labels `self-hosted Linux X64 agl-pr`), one gate.
6. Write down the node in your inventory (the manual does not list addresses).

## Debugging a host
| Symptom | Look at | Likely cause |
|---|---|---|
| Builds on the builder show no progress for hours | `timeout 3 bash -c '</dev/tcp/<mirror-tunnel-address>/9393'` from the builder; `docker ps` on the mirror host | The hash server container is down (2026-11-16: it stopped with a restart of the mirror host, had no restart policy, and two builds idled about 17 hours; they went on a few minutes after the server was up again *(observed; why they resumed was not analysed)*). Fix: start it and `docker update --restart unless-stopped <container>` |
| A cancelled run keeps running | `gh run view <id> --json jobs`: a job `in_progress` after the cancel | The job's `if:` uses `always()`, which GitHub never cancels (found 2026-11-19; `build` and `check-layer` use `!cancelled()` since the fix, a caller on an older pin still has it); `force-cancel` stops it and the slot re-registers after about 25 minutes (chapter 13, "Cancelling a run") |
| Offline runners accumulate in the org | `gh api orgs/<org>/actions/runners` | Three offline registrations were found on 2026-11-18, one per slot; a slot restart leaves one *(inference from that count)*; delete the offline ones whose slot has an online replacement |
| Fetch jobs fail with `early EOF` or 429 | Job log of the fetch pass | Upstream drops or throttles parallel clones; since agl-ci#65 and agl-ci#66 the layers come from the git mirror, the fill retries once and at most three jobs run at the same time. One fetch pass ran green with that (13 of 13, 2026-11-18); it was mostly cache hits, so it did not test the throttle *(not yet shown)* |
| Hosts cannot reach the mirror | `curl -s -o /dev/null -w '%{http_code}\n' http://<mirror>:8080/dl/` (403 is right), `docker logs --since 20m agl-mirror` | Tunnel down, container stopped |
| The disk of a runner host fills up, `docker system df` shows hundreds of local volumes | `docker volume ls -qf dangling=true \| wc -l`, `docker system df` | The `docker:dind` sidecar leaves an anonymous 1.3 GB volume per job when its container is removed with `rm -f`; fixed in agl-ci#71, see "Housekeeping" below |

## Housekeeping

### Dangling Docker volumes (found 2026-11-19)
- **Observed:** the sidecar image `docker:dind` declares `VOLUME /var/lib/docker`. `kit/run-loop.sh` removed the job containers with `rm -f`, which keeps their anonymous volumes. On 2026-11-19 the builder had 391 dangling volumes (487.5 GB, about 1.3 GB each), the old trusted host 274 (about 280 GB) and the fork host 22. All were removed by hand; the disk use of the builder went from 621 GB to 150 GB.
- **Fix:** agl-ci#71 changes the cleanup to `rm -fv`. *(Projection: no new dangling volumes after it is installed. Not yet confirmed; check the count a day later.)*
- **Check (every host with a slot):** `docker volume ls -qf dangling=true | wc -l` stays near 0, `docker system df` shows the local volumes small.
- **Clean up:** `docker volume ls -qf dangling=true | xargs -r -n 20 docker volume rm`. Docker refuses a volume that a container uses. The named volumes (`agl-w<slot>` of a running slot, `prhashserv-wrynose` of the hash server) are not dangling while in use, so leave `docker volume prune -a` alone.
- **Images:** an image that a host uses by digest (`RUNNER_IMAGE=...@sha256:...`) shows as dangling (`<none>`), and so did an image that a running container used (the fork host refused to remove it: "image is being used by running container"). Remove an image only by its ID and read the `in use` refusal as the right answer, never prune images blindly.

### Updating the run loop without killing jobs
`kit/update.sh` redeploys and restarts every slot, which kills the jobs that run. For a change in `kit/run-loop.sh` only (agl-ci#71 was installed this way on 2026-11-19):
1. Check that no slot is busy: `gh api orgs/<org>/actions/runners --paginate -q '.runners[] | select(.busy) | .name'` prints nothing.
2. On the host: `cd <kit checkout> && git pull --ff-only && install -m 0755 kit/run-loop.sh /opt/agl-runner/run-loop.sh`. A running loop keeps its old copy; `install` replaces the file.
3. `systemctl restart agl-runner@N` for each idle slot. The runner container of an idle slot is only waiting; the restart leaves one offline registration per slot (delete it, "Debugging a host"). The new registrations appeared within about a minute on both hosts *(observation, one time)*.

### Automatic security updates
Verified on 2026-11-19 on the builder, the fork host and the old host: the origin is `trixie-security` only, the blacklist is `docker.io containerd runc`, `Automatic-Reboot` is `false`, and the first runs found no package to install (`unattended-upgrades-dpkg.log` empty). Check with `ls -la /var/log/unattended-upgrades/`, `systemctl list-timers 'apt-daily*'` and `apt-config dump | grep -i Unattended-Upgrade::`.

### Why did a build miss the cache?
The `Sstate summary: Wanted W Local L Mirrors M Missed X` line of the job log counts the tasks that run. To find out what a miss is on a spare host (the fork host when idle), without building:
1. Run `bitbake -n <target>` (dry run: lists the tasks that would run, downloads nothing) or `bitbake -S none <target>` (writes the signature files under `build/tmp/stamps`) in the runner image with the kas files of the matrix entry. Run as the runner user (`--user 1001:1001`): bitbake refuses root.
2. Pass the read-only hash server (`AGL_HASHSERV_UPSTREAM`, from `runner.env`). **Observed 2026-11-19:** without it 100 of 610 tasks of `hdparm` and the kernel looked missed, with it 1 did. Judging a cache without the server gives a wrong picture.
3. A cached object is named after the equivalence hash, a signature file of `bitbake -S none` after the task hash, so the two names do not match even for a hit. Compare the contents with `bb.siggen.compare_sigfiles` of a bitbake 2.18 checkout (`bitbake-diffsigs` starts a full bitbake environment even for two files and fails without one).
4. **Case 2026-11-13:** the warm run of `agl-image-minimal` on raspberrypi5 missed 165 of 3267 tasks (kernel, `u-boot`, `perf`, `connman`, `ofono`, `bluez5`, `hdparm`). On 2026-11-19 the same image missed 6 on the fork host and 6 in CI, with and without `BAD_RECOMMENDATIONS += "hdparm"` (which does not remove the build of `hdparm` anyway: it only filters what is installed). The cause is unknown. *(Inference: the warm run itself refilled the cache. Not shown.)* Two things were measured that point at a source of unstable hashes without proving one: most native recipes have 2 to 4 cached `populate_sysroot` hashes, and the kernel has three cached `configure` hashes. Six native recipes were compared: their hashes differ by the multiconfig (`agl-kvm-guest`, `agl-xen-domu`) that built them.

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

## Host CVE watch
The images are scanned (chapter 09: builder and runner image). The **hosts** are not: kernel, Docker stack and the mirror's web server need their own watch. The mirror and the
hash server images are not mentioned in chapter 09, so treat them as unscanned *(inference from the chapter)*. Check weekly and whenever a disclosure like the one below appears.

| Component | Where | State on 2026-11-18 | How to look |
|---|---|---|---|
| Linux kernel | all three hosts | 6.12.117 on all three hosts since 2026-11-18 (was 6.12.113 on the mirror and fork host, 6.12.115 on the builder) | `uname -r`; `apt list --upgradable 2>/dev/null \| grep linux-image` |
| SCTP module | all three hosts | not loaded; blocked on all three hosts since 2026-11-18 (`install sctp /bin/false`, see "SCTP block" below) | `lsmod \| grep sctp`; `modprobe -n -v sctp` prints `install /bin/false` |
| nginx | container `agl-mirror` on the mirror host | 1.30.6, image pinned by digest in `kit/mirror/run.sh`; nginx.org lists 1.30.7 and 1.31.9 as fixed | `docker exec agl-mirror nginx -v`; <https://nginx.org/en/security_advisories.html> |
| docker.io, containerd, runc | builder, fork host | Debian trixie packages: docker 26.1.5, containerd 1.7.24, runc 1.1.15 | `docker version`; `docker info \| grep -i -E 'containerd\|runc'`; Debian security tracker (source packages `runc`, `docker.io`, `containerd`) |

**Updating a host** (done 2026-11-18, one host at a time, with no job running: the fork host first, the builder, the mirror host last because it carries the hash server): `apt-get -y full-upgrade`, then `systemctl reboot`.
Use `full-upgrade`, not `upgrade`: a kernel update brings a new package (`linux-image-6.12.117…`), which `apt-get upgrade` never installs, so the host rebooted into the old kernel. After a reboot check
`uname -r`, `systemctl is-active 'agl-runner@*'` and `docker ps`; the slots register again after one to three minutes and leave their old registrations offline (delete them, "Debugging a host").
Before a reboot check that every container has a restart policy (`docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' <name>`): the mirror, the hash server and `agl-rsyncd` have `unless-stopped`.
**Automatic security updates** (switched on 2026-11-18 on all three hosts). Before that `unattended-upgrades` was installed on the mirror and the fork host but never active: there was no
`/etc/apt/apt.conf.d/20auto-upgrades`, so the daily apt timer ran and did nothing, which is why the zlib update of 7 Nov waited 11 days; the builder did not have the package. Now, on every host:
- `/etc/apt/apt.conf.d/20auto-upgrades`: package lists and unattended upgrade every day.
- `/etc/apt/apt.conf.d/52agl-unattended`: only the `trixie-security` origin (a `#clear` of Debian's default list comes first, otherwise the stable point-release origin stays allowed), the packages
  `docker.io`, `containerd` and `runc` blacklisted (their update restarts the Docker daemon and with it the running jobs) and `Automatic-Reboot "false"`.
- Fork host only: `/etc/needrestart/conf.d/agl.conf` with `$nrconf{restart} = 'l';`, so that `needrestart` lists services that need a restart and does not restart them.
Check: `apt-config dump | grep -E 'APT::Periodic::(Update|Unattended)|Unattended-Upgrade::(Origins-Pattern|Package-Blacklist|Automatic-Reboot)'` and
`LC_ALL=C unattended-upgrade --dry-run -d 2>&1 | grep -E 'Allowed origins|blacklist'` (`LC_ALL=C`: the mirror host has a German locale); after the first run
`/var/log/unattended-upgrades/unattended-upgrades.log` exists. **Still manual:** every reboot into a new kernel, and the Docker stack; check weekly (the commands above).
The first automatic run is the daily apt timer in the early morning; it was not yet observed. Debian's default configuration also removes unused old kernels *(default setting from memory, not
checked on our hosts)*.

IPv6 on the mirror host: the published ports listen on `[::]` as well, and the `DOCKER-USER` rule is IPv4 only. The public interface has an IPv4 address and only a link-local IPv6 address (`ip addr`, 2026-11-18), so the host cannot be reached over IPv6 from outside its segment
(measured). If a global address is ever added: ufw's IPv6 side allows only 22, 80 and 8080 and `ip6tables` has `INPUT DROP`, so 9191/9393 should stay closed *(inference from the rules, not tested)*; test it then.

Known open items on that date: the Debian tracker lists runc 1.1.15 in trixie as vulnerable without a fix (CVE-2025-31133, -52565, -52881, CVE-2026-41579) and two open docker.io
CVEs (CVE-2026-92542, -92543). The jobs run in the Docker daemon of a privileged sidecar, so a job already has far-reaching rights on its host; whether the host runc is the deciding
weakness was not tested *(inference)*.

**SCTP block** (`install sctp /bin/false`, written by the host scripts of chapter 20): no job needs SCTP, and the kernel bugs of the SCTP stack (send path, CVE-2026-46227; ASCONF "SCTPhantom", CVE-2026-64564, third-party
sources, not checked against kernel.org) can be reached by any process that opens an SCTP socket, which loads the module. On each host, as root:
```
echo 'install sctp /bin/false' > /etc/modprobe.d/disable-sctp.conf
modprobe -n -v sctp        # must print: install /bin/false
```
It changes nothing for a running system (the module is not loaded) and nothing for CI.

**Case, 2026-11-18: "nginx2root"** (CVE-2026-123007, HTTP/2 flow control, nginx 1.9.5 to 1.31.8; fixed in 1.31.9 and 1.30.7). Procedure that was followed, for the next one: (1) read the
advisory on nginx.org, not only the blog; (2) does our configuration enable the precondition? The mirror has no `http2`, no HTTP/3, no proxy, mail or stream module, no `alias`, `try_files`
or `rewrite`, and the TLS port is off, so the paths of the article do not apply; (3) which version runs (1.30.6, vulnerable code); (4) patch when the fixed image exists: new digest in `kit/mirror/run.sh`, recreate the container.

## Open
- The 10 Gbit network, the names and the move of the tunnel onto it.
- A prompt hand-off between nodes (pull every 5 minutes today) and the staging per machine ("way B": a canary image first, then the rest of that machine) before more than one builder runs.
- The 165 missed tasks of `agl-image-minimal` on raspberrypi5 (2026-11-13) did not come back on 2026-11-19; the cause is unknown ("Why did a build miss the cache?"). Compare two builds with the same inputs to find a native or kernel recipe whose output is not reproducible.
- A cold event on several nodes, measured.
- Move the mirror image to nginx 1.30.7 or later (the kernels are updated since 2026-11-18).
- IPv6: test the read-write hash ports from outside once the mirror host gets a global address; consider binding 9191 and 9393 to the tunnel address instead of every address.
- Backups of the hash server database, pruning, log rotation of `/var/log/agl-release.log` and `/var/log/agl-mirror.log`.
