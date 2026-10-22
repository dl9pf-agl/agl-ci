#!/bin/bash
# SPDX-License-Identifier: MIT
# kas-container starts this image as root and passes the desired host UID/GID via
# USER_ID/GROUP_ID env vars (see `kas-container`'s own docker run invocation) - remap the
# `ci` user to match, so files written into the bind-mounted repo/work dirs are owned by
# the calling host user, not root, then drop privileges and exec kas.
set -e

if [ "$(id -u)" = "0" ]; then
  if [ -n "${USER_ID}" ] && [ "${USER_ID}" != "$(id -u ci)" ]; then
    usermod -o -u "${USER_ID}" ci
  fi
  if [ -n "${GROUP_ID}" ] && [ "${GROUP_ID}" != "$(id -g ci)" ]; then
    groupmod -o -g "${GROUP_ID}" ci
  fi
  chown -R ci:ci /home/ci
  exec runuser -u ci -- kas "$@"
else
  exec kas "$@"
fi
