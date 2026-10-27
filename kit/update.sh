#!/usr/bin/env bash
# Update this host to the current agl-ci main: pull, then redeploy 2 slots (SLOTS=n to change; POOL is kept from the last deploy).
#   ./kit/update.sh [token-file]    (without a file the token of the previous deploy is reused)
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")/.."
git pull --ff-only
SLOTS="${SLOTS:-2}" sudo -E ./kit/deploy.sh ${1:+"$1"}
sudo systemctl restart 'agl-runner@*'   # pick up a changed run-loop.sh
