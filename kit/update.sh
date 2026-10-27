#!/usr/bin/env bash
# Update this host to the current agl-ci main: pull, then redeploy. Slots, paths, limits, pool and token are kept from the
# last deploy (a host without a stored SLOTS gets 2); give them in the environment to change them.
#   ./kit/update.sh [token-file]    (without a file the token of the previous deploy is reused)
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")/.."
git pull --ff-only
stored="$(sudo sed -n 's/^SLOTS=//p' /etc/agl-runner/runner.env 2>/dev/null || true)"
SLOTS="${SLOTS:-${stored:-2}}" sudo -E ./kit/deploy.sh ${1:+"$1"}
sudo systemctl restart 'agl-runner@*'   # pick up a changed run-loop.sh
