# SPDX-License-Identifier: MIT
# agl-ci runner = builder + docker CLI + GitHub Actions runner (sha256-verified).
# Build args: BUILDER (name of a --build-context, or builder@sha256:...), RUNNER_VERSION, RUNNER_SHA256, SOURCE_DATE_EPOCH,
# version + sha256 of the lint tools (ACTIONLINT_*, ZIZMOR_*, SHELLCHECK_*, the same pins as scripts/install-lint-tools.sh) and of
# the static docker CLI (DOCKER_CLI_*).
ARG BUILDER=builder
FROM ${BUILDER}
ARG RUNNER_VERSION
ARG RUNNER_SHA256
ARG ACTIONLINT_VERSION
ARG ACTIONLINT_SHA256
ARG ZIZMOR_VERSION
ARG ZIZMOR_SHA256
ARG SHELLCHECK_VERSION
ARG SHELLCHECK_SHA256
ARG DOCKER_CLI_VERSION
ARG DOCKER_CLI_SHA256
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
USER 0
RUN apt-get update -qq && apt-get install -y --no-install-recommends curl jq sudo libicu76 libssl3t64 python3-yaml \
 && apt-get clean && rm -rf /var/lib/apt/lists/* /var/log/* /var/cache/ldconfig/aux-cache
# lint tools for repo-lint.yml (so a lint job downloads nothing); each archive is sha256-verified
RUN t=$(mktemp -d) \
 && curl -fsSL -o "$t/al.tgz" "https://github.com/rhysd/actionlint/releases/download/v${ACTIONLINT_VERSION}/actionlint_${ACTIONLINT_VERSION}_linux_amd64.tar.gz" \
 && echo "${ACTIONLINT_SHA256}  $t/al.tgz" | sha256sum -c - && tar -xzf "$t/al.tgz" --no-same-owner -C /usr/local/bin actionlint \
 && curl -fsSL -o "$t/zz.tgz" "https://github.com/zizmorcore/zizmor/releases/download/v${ZIZMOR_VERSION}/zizmor-x86_64-unknown-linux-gnu.tar.gz" \
 && echo "${ZIZMOR_SHA256}  $t/zz.tgz" | sha256sum -c - && tar -xzf "$t/zz.tgz" --no-same-owner -C /usr/local/bin zizmor \
 && curl -fsSL -o "$t/sc.txz" "https://github.com/koalaman/shellcheck/releases/download/v${SHELLCHECK_VERSION}/shellcheck-v${SHELLCHECK_VERSION}.linux.x86_64.tar.xz" \
 && echo "${SHELLCHECK_SHA256}  $t/sc.txz" | sha256sum -c - && tar -xJf "$t/sc.txz" -C "$t" \
 && install -m 0755 "$t/shellcheck-v${SHELLCHECK_VERSION}/shellcheck" /usr/local/bin/shellcheck && rm -rf "$t"
# docker CLI only (no daemon): static release, sha256-verified, built with a current Go
RUN t=$(mktemp -d) \
 && curl -fsSL -o "$t/d.tgz" "https://download.docker.com/linux/static/stable/x86_64/docker-${DOCKER_CLI_VERSION}.tgz" \
 && echo "${DOCKER_CLI_SHA256}  $t/d.tgz" | sha256sum -c - \
 && tar -xzf "$t/d.tgz" --no-same-owner --strip-components=1 -C /usr/local/bin docker/docker && rm -rf "$t"
RUN useradd --create-home --uid 1001 --shell /bin/bash runner && sed -i -E 's/^(runner:[^:]*:)[0-9]*:/\119000:/' /etc/shadow /etc/shadow-
USER 1001
WORKDIR /home/runner/actions-runner
RUN curl -fsSL -o r.tgz "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz" \
 && echo "${RUNNER_SHA256}  r.tgz" | sha256sum -c - && tar xzf r.tgz && rm r.tgz \
 # Node 20 (end of life) is not used by any action we run (all declare node24, docker or composite): drop it. The npm of the
 # remaining Node tree is not used by any action either (they ship their own node_modules) and carries old libraries.
 && rm -rf externals/node20 externals/node20_alpine \
 && rm -rf externals/node*/lib/node_modules/npm externals/node*/bin/npm externals/node*/bin/npx
ENTRYPOINT ["/bin/bash", "-c", "exec ./run.sh --jitconfig \"$JITCONFIG\""]
