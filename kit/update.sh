#!/usr/bin/env bash
# Update this host to the current agl-ci main: pull, then redeploy 2 slots (SLOTS=n to change; POOL is kept from the last deploy).
#   ./kit/update.sh [token-file]    (default: /home/ghrunner/DL9PF-AGL-CI-RUNNER-TOKEN)
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")/.."
git pull --ff-only
SLOTS="${SLOTS:-2}" sudo -E ./kit/deploy.sh "${1:-/home/ghrunner/DL9PF-AGL-CI-RUNNER-TOKEN}"
sudo systemctl restart 'agl-runner@*'   # pick up a changed run-loop.sh
