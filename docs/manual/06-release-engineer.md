# 06 Release engineer guide

*Read this if you sign releases, rotate keys or hand over the release role.*

Status: **untested on real hardware** (commands taken from the cosign docs; run the dry-run in section 9
before the first real release).

Release policy: every image is signed by CI (keyless). A *release* (tag `vX.Y.Z`) additionally carries a
countersignature by a release engineer's YubiKey. `scripts/verify-release.sh REF --release` requires both.
Fallback if YubiKey signing is unavailable: signed git tag only (section 8). CI then still signs keyless.

## 1 Prerequisites
- YubiKey 5 (PIV applet) or compatible; a second one as backup (PIV keys are not exportable).
- `cosign` of the version in `docker/pins.env` (`COSIGN_RELEASE`), built/downloaded with checksum check.
- Debian: `apt install pcscd libpcsclite1 yubikey-manager`; `systemctl enable --now pcscd`.
- `docker` with buildx, `gh`, and a clone of this repo.

## 2 First-time setup of a token
Use a fresh or reset token. `cosign piv-tool reset` wipes the PIV applet; do not use it on a token with
other PIV credentials.
```
cosign piv-tool set-pin                         # new PIN (6-8 chars); keep the PIN out of shell history
cosign piv-tool set-puk                         # new PUK; store sealed, separate from the token
cosign piv-tool set-management-key --random-management-key   # random key, discarded: no re-provision without reset
cosign piv-tool generate-key --slot signature --pin-policy once --touch-policy always
cosign piv-tool attestation --slot signature    # proves the key was generated on the device; save output
cosign public-key --sk --slot signature > keys/release/<id>.pub
```
`<id>` = short unique name, e.g. `alice-yk1`. Record serial number, date, and the attestation output in the
hand-over log (section 7). `--touch-policy always` means every signature needs a physical touch.

## 3 Publish the public key (key exchange)
1. Open a PR adding `keys/release/<id>.pub` (signed commit; two-person review once a second engineer exists, today CODEOWNERS names one owner).
2. Send the SHA-256 fingerprint (`sha256sum keys/release/<id>.pub`) over a second, independent channel
   (voice/video call or signed mail) to the other maintainers; they compare before approving.
3. Merge. From now on `verify-release.sh --release` accepts signatures of this key.

## 4 Sign a release
```
git tag -s v1.0.0 -m "agl-ci 1.0.0" && git push origin v1.0.0     # CI builds, signs, publishes 1.0.0
scripts/sign-release.sh builder 1.0.0
scripts/sign-release.sh runner  1.0.0
```
The script verifies the CI signature, SBOM and provenance first, signs the digest (PIN + touch), then runs
the full release verification. Key-based signatures are written to the Rekor transparency log as well.

## 5 Re-sign
Signing is idempotent per digest: run `sign-release.sh` again (e.g. after a key rotation, with the new key
in `keys/release/`). Old signatures stay valid until the old key is revoked.

## 6 Rotation, revocation, compromise
- **Rotation**: generate a new key (section 2, new `<id>`), publish (section 3), re-sign active releases,
  then retire the old one: `git mv` its `.pub` out of `keys/release/` and add a `REVOKED.txt` line.
- **Revocation** (lost token, leaving engineer, suspected compromise): add `<id> <date> <reason>` to
  `keys/REVOKED.txt` in a PR (urgent review path), remove the `.pub`, publish a security advisory naming the
  affected digests. Cosign has no CRL: consumers must use the keys file of a current, verified checkout.
  Rekor timestamps show which signatures predate the compromise date.
- **Compromise of the CI identity** (workflow/branch takeover): tighten the identity regexp in
  `scripts/verify-release.sh`, rebuild from a clean commit, re-sign all supported releases.
- Lost PIN: `cosign piv-tool unblock --puk ... --new-PIN ...`. PIN and PUK both lost: token is dead, rotate.

## 7 Hand-over to another release engineer
Checklist, record each step with date and both names in `docs/handover-log.md` (create the file at the first hand-over):
1. New engineer completes sections 1-3 with their own token(s). Nothing is transferred between tokens.
2. Existing engineers review and merge the new public key; confirm the fingerprint out of band.
3. New engineer re-signs all supported releases (section 5) and runs `verify-release.sh --release` on each.
4. Outgoing engineer's key is revoked (section 6), their token PIN/PUK material destroyed or returned.
5. GitHub: update CODEOWNERS, org owners/maintainers, environment reviewers.
6. Test: new engineer signs a throw-away `test-*` image tag; verification passes.

## 8 Fallback: signed git tag only
When no YubiKey is available:
```
git config gpg.format ssh && git config user.signingkey ~/.ssh/id_ed25519.pub
git tag -s v1.0.0 -m "agl-ci 1.0.0"
```
Upload the SSH key to GitHub as a *signing key*. CI refuses to publish a `v*` tag unless GitHub reports the
tag signature as verified (`images.yml`, step `tag`). The released image then carries the CI signature and the
tag signature, but no image-level engineer signature; note this in the release notes.

## 9 Dry-run before the first release
Sign a `test-*` image with the real token, verify with `--release`, then revoke that test key.
