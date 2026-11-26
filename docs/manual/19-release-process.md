# 19 Release process (AGL images)

*Read this if you cut a release of the AGL images, run the download server, or want to check a downloaded release.*

A release is a set of images (several machines, several images) that were built from one frozen set of sources, signed by the CI,
countersigned by a release engineer, and offered for download. This chapter describes what runs, in which repository, and how a user
checks the result. It was rehearsed with the codename `releasetest` (versions 0.0.1 to 0.0.3); the last one went through completely.

Status marks: **[rehearsed]** ran for real in `releasetest_0.0.3`; **[offline]** covered by the unit tests only; **[not tested]**.

## 1 The picture

```
agl-ucb:   scripts/prepare-release.sh  ->  kas/releases/pins_<branch>_<version>.yml  (PR, merge)
           tag <branch>_<version> on the merge commit (admins only)  --------------------+
                                                                                         v
agl-ci release.yml (called from agl-ucb, pinned by commit):
  matrix   (hosted)   check tag and pins file, list the images of tier "release"
  build    (pool)     one job per image, on ANY host, in parallel: kas build with provenance,
                      collect the files into THAT host's staging area
  attest   (hosted)   check each kas statement against the pins file, attest each image's sums file,
                      sign the top-level SHA256SUMS   [the only job with id-token: write]
  publish  (hosted)   create the GitHub release of the tag with the signed files   [the only job with contents: write]

build hosts:  <CACHE_DIR>/staging/release/<branch>/<version>/...    (unsigned, public, says so)
                                      | rsync pull, every 5 minutes (all hosts merged)
download server cron:  pull + fetch the signed asset + agl-ucb checkout (engineer signatures)
                       -> promote.sh verifies everything -> release/<branch>/<version>/
engineer:  signs SHA256SUMS (YubiKey), commits kas/releases/<tag>.SHA256SUMS.<id>.sig to agl-ucb
```
**Design rules** (decided by the owner): one combined release per tag; the pins file lists *all* known repos (23 today), so a release is
reproducible from the tag alone; images are built **in parallel on different hosts and combined on the download server**; the job that
signs cannot write to the repository and the job that writes cannot sign; releases are immutable; every image has its own
folder `<repo>/<machine>/<target>/` (decision 2026-11-26; it replaces the AGL/Yocto layout `<machine>/deploy/images/<machine>/`, in
which images of one machine shared the kernel files and the vulnscout report).

## 2 Names and files

| What | Where |
|---|---|
| tag | agl-ucb `<branch>_<version>`, e.g. `vimba_22.0.2`; regex `^[a-z]+_[0-9]+\.[0-9]+\.[0-9]+$`; rehearsal `releasetest_0.0.3` |
| pins file | agl-ucb `kas/releases/pins_<branch>_<version>.yml`: every repo of every fragment, one commit each; the release job copies it over `kas/pins.yml` in its throw-away tree |
| engineer signature | agl-ucb `kas/releases/<branch>_<version>.SHA256SUMS.<id>.sig` (one file per engineer, added after the tag) |
| image files | `<repo>/<machine>/<target>/`: `<target>-<machine>.*` (own files) plus the kernel and boot files of the machine (`*Image-<machine>.bin`, `*Image`, `*.efi`, `*.efi.stub`, `*.dtb`) |
| per image | `<target>-<machine>.kas.yml` (the flattened kas file, chapter 13), `<target>.provenance.json` (kas statement), `<target>.SHA256SUMS` (hash of every file of that image), `<target>.slsa.intoto.bundle` (attestation of the sums file) |
| per release | `SHA256SUMS` (hashes of all sums files, statements, bundles, the pins file), `SHA256SUMS.bundle` (its CI signature), `pins_<branch>_<version>.yml` |
| after promotion | `SHA256SUMS.<id>.sig` (engineer signatures), `PROMOTED` (when and by what) |

The file list of an image is a first guess; the SDK and the OCI archives of the builder and runner images are **not** collected yet (phase 2).
Every image folder has its own copy of the kernel and boot files, so two images of one machine may have different kernels (the
older layout refused that; found by `releasetest_0.0.1`).

## 3 Preparing a release (agl-ucb) [rehearsed]

1. `scripts/prepare-release.sh <branch> <version>` (needs kas 5.5, git, python3 with PyYAML, network). It resolves every repo of all 41 fragments
   to a commit (`kas dump --resolve-refs`) and writes the pins file. It refuses a working tree of agl-ucb with uncommitted changes, a repo declared two ways by
   different fragments, a pin of `kas/pins.yml` that kas did not honour, and any commit that is not 40 hex; it warns about repos that `kas/pins.yml` does not
   pin (they get the branch tip of now) and about `${AUTOREV}` recipes. A `dirty` repo in the *build* is refused later, by the attest job (section 4).
2. Review the file, commit it, open a PR, merge it (lint is the gate). `${AUTOREV}` recipes must be pinned in the layers first (meta-agl-devel#13
   was such a case): a floating recipe makes the same commit build different sources on different days.
3. Tag the **merge commit** (annotated tag, only repository admins can create it: ruleset "release tags" on `refs/tags/*_*.*.*`) and push it.
   The tag starts `.github/workflows/release.yml` of agl-ucb, which calls the reusable workflow of agl-ci pinned by commit.

A version is used once. A failed run is not repeated under the same tag: the GitHub release of a tag exists once, and a half-collected
image on a build host would be refused (`already collected`). Take the next version; the rehearsal burned 0.0.1 and 0.0.2 this way.

## 4 What the workflow does (agl-ci `release.yml`)

| Job | Runs on | Permissions | Work |
|---|---|---|---|
| matrix | GitHub-hosted | contents: read | checks that the tag is `<branch>_<version>` in agl-ucb and that its pins file exists; copies the pins file over `kas/pins.yml`; checks out the layers at the pinned commits (builder image, verified); lists the images whose tiers contain `release` from **all** layers; refuses an empty release |
| build (one per image) | `agl-pr` pool, any host | contents: read, **no id-token** | `build.sh` with `AGL_RELEASE=1`: `kas build --provenance mode=min --target <t>`; then `release-collect.sh` in a container on the sidecar's Docker daemon (as root, the cache directory is not reachable from the runner) copies the image files into this host's `staging/release/<branch>/<version>/`, writes `<target>.SHA256SUMS`, and the job uploads only the two small files (sums, statement) as an artifact |
| attest | GitHub-hosted (input `attest_runs_on`, a dedicated node later) | contents: read, **id-token: write** | `release-attest.sh`: checks each statement against the pins file (`release-check.py`: 40-hex commits, pins honoured, no dirty repo), attests each sums file (`cosign attest-blob --type https://slsa.dev/provenance/v1`), writes and signs the top-level `SHA256SUMS`, verifies every signature right after making it; uploads the signed files as an artifact |
| publish | GitHub-hosted | **contents: write**, no id-token | downloads the signed files, `gh release create <tag>` with `release-signed.tar.gz`, `SHA256SUMS` and `SHA256SUMS.bundle` as assets |

`mode=min` matters: `mode=max` writes the values of the environment passthrough (mirror URL, hash-server address) into a public statement.
The caller in agl-ucb grants `permissions: { contents: write, id-token: write }` (the ceiling; a called workflow cannot have more). The builds of
one release land on whatever host has a free slot; nothing in the workflow depends on the host. All of this **[rehearsed]**.

## 5 The download server [rehearsed]

`kit/release/run.sh`, called from `/etc/cron.d/agl-release` every five minutes (`flock`; log `/var/log/agl-release.log`; settings
`/etc/agl-release/promote.env`, see `kit/release/promote.env.example`):

1. `kit/mirror/pull-sync.sh` with `AREAS=staging` and `SOURCES` = the rsync daemon of **every build host** (`BUILD_RSYNC`, space separated). The
   daemon (`kit/mirror/rsyncd.sh`) offers `staging/` read-only; the pulls merge the images of all hosts into one tree. A host that is also the
   download server (the mirror host builds too) fills the same tree directly. Dotfiles never travel.
2. `git pull --ff-only` of the agl-ucb checkout (`RELEASE_UCB_DIR`): the engineer signatures are files there.
3. `kit/release/promote.sh` for every staged `<branch>/<version>`; it is idempotent and cheap while it waits:
   - fetch `release-signed.tar.gz` of the GitHub release (when `SHA256SUMS` is not in the tree yet) and unpack it; a tar with a link or a path
     outside the tree is refused; not published yet means *waiting*;
   - **CI signature** of `SHA256SUMS`: keyless identity `^https://github.com/dl9pf-agl/agl-ci/\.github/workflows/release\.yml@[0-9a-f]{40}$`, issuer
     `https://token.actions.githubusercontent.com`, repository `dl9pf-agl/agl-ucb`, ref `refs/tags/<tag>`;
   - **engineer signatures**: files in agl-ucb checked against `keys/release/<id>.pub` minus `REVOKED.txt`; fewer than `RELEASE_MIN_SIGNATURES` means *waiting*;
   - every file named by the signed sums is there (a build host not pulled yet means *waiting*), then `sha256sum -c` of the top level and of every
     image, no symlink, no file that nobody lists, every image attestation verifies;
   - then it **copies** the tree to `release/<branch>/<version>/` (atomic rename), adds the engineer signatures and `PROMOTED`.
   A wrong hash, signature or file is a failure (non-zero exit, one log line), never a promotion.
4. `kit/release/run.sh cleanup` (daily) removes the **staging copy** of a promoted release after `RELEASE_STAGING_KEEP_DAYS` (7) and adds an exclude line
   to `release-done.txt` so that the pull does not fetch it again. The build hosts keep their own copy; remove it by hand when no longer needed. **[offline]** (the first real cleanup is seven days after the first promotion).

`RELEASE_PROMOTE=manual` runs every check and reports but does not promote; an engineer then runs `kit/release/promote.sh <branch> <version>`
**[offline]**. nginx offers `/` (a static start page, `kit/mirror/index.html`), `/release/` and `/staging/` with an index; `dl`, `sstate` and `git`
stay without one. Staging is public and **not verified**; `staging/release/STAGING.txt` says so.

## 6 The release engineer's step

After the run is green and the GitHub release exists (about 20 minutes with a warm cache):

```bash
tag=vimba_22.0.2
gh release download "$tag" --repo dl9pf-agl/agl-ucb --pattern 'SHA256SUMS*'
cosign verify-blob --bundle SHA256SUMS.bundle SHA256SUMS \
  --certificate-identity-regexp '^https://github.com/dl9pf-agl/agl-ci/\.github/workflows/release\.yml@[0-9a-f]{40}$' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --certificate-github-workflow-repository dl9pf-agl/agl-ucb --certificate-github-workflow-ref "refs/tags/$tag"
cosign sign-blob --sk --output-signature "kas/releases/$tag.SHA256SUMS.<id>.sig" SHA256SUMS      # YubiKey, see chapter 06
```
Then open a PR adding that one file to agl-ucb and merge it. Within five minutes the cron pulls it, counts the signature and promotes. With a
second engineer, `RELEASE_MIN_SIGNATURES=2` makes both signatures necessary. The hardware step with a real YubiKey is **[not tested]** (the
rehearsal used a throw-away key with `--key` and `--tlog-upload=false`; chapter 06, section 9 is the dry run to do before the first real release).

## 7 Checking a downloaded release (users)

In `release/<branch>/<version>/`:
```bash
sha256sum -c SHA256SUMS                                      # all sums files, bundles and the pins file
cosign verify-blob --bundle SHA256SUMS.bundle SHA256SUMS \
  --certificate-identity-regexp '^https://github.com/dl9pf-agl/agl-ci/\.github/workflows/release\.yml@[0-9a-f]{40}$' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --certificate-github-workflow-repository dl9pf-agl/agl-ucb --certificate-github-workflow-ref refs/tags/<branch>_<version>
cosign verify-blob --key keys/release/<id>.pub --signature SHA256SUMS.<id>.sig --insecure-ignore-tlog=true SHA256SUMS   # engineer
cd <repo>/<machine>/<target>
sha256sum -c <target>.SHA256SUMS                             # the image files
cosign verify-blob-attestation --type https://slsa.dev/provenance/v1 --bundle <target>.slsa.intoto.bundle <the same certificate flags> <target>.SHA256SUMS
```
`verify-blob*` is for files; `verify-attestation` is for container images. The attestation says: this sums file was produced by that kas build with
those pinned repositories (the kas statement lists every repo and commit and embeds the pins file).

## 8 Security properties

| An attacker holds | Can he publish a bad release? |
|---|---|
| a compromised build host or build step | can put files into staging (public, visible, unverified); `promote` refuses them: the CI and engineer signatures name exact hashes. Build jobs have no `id-token`, so they cannot sign |
| a stolen engineer key | cannot promote content that the CI did not build and sign |
| write access to agl-ucb without tag rights | cannot create a release tag; a signature file he adds does not verify |
| the `publish` job (`contents: write`) | can replace release assets, but cannot make a valid CI signature (no `id-token`); the tar is unsigned by design, every file in it is checked against the signed sums |
| the `attest` job (`id-token: write`) | could sign wrong sums; it runs only on a tag, from the pinned agl-ci commit, and checks each statement before signing |
| access to the download server | can change the release tree; `PROMOTED` and the signed top level let anyone detect a changed file |

**Limits** (honest list): repository admins can delete or move release tags (GitHub cannot split create from delete for bypass actors), so
immutability rests on the signatures and `promote`; the shared cache and the privileged sidecar are what keep the build below **SLSA Build L3**: the
reachable level is **L2** (signed provenance from a hosted platform; read against the v1.0 requirement pages: v1.2 is current and was not read, check it before
quoting a level). L3 would additionally need a signing secret unreachable by build steps (partly done), every provenance field generated by the platform,
one VM per release build, and a read-only verified cache with a reproducible-build check. Staging shows unverified files publicly on purpose.

## 9 Failures seen in the rehearsal (and what they mean)

| Message or symptom | Cause | Action |
|---|---|---|
| a build job passed but its files are not where the others are | the images of a release are on different hosts | not an error: the server merges them; with only one host in the pull sources, missing files mean *waiting* |
| `promote: …: no signed files yet (the release asset is not published)` | the run is not finished, or `publish` failed | wait; look at the run; a second run for the same tag cannot create the release again |
| `CI signature ok, waiting for engineer signatures (0 of N)` | normal until the signature file is in agl-ucb `master` and pulled | section 6 |
| `waiting for N listed files (a build host not pulled yet?)` | a build host's staging has not arrived | check `BUILD_RSYNC` and that every build host runs `kit/mirror/rsyncd.sh` with the `staging` mount |
| `FAIL SHA256SUMS does not verify` / `… does not verify` | a file changed after collection, or a wrong bundle | do not promote; compare with the build host's copy; build a new version |
| `promote: cosign not found` in every cron run | cron has `PATH=/usr/bin:/bin`; `run.sh` adds `/usr/local/bin` | install cosign there or extend `PATH` in `promote.env` |

## 10 Setting up a download server (checklist)

0. The tree of the server is `/srv/agl-permanent` (`RELEASE_ROOT` and `MIRROR_ROOT`): published, permanent data (`dl`, `sstate`, `git`, `release`, `staging`,
   `nightly`). It is not the cache of a builder (`/srv/agl-cache`, `CACHE_DIR`), which is working storage that can be rebuilt; the two are different directories, and
   the prune cron of a builder (`kit/builder.cron`) must never run on the server.
1. `MIRROR_ROOT=/srv/agl-permanent kit/mirror/run.sh` (nginx, mounts `dl`, `sstate`, `git`, `staging`, `release`, `nightly`, the start page); `kit/mirror/rsyncd.sh` on every build host (bind to the private address,
   allow the server only; it mounts `staging` and `nightly` when the directories exist: create them before starting).
2. `cosign` (checksum-verified, version of `docker/pins.env`), `jq`, `curl`, `tar`, `rsync`, `flock`, `git`; a read-only clone of agl-ucb (`RELEASE_UCB_DIR`).
3. `/etc/agl-release/promote.env` (from `kit/release/promote.env.example`) and the engineers' public keys (`RELEASE_KEYS_DIR`, `REVOKED.txt` next to it).
4. `/etc/cron.d/agl-server` from `kit/server.cron` (release, nightly, the pull of `dl`/`sstate`/`git`, the refresh of the git mirrors; `kit/release/run.sh` reads the settings from `promote.env`, so no address is in the cron file).
5. Check: `kit/release/run.sh` once by hand, `/var/log/agl-release.log`, `curl -I http://localhost:8080/release/`.

The tag ruleset in agl-ucb (only admins create `*_*.*.*` tags) and the permission ceiling of the caller (`contents: write, id-token: write`) are repository settings
([12 Repository hardening](12-repo-hardening.md)).

## 11 Not done yet

OCI archives of the builder and runner images as release assets; the SDK; hash-equivalence snapshots; a dedicated signing node (`attest_runs_on`); SLSA L3 items;
the real YubiKey run; a second engineer (`RELEASE_MIN_SIGNATURES=2`); removal of a release; and the review of the per-image file list.
