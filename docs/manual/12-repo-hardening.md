# 12 Repository hardening

*Read this if you change repository, ruleset or organisation settings.*

Status: files and `scripts/github-settings.sh` **implemented**; settings applied on 2026-10-22; later changes are in "Settings log" at the end.

## What is in the repo
| File | Purpose |
|---|---|
| `LICENSE` | Apache-2.0 (decision 2026-10-22) |
| `SECURITY.md` | Reporting path (private vulnerability reporting), supported versions, scope |
| `.github/CODEOWNERS` | Owner of everything; becomes a gate only with `require_code_owner_review` (see below) |
| `.github/dependabot.yml` | Weekly updates of the SHA-pinned actions, 7-day cooldown |
| `.github/workflows/scorecard.yml` | OpenSSF Scorecard weekly and on `main`; results in the Security tab |
| `policy/github/ruleset-main.json` | The `main` branch ruleset, as code |
| `scripts/github-settings.sh` | Applies ruleset and repo settings through `gh api`; idempotent; used for adopters too |

## Settings applied by `scripts/github-settings.sh`
- Ruleset `main`: no deletion, no force-push, pull request required, status check `lint` required, 0 approvals, no bypass.
  Merge method: **rebase only** (`allowed_merge_methods: ["rebase"]`, 2026-10-23), see "Merge strategy" below.

Layer repos (2026-10-23): `meta-agl` has the same ruleset (without the repo-level merge settings, the ruleset alone limits the method) with the required check `ci / result` (the `result` job of the
caller workflow), applied with `CHECK='ci / result' ONLY_RULESET=1 scripts/github-settings.sh dl9pf-agl/meta-agl`.
`ONLY_RULESET=1` leaves the other repository settings alone; they are not applied to `meta-agl` yet (merge methods,
secret scanning, push protection, private vulnerability reporting). Full-SHA pinning is on for all five repos since 2026-10-29.
`meta-agl-demo`, `meta-agl-devel` and `agl-ucb` have the ruleset since 2026-10-29 (`CHECK='ci / result'`, for agl-ucb `CHECK='lint / lint'`,
both with `ONLY_RULESET=1`), after their caller and lint workflow reported; their repo-level merge settings still allow merge and squash
commits, the ruleset alone limits the method to rebase.
- Secret scanning and push protection on; private vulnerability reporting on.
- Actions: full-SHA pinning required; fork-PR workflows need approval for all external contributors; default
  `GITHUB_TOKEN` read-only; Actions cannot approve PRs.
- Branches deleted on merge.
- Merge methods: only rebase (repo setting and ruleset).

Only `lint` is a required check on purpose: `images.yml` is path-filtered, and a required check that does not run
blocks every PR that does not touch those paths. Image changes are covered by the `images` run on the PR and by
`verify` after merge to `main`.

## Settings that exist in the web UI only (owner action)
1. Org *Authentication security*: require two-factor authentication for all members.
2. Org *Actions > General*: same SHA-pinning and fork-PR approval policy at org level, so new repos inherit it (open: the org-level SHA-pinning setting is still off; the five repos have it per repo).
3. Org *Packages*: allow public packages; make `builder` and `runner` public.
4. Org *Runner groups*: allow public repositories only after the fork-PR approval is on.

## Enabling and enforcing approvals later
Fork PRs always need approval to run workflows (setting above). To require review of every change:
```
APPROVALS=1 scripts/github-settings.sh                  # 1 approval, nobody bypasses
APPROVALS=2 BYPASS=admin scripts/github-settings.sh     # 2 approvals, repo admins may bypass (break-glass)
```
Add `"require_code_owner_review": true` in `policy/github/ruleset-main.json` once `.github/CODEOWNERS` lists a team.
Bypass by admins is visible in the audit log; use it only for the recovery path in chapter 10, and note it in the hand-over log.
A solo maintainer cannot satisfy `APPROVALS>=1` without bypass because GitHub does not allow approving your own PR.

## Scorecard
`scorecard.yml` publishes results, so the badge and API work:
`https://api.securityscorecards.dev/projects/github.com/dl9pf-agl/agl-ci`. Expected remaining findings until a second
engineer exists: Code-Review, Branch-Protection (partial), Contributors, Signed-Releases (until the first signed tag),
CII-Best-Practices. Not addressed on purpose: Fuzzing, SAST via CodeQL (zizmor covers workflow security; revisit).

## Adopting elsewhere
`scripts/github-settings.sh OWNER/REPO` plus `policy/github/ruleset-main.json` reproduce the repo side. GitLab/Forgejo
equivalents: protected branches, merge request approval rules, secret detection (chapter 11).

## Merge strategy (decision 2026-10-23)
Three options were weighed. The goal: linear history like Gerrit's "rebase if necessary", without hand-updating every
pull request after each merge.

| Option | What it does | Cost |
|---|---|---|
| 1. Up-to-date rule + manual update | PR must contain current `main` with green checks (`strict_required_status_checks_policy: true`) | every merge makes other PRs `BEHIND`; update by button or `gh pr update-branch --rebase N`; one CI run each |
| **2. Rebase merge, no up-to-date rule (chosen)** | GitHub replays the PR commits onto current `main` at merge; `strict` is false | no manual update; the merged result was not built as such (CI ran before the rebase); new commit SHAs, so commit signatures on PR commits do not survive |
| 3. Merge queue (**option, not enabled**) | queue rebases onto latest `main`, runs CI on that result, then merges | needs `merge_group` in every required workflow; build per queued PR; see below |

Option 2 is set by `ruleset-main.json` (`allowed_merge_methods: ["rebase"]`, `strict_required_status_checks_policy:
false`) and `scripts/github-settings.sh` (rebase allowed, squash and merge commit off). Applied to `agl-ci` and
`meta-agl`. Revert to option 1 by setting `strict` back to true.

Why the gap in option 2 is acceptable here: `lint` is one minute and the nightly build on `main` (layer repos) catches a
bad combination within a day. If a repository sees broken `main` from interleaved merges, move it to option 3.

### Option 3: merge queue (documented, not enabled)
From the GitHub docs (Managing a merge queue): enabled per branch rule with "Require merge queue"; merge, rebase or
squash can be chosen for queued PRs; **workflows must trigger on `merge_group`**, otherwise "status checks will not be
triggered" and "the merge will fail"; limits for concurrent builds and PRs per merge; not usable with wildcard branch
patterns. The docs page does not state which plans or repository visibilities have it: **verify on the org before
relying on it** (settings of the `main` ruleset show the option or not).

To adopt it:
1. Add `merge_group:` to `on:` of every workflow that provides a required check (`lint.yml`, the layer callers; in
   `layer-ci.yml` the tier for `merge_group` must be forced like for `pull_request`, never from inputs).
2. Enable "Require merge queue" in the ruleset, merge method rebase, build concurrency 1 for the layer repos (one
   self-hosted slot pool).
3. Keep `strict` false (the queue provides the guarantee).
Cost: a multi-hour cold build per queued PR; with the warm cache about 25 minutes each.

## Settings log
| Date | Change |
|---|---|
| 2026-10-22 | Settings of `agl-ci` applied with `scripts/github-settings.sh`: `main` ruleset (pull request, `lint`), secret scanning, push protection, full-SHA pinning, fork-PR approval, read-only token |
| 2026-10-23 | Merge strategy: rebase only (ruleset and repo settings); `meta-agl` gets the ruleset with `ci / result` |
| 2026-10-29 | Full-SHA pinning (`sha_pinning_required`) switched on for `agl-ucb`, `meta-agl`, `meta-agl-demo`, `meta-agl-devel` after a scan of all workflows (9 files, default branches and open pull request heads) found no unpinned `uses:`; the org-level setting stays off. Whether to keep the update churn is to be decided later |
| 2026-10-29 | `main` ruleset (pull request required, rebase only, no force-push or deletion, 0 approvals, no bypass) added to `agl-ucb` (required check `lint / lint`), `meta-agl-demo` and `meta-agl-devel` (`ci / result`) with `ONLY_RULESET=1`; all five repos now have one |
