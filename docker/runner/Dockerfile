# SPDX-License-Identifier: MIT
# agl-ci runner = builder + docker CLI + GitHub Actions runner (sha256-verified).
# Build args: BUILDER (name of a --build-context, or builder@sha256:...), RUNNER_VERSION, RUNNER_SHA256, SOURCE_DATE_EPOCH.
ARG BUILDER=builder
FROM ${BUILDER}
ARG RUNNER_VERSION
ARG RUNNER_SHA256
USER root
RUN apt-get update -qq && apt-get install -y --no-install-recommends curl jq sudo docker-cli libicu76 libssl3t64 \
 && apt-get clean && rm -rf /var/lib/apt/lists/* /var/log/* /var/cache/ldconfig/aux-cache
RUN useradd --create-home --uid 1001 --shell /bin/bash runner && sed -i -E 's/^(runner:[^:]*:)[0-9]*:/\119000:/' /etc/shadow /etc/shadow-
USER runner
WORKDIR /home/runner/actions-runner
RUN curl -fsSL -o r.tgz "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz" \
 && echo "${RUNNER_SHA256}  r.tgz" | sha256sum -c - && tar xzf r.tgz && rm r.tgz
ENTRYPOINT ["/bin/bash", "-c", "exec ./run.sh --jitconfig \"$JITCONFIG\""]
