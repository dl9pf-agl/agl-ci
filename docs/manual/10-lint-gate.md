# 10 Lint and security gate

Status: **in use**. `lint` is the required check of the `main` ruleset of agl-ci; local runs verified (clean tree passes; a deliberately
bad `pull_request_target` workflow with expression injection fails in `enforce`, passes in `report`).

## What runs (`scripts/lint.sh`, workflow `lint.yml`)
| Tool | Checks | Config |
|---|---|---|
| actionlint | workflow syntax, expression types, runner labels, shellcheck of `run:` blocks | `.github/actionlint.yaml` (our self-hosted labels) |
| zizmor | template injection, excessive permissions, dangerous triggers, unpinned `uses:`, credential persistence | inline `# zizmor: ignore[rule] reason` (e.g. `self-repository` in images.yml: actionlint 1.7.12 does not accept the new `$/` syntax) or `.github/zizmor.yml` |
| shellcheck | `scripts/*.sh`, `kit/*.sh`, `ci/scripts/*.sh`, builder entrypoint | inline `# shellcheck disable=SCxxxx` with reason |
| matrix test | `ci/scripts/_matrix_test.py`: the validation of untrusted `build-matrix.yaml` files (chapter 13) | needs PyYAML |


Tools are installed by `scripts/install-lint-tools.sh` from pinned releases with sha256 (`docker/pins.env`);
no third-party actions. actionlint hash matches the upstream checksum file; zizmor/shellcheck publish none,
so their hashes are trust-on-first-download. `GH_TOKEN` (read-only) enables zizmor's online audits.

## Gate wiring
- `lint.yml` runs on every PR and push to `main` (no path filter).
- `images.yml` calls it as job `lint`; every build job `needs: lint`, so nothing is built or published
  when lint fails (tags included).
- Scorecard and CodeQL are separate scheduled checks (planned, chapter 07).
- Branch ruleset: `lint` is required (live on agl-ci since the ruleset of 2026-10-22).
- Other repos use the same tools through the reusable workflow `repo-lint.yml` (agl-ucb calls it; chapter 05, "Pools").

## Run locally
```
scripts/install-lint-tools.sh && export PATH=$HOME/.local/bin:$PATH
scripts/lint.sh                 # enforce
LINT_MODE=report scripts/lint.sh
```

## Recovery path (lint blocks you)
Order of preference; every step leaves a trace.
1. **Real finding**: fix it (the fix PR runs the new lint and is itself gated).
2. **False positive / accepted risk**: add a reviewed ignore with reason (config file or inline comment) in a PR.
3. **Tool problem** (bad release, download failure): bump or revert the pin in `docker/pins.env` in a PR.
4. **Break-glass**: repo variable `LINT_MODE=report` (Settings > Secrets and variables > Actions > Variables;
   admin only, audit-logged). The run summary shows "LINT RUNNING IN report MODE" and a warning annotation.
   Reset to `enforce` (delete the variable) right after the fix lands. A one-off alternative is
   `workflow_dispatch` input `mode=report` on `lint.yml`.
5. **Admin bypass** of the branch ruleset is the last resort and must be noted in the hand-over log.

## Test run
The PR that adds the gate is the test run. To rehearse the recovery path: set `LINT_MODE=report`, push a
workflow with a known finding, check the warning shows, delete the variable, check the same push fails.
