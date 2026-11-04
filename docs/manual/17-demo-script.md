# 17 Demo run-through

A script for showing the CI to somebody in about 45 minutes. Each scene says what to say, what to show (command or page), what to expect and what to do if it does
not look like that. The numbers are from real runs between 28 October and 4 November 2026; take the ones of the day before as the new reference. Addresses of the
hosts are never written here: `<TRUSTEDHOST>` is the build and cache host (mirror on port 8080, read-only hash server on 9494).

## Before the demo (the evening before, 10 minutes)
1. Runners: `gh api orgs/dl9pf-agl/actions/runners --paginate --jq '.runners[]|select(.status=="online")|"\(.id) busy=\(.busy) \([.labels[].name]|map(select(startswith("agl-")))|join(","))"'`
   Expect two `agl-pr`, one `agl-lint`, one `agl-fork`, one `agl-fork-lint`, all idle. Without `--paginate` only 30 entries are listed and online runners can be missing.
2. Last nightly green: `gh run list -R dl9pf-agl/meta-agl --workflow ci.yml --event schedule --limit 3`. GitHub starts the schedule late (01:17 UTC cron, in practice 07:30).
3. Caches warm: a dispatch of the nightly tier (scene 5) the day before, so that the runs shown take minutes and not hours.
4. On the trusted host: `systemctl status 'agl-runner@*' --no-pager | grep Active:` and `docker ps --format '{{.Names}}  {{.Status}}'` (`agl-mirror` and the hash server container up).

## Scene 1: the pull request gate (5 minutes)
*Say:* one required check, `ci / result`, which waits for everything else. Builds run on our own hosts, not on GitHub's.
*Show:* a pull request of meta-agl, for example the pin bump #17: `gh pr checks 17 -R dl9pf-agl/meta-agl`.
*Expect:* `ci / matrix` about 1 minute (GitHub-hosted), `ci / check-layer` 25 to 35 minutes, `ci / build (...)` 12 to 80 minutes depending on how busy the host is
(about 20 minutes for the whole gate on an idle host with a warm cache), then `ci / result` pass. The yocto-check-layer run and the build run in parallel.
*If it queues:* both build slots are busy (a cold build holds a slot for hours); `gh api repos/dl9pf-agl/meta-agl/actions/runs/<id>/jobs --jq '.jobs[]|{name,status,runner_name}'`.

## Scene 2: a pull request from a fork (7 minutes)
*Say:* fork code never runs on the trusted host. The trusted host refuses it, the untrusted host has no secrets, no read-write hash server and reads the public mirror.
*Show (works):* the test pull request meta-agl#16 (closed): run 41055479201. `gh api repos/dl9pf-agl/meta-agl/actions/runs/41055479201/jobs --jq '.jobs[]|{name,runner_name,labels}'`
shows the build on a runner with the labels `self-hosted,agl-fork`. In its log the `validate` step prints `mirror=set ... hashserv_upstream=set`.
*Expect:* 30 minutes from an **empty** local cache, `Sstate summary: Wanted 3537 Local 0 Mirrors 3532 Missed 5 (99% match)`: nearly everything came from the mirror.
*Show (refused):* meta-agl#11 (closed), a fork pull request whose jobs ask for the trusted label. Each job ends in `Set up runner` with
`agl-hook: job refused: pull request from fork dl9pf/meta-agl on a trusted host`.
*Not shown yet:* a pull request from an outside contributor's account (the "Approve and run" gate); see scene 7.

## Scene 3: reading a red run (7 minutes)
*Say:* a red run says where to look; the log of the failing task is usually in the job log, the full bitbake output of fetch runs is in the uploaded artifact.
*Show:* the KVM demo on `qemux86-64` that failed after 5 h 34 min (meta-agl-demo run 41678903588). `gh run view <id> -R <repo> --json jobs -q '.jobs[]|select(.conclusion=="failure")|.name'`,
then the annotation (`gh api repos/<repo>/check-runs/<job id>/annotations --jq '.[].message'`) and the first `ERROR:` line of the job log:
`install: cannot stat '.../agl-ivi-demo-flutter-guest-qemux86-64.ext4'`. Then the finding behind it: chapter 13, "Pitfalls found in the layers".
*Say:* it is shelved for x86-64 on purpose; the KVM demo is built on qemuarm64 (scene 4).

## Scene 4: the nightly (10 minutes)
*Say:* every night the images of the matrix are built, and the sources of **all** images, built or not, are fetched into the cache and the mirror.
*Show:* `gh run list -R dl9pf-agl/meta-agl --workflow ci.yml --event schedule --limit 3`, then the jobs of the latest run:
`gh api repos/dl9pf-agl/meta-agl/actions/runs/<id>/jobs --paginate --jq '.jobs[]|select(.conclusion!="skipped")|"\(.name): \(.conclusion)"'`.
*Expect (run 41792598439, 4 November):* 13 of 13 fetch jobs green; `agl-image-minimal` about 11 minutes, the Flutter demo about 27, `check-layer` about 24. The KVM demo on
qemuarm64 (from the matrix of 4 November): 39 minutes for a rebuild with `Wanted 11529 Local 11519 Missed 10 (99% match)`.
*Say:* a cold build of such an image takes hours once; the shared cache (sstate, downloads, hash equivalence) makes every later run minutes. The `Sstate summary` line is the
quick measure of that (chapter 13).

## Scene 5: starting a build by hand (6 minutes)
*Show:* `ci/scripts/manual_dispatch.sh.example` in meta-agl without options: it prints its help and starts nothing. Then
`ci/scripts/manual_dispatch.sh --tier nightly --mode fetch --watch` (copy the example first). `--mode fetch` only fills the cache and takes about 10 minutes.
*Say:* a tier selects which matrix entries are built; one image on its own is built with a throw-away branch (chapter 13, "Build exactly one entry").
*If a run does not start for hours:* GitHub delays dispatches and schedules by up to several hours at times; the run shows `queued` or `pending` with no jobs.
*To stop a run:* `gh run cancel <id> -R <repo>`; **a normal cancel does not stop the build container on our hosts**, so a job can stay `in progress`; then
`gh api -X POST repos/<repo>/actions/runs/<id>/force-cancel` (the slot's runner restarts and is back after about 25 minutes).

## Scene 6: cache, mirror and hash server (5 minutes)
*Say:* the mirror (downloads and sstate) and the read-only hash server are public by design; the read-write ports are closed to the outside.
*Show:* `curl -s -o /dev/null -w '%{http_code}\n' http://<TRUSTEDHOST>:8080/dl/` prints `403` (no directory listing), a known file prints `200`.
`bitbake-hashclient --address <TRUSTEDHOST>:9494 ping` answers; the read-only server refuses `clean-unused`, `remove` and `gc-mark` (tested locally with bitbake 2.18), and
9191 and 9393 are dropped on the external interface.
*Say:* 99% against 65%: the same task graph restored 65% when a second, aarch64 world was built next to the x86-64 image, and 99% once host and guest shared the architecture.

## Scene 7: what is not done (5 minutes, keep it honest)
- A pull request from an outside contributor's account (the approval gate) has not been tested; the fork tests ran as an organisation admin, who GitHub does not count as outside.
- The three layer repos are still behind the upstream at `git.automotivelinux.org` (the rebase is planned, it needs a ruleset lift for the force push).
- Shelved: the KVM demo on x86-64 (install step) and the Xen test image on x86-64 (guest machine); both come from the layers' `MACHINE` hooks under kas (chapter 13).
- The Docker sidecar of a job is privileged: it separates a job from the host kernel only as far as containers do, so one pool per host is the real boundary (chapter 05, "Sidecar privilege").
- An equivalence that saved a rebuild through the hash server has not been seen yet; the mirror runs over plain HTTP.
