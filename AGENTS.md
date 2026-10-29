# AGENTS.md

This is `agl-ci`, the only place with CI logic for the AGL layer repos and for the builder and runner images: reusable workflows (`.github/workflows/`), engine scripts (`ci/scripts/`), the build-host kit (`kit/`), image definitions (`docker/`), policy (`policy/`) and the manual (`docs/manual/`, start at `00-index.md`). Skills for working here are in `.claude/skills/`: `agl-ci-hosts-and-pools`, `agl-ci-trust-and-security`, `agl-ci-run-triage`, `agl-ci-mirror-and-cache`, `agl-ci-release-and-pins`, `agl-ci-layer-engine`, `agl-ci-images`, `agl-ci-dev-env`, `kas-operations`, `yocto-bitbake`.

## Commands
- `scripts/lint.sh`: actionlint, zizmor, shellcheck, the matrix test and the job-started hook test. Run it before every pull request. Also run `checkbashisms` and `bash -n` on shell scripts you touch.
- `docker/pins.env` holds the pinned tool versions and hashes; bump them by pull request (manual chapter 03).

## Rules
- The manual is updated in the same commit as the change it describes (`docs/manual`).
- Pull requests from forks and their `ci/build-matrix.yaml` are untrusted input (manual chapter 13, "Trust rules"); the trusted build hosts refuse fork pull requests through the job-started hook of the runner image.
- A new agl-ci commit reaches the layer repos only through their pinned `uses:` line.

## Working rules
- Show the complete commit message and the complete diff before any push or pull request; do not summarise them.
- Before every push: fetch, check that the pull request is still open and whether the branch needs a rebase onto its base; push only then.
- Name pull requests with their repository (`meta-agl#8`, not `#8`): the numbers repeat across repos.
- Rebase-merge only (the ruleset allows nothing else). Only commit or push when asked.
- A push to a pull request cancels its CI run in progress; do not push to a pull request with a cold build running without saying so.
- No links to chat sessions in commit messages or pull request texts; no tokens and no host addresses in committed files.
- Changes under `.github/`, `.claude/` and `ci/` are reviewed by the owner (`.github/CODEOWNERS`).

## AI assistants
AGL tracks AI involvement in contributions. The AGL documentation on AI coding assistants is linked from `ai-coding.md` in meta-agl; follow it for the commit trailer. This file does not restate the policy.
