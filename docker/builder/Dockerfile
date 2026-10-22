# check=skip=InvalidDefaultArgInFrom
# SPDX-License-Identifier: MIT
# agl-ci builder: kas + Yocto host tools + qemu. Reproducible: every input is pinned in docker/pins.env
# and docker/requirements.txt (hashes). Build context = repo root.
ARG BASE_DIGEST
FROM docker.io/library/debian@${BASE_DIGEST}
ARG SNAPSHOT
ARG SOURCE_DATE_EPOCH
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
ENV DEBIAN_FRONTEND=noninteractive LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 PYTHONDONTWRITEBYTECODE=1

# apt from a dated snapshot (not deb.debian.org): same package set on every build.
RUN rm -f /etc/apt/sources.list.d/debian.sources \
 && printf '%s\n' \
  "Types: deb" "URIs: http://snapshot.debian.org/archive/debian/${SNAPSHOT}/" \
  "Suites: trixie trixie-updates" "Components: main" \
  "Signed-By: /usr/share/keyrings/debian-archive-keyring.pgp" "" \
  "Types: deb" "URIs: http://snapshot.debian.org/archive/debian-security/${SNAPSHOT}/" \
  "Suites: trixie-security" "Components: main" \
  "Signed-By: /usr/share/keyrings/debian-archive-keyring.pgp" \
  > /etc/apt/sources.list.d/debian.sources \
 && echo 'Acquire::Check-Valid-Until "false"; Acquire::Retries "5";' > /etc/apt/apt.conf.d/99snapshot

# Yocto build host dependencies (docs.yoctoproject.org system-requirements) + qemu for boot tests.
RUN apt-get update -qq && apt-get install -y --no-install-recommends \
      build-essential chrpath cpio debianutils diffstat diffutils file gawk gcc git \
      iputils-ping libacl1 libcrypt-dev locales lz4 python3 python3-git python3-jinja2 \
      python3-pexpect python3-pip python3-subunit python3-venv python3-websockets socat \
      texinfo unzip wget xz-utils zstd ca-certificates rsync \
      qemu-system-x86 qemu-system-arm qemu-system-misc qemu-utils \
 && echo "en_US.UTF-8 UTF-8" > /etc/locale.gen && locale-gen \
 && echo "dash dash/sh boolean false" | debconf-set-selections && dpkg-reconfigure dash \
 && apt-get clean && rm -rf /var/lib/apt/lists/* /var/log/* /var/cache/ldconfig/aux-cache /var/cache/debconf/*-old /var/lib/dpkg/*-old

# kas + oelint-adv: hash-locked (--require-hashes), in a venv; symlinks in /usr/local/bin survive
# bitbake's PATH pruning.
COPY docker/requirements.txt /tmp/requirements.txt
RUN python3 -m venv /opt/kas \
 && /opt/kas/bin/pip install --no-cache-dir --no-compile --require-hashes --no-deps -r /tmp/requirements.txt \
 && ln -s /opt/kas/bin/kas /opt/kas/bin/kas-container /opt/kas/bin/oelint-adv /usr/local/bin/ \
 && rm /tmp/requirements.txt

RUN useradd --create-home --uid 1000 --shell /bin/bash ci
COPY --chmod=0755 docker/builder/entrypoint.sh /entrypoint.sh

# Pin shadow lastchg (useradd would record the build day).
RUN sed -i -E 's/^(ci:[^:]*:)[0-9]*:/\119000:/' /etc/shadow /etc/shadow-

WORKDIR /home/ci
ENTRYPOINT ["/entrypoint.sh"]
CMD ["--help"]
