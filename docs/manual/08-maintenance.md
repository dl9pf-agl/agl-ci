# 08 Maintenance

Status: **planned**.

## Bump pins
Edit `docker/pins.env` / regenerate `docker/requirements.txt` (`pip-compile --generate-hashes`), open a PR.
CI builds twice and compares; merge only if green. Weekly schedule re-runs the build as a reproducibility
canary (same commit, same digest expected).

## Incidents
Compromised action/dependency: revert pin, rebuild, re-sign, advisory. Broken reproducibility: download both
artifacts of the failed run, diff layers (see chapter 03).
