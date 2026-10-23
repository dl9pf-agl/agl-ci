# 12 Repository hardening

Status: files and `scripts/github-settings.sh` **implemented**; settings applied on 2026-10-22 (see log at the end).

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
  "Require branches to be up to date before merging" is on (`strict_required_status_checks_policy`, 2026-10-23): a pull
  request must contain the current `main` and have a green `lint` on that state, so the merged result is what was
  tested. Cost: every merge makes the other open pull requests out of date; for `lint` (one minute) that is cheap. A
  repository whose required check is a multi-hour build needs a merge queue or accepts the serialisation of merges.
- Secret scanning and push protection on; private vulnerability reporting on.
- Actions: full-SHA pinning required; fork-PR workflows need approval for all external contributors; default
  `GITHUB_TOKEN` read-only; Actions cannot approve PRs.
- Branches deleted on merge.

Only `lint` is a required check on purpose: `images.yml` is path-filtered, and a required check that does not run
blocks every PR that does not touch those paths. Image changes are covered by the `images` run on the PR and by
`verify` after merge to `main`.

## Settings that exist in the web UI only (owner action)
1. Org *Authentication security*: require two-factor authentication for all members.
2. Org *Actions > General*: same SHA-pinning and fork-PR approval policy at org level, so new repos inherit it.
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
