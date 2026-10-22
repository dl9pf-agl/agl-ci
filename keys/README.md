# Release engineer public keys

- `release/<id>.pub`: active cosign public keys (PEM) of release engineers. One file per YubiKey.
- `REVOKED.txt`: `<id> <date> <reason>` per line. A key listed here is ignored by `verify-release.sh --release`.
- Changes to this directory need two-person review (CODEOWNERS) and a signed commit.
See `docs/manual/06-release-engineer.md`.
