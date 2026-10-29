---
name: agl-ci-run-triage
description: How to read an AGL layer-CI run on GitHub and find out why it is red, vacuously green, skipped, queued, cancelled or slow - matrix job outputs, build job steps, annotations, runner and queue state, scheduled-run delays, with the exact gh commands. Consult BEFORE you claim a PR is green or broken, before re-running or cancelling a run, or when a job is stuck.
---

# Run triage (agl-ci layer CI)

Always read the state from GitHub; do not infer it. Repo-qualify PR numbers (agl-ci#38, meta-agl#8): numbers repeat across repos.

## Anatomy of a run
`ci / matrix` (hosted runner, read-only token): checks out agl-ci at the pinned SHA and agl-ucb at the default branch **at run time**, runs `checkout.sh`, computes the matrix. Outputs: `count`, `matrix`, `pool`, `mode`, `tier`, `builder`. Job summary: "Resolved pins of this run" (from agl-ci#38 on).
`ci / approve` (skipped unless fork PR) → `ci / build (<repo>/<target> on <machine>)` on `[self-hosted, <pool>]` → `ci / result` (the only required check).

## Is green real?
- **Vacuous green:** `matrix` ok but no `build` jobs / `count=0`. Cause seen: the tree was not at the commit under test (pin lost to an `overrides:` pin). Callers pinned to agl-ci `31d44b2` or older **lack** the "tree is at the commit under test" failure and the count warning; check the caller's `uses:` SHA.
- **Skipped builds** are not passes. Read the build job list, not only the check mark.
- A re-run uses the **same workflow file and pin** but takes agl-ucb's default branch as of now, so an agl-ucb merge changes what a re-run builds.

## Commands
```
gh run list -R dl9pf-agl/<repo> --limit 5 --json databaseId,event,status,conclusion,createdAt
gh run view <id> -R dl9pf-agl/<repo> --json status,conclusion,jobs \
  -q '.jobs[]|"\(.name) \(.status) \(.conclusion) \(.startedAt)"'
gh api repos/dl9pf-agl/<repo>/actions/runs/<id>/jobs --jq '.jobs[]|{name,runner_name,steps:[.steps[]|select(.conclusion!="success" and .conclusion!="skipped")|{name,conclusion}]}'
gh api repos/dl9pf-agl/<repo>/check-runs/<job-id>/annotations --jq '.[]|.message'    # timeout reason
gh pr checks <n> -R dl9pf-agl/<repo>
gh api orgs/dl9pf-agl/actions/runners --jq '.runners[]|"\(.name) \(.status) busy=\(.busy)"'
```
The job log of a running self-hosted build is not available through `gh run view --log` until it finishes; use the journal on the host (`journalctl -u agl-runner@N`).

## Symptoms
| Symptom | Likely cause | Check |
|---|---|---|
| `queued` for hours | no free runner of that label: slots busy with cold builds, or the host is in the gap after a job (see `agl-ci-hosts-and-pools`) | runner list above; wait ~30 min before calling it an outage |
| `cancelled` after exactly 10 h | job limit; annotation "exceeded the maximum execution time of 10h0m0s". 24 h limit comes only with a caller pin on agl-ci ≥ the timeout PR | annotations |
| Scheduled run starts hours after its cron | GitHub delays `schedule` events (the 01:17 UTC nightly was created at 07:03) | `gh run list --event schedule` |
| Fork PR waits | `agl-fork` host offline, or approval pending | runner list, `approve` job |
| `matrix` fails | matrix validation (`... is not allowed`) or checkout failed or tree not at pin | step log of `matrix` |
| Cold build is slow | first build of an image: `agl-image-minimal` 4h29, Qt/Flutter demos over 10 h; later builds resume from sstate | sstate in `CACHE_DIR` |
| Build red, same on re-run | real failure: read the `build` step log, last bitbake error | log |

## Rules of thumb
- **Hard-stop before acting:** when a re-run depends on a merge, verify `MERGED` and the merged file content first, in the same command, and exit if not. A premature re-run wastes hours of slot time; cancel at once if it happens.
- Cancel and re-run of a PR run while a cold build is in progress throws away nothing that finished (sstate stays), but pushing a new commit to the PR restarts its jobs.
- Report what you saw, with time and run id; do not narrate a cause you did not verify.
