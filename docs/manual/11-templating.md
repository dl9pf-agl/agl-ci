# 11 Templating and portability

*Read this if you adopt agl-ci in another organisation or on another forge.*

Status: requirement and target structure **decided**; refactor mostly done (`policy/project.env`, `scripts/publish-image.sh`, `scripts/sign-image.sh`, `scripts/verify-release.sh`); remaining items below.

## Requirement
Members must be able to adopt this pipeline for their own repos, and later on GitLab or Forgejo. Therefore
logic and project identity are separated from forge glue.

## Layers
| Layer | Files | Forge-specific? |
|---|---|---|
| Engine | `docker/**`, `scripts/*.sh`, `policy/**`, `docker/pins.env` | No. Needs bash, docker buildx, cosign, grype, python3, curl |
| Project identity | `policy/project.env` (repo, registry, image list), `policy/cve.env`, `policy/vex/`, `keys/` | No |
| Adapter | `.github/workflows/*.yml` | Yes: triggers, permissions, OIDC, environments, artifacts |

Rule for new work: anything beyond "check out, install pinned tools, call a script" belongs in a script, not in
workflow YAML. Names of the repo/registry come from `policy/project.env` or the forge's context, never literals.

## Adopting on GitHub (today)
1. Create a repo from this one (mark agl-ci as a *template repository* once the refactor below is done).
2. Edit `policy/project.env`, `docker/pins.env` (verify every hash), `policy/cve.env`, replace `keys/release/`.
3. Org settings per chapter 05; create environment `release` (chapter 06); set LINT_MODE only for break-glass.
4. Run `lint` then `images` via PR; compare digests; read the manual chapters 03-04 before trusting anything.
5. Layer CI (chapter 13) is forge-independent in its scripts and matrices; its GitLab adapter is not imported yet (chapter 13, "Origin").

`scripts/github-settings.sh` also switches on full-SHA pinning of actions; Dependabot (chapter 12) keeps the pins current.

## Forge-specific pieces and equivalents
| Piece | GitHub | GitLab | Forgejo |
|---|---|---|---|
| Keyless signing | Actions OIDC -> Fulcio | CI `id_tokens` with `sigstore` audience -> Fulcio (documented by Sigstore) | Unverified; check Forgejo Actions OIDC support before promising |
| Build provenance | `attest-build-provenance` | cosign attest in-toto predicate / GitLab provenance | cosign attest in-toto predicate |
| Release approval | environment + required reviewers, GitHub Mobile push | protected environment / manual job with approvals | no direct equivalent verified |
| Code scanning of workflow YAML | zizmor, actionlint | actionlint not applicable; use gitlab-ci linters | actionlint/zizmor partly applicable |

To keep these swappable: signing, attesting and verifying are called from scripts with the identity and issuer
as parameters; the verify policy (`verify-release.sh`) already takes repo from `policy/project.env`. Remaining
GitHub-only literals to remove: the OIDC issuer URL and workflow-path regexp in `verify-release.sh`,
image names in `images.yml` (drive from `IMAGES`). The push/sign blocks already live in scripts.

## Planned refactor (in order)
1. (done) `scripts/publish-image.sh`, `scripts/sign-image.sh` called from the workflow.
2. `images.yml` matrix generated from `IMAGES` in `policy/project.env` (needs ordered builds: builder before runner).
3. Issuer/identity regexp into `policy/project.env`.
4. Mark as template repository; add an adopter checklist chapter from the steps above.
