# HarnessRouter Community Edition on Cloudron: rebuilt from the upstream tag's source on cloudron/base.
#
# Not a repack of upstream's image (python:3.12-slim, Debian): the final stage is cloudron/base, as every
# package here is, and the source is fetched by commit so the build is reproducible. The steps follow upstream's
# own Dockerfile at the same tag (kept for diffing in the workspace, `upstream-Dockerfile-0.37.13`).
#
# AGENT CLIs ARE NOT IN THIS IMAGE. Claude Code and hermes-agent cannot be redistributed in a public
# image (upstream's own licensing note), so upstream's entrypoint installs them on first start into the
# data volume, under their own licences, exactly as if the operator had installed them. Nothing here
# changes that. Starter Kits (licence not yet read) are not built in.
#
# Pins: UPSTREAM_VERSION and HR_COMMIT move together; HR_SKILLS_REF is a commit sha, never `main`.
ARG UPSTREAM_VERSION=0.37.13
ARG HR_COMMIT=558a8bbbd548c57e6b5afb21541993a164a94203
ARG HR_SKILLS_REF=1553417dca0e5e2f9378a1e0ff5ebc260c894cea

FROM ghcr.io/astral-sh/uv:0.13.1@sha256:4a1f3666816dafadd20ceb71eac9a7d56d7ef30279f7d64048519ab901ada336 AS uvbin

# ---- source ---------------------------------------------------------------------------------------------
FROM docker.io/cloudron/base:6.0.1@sha256:7b1e729960c3ca312d26e886917ba89483241bba0219ff292858e10d9d5768ee AS src
ARG HR_COMMIT
WORKDIR /src
RUN git init && git remote add origin https://github.com/HarnessRouter/harnessrouter.git \
 && git fetch --depth 1 origin "${HR_COMMIT}" && git checkout FETCH_HEAD

# ---- console build (the same UI the hosted product runs, edition flag set to self-hosted) ----------------
FROM docker.io/library/node:22.23.4-bookworm-slim@sha256:de170b39439eb0e5a3444ad7d60b015614a381e10fecae2e30ec9e735122f38d AS ui
WORKDIR /ui
# git: the UI depends on a component library straight from its repository.
RUN apt-get update -y && apt-get install -y --no-install-recommends git ca-certificates \
    && rm -rf /var/lib/apt/lists/*
# .npmrc carries legacy-peer-deps, without which npm refuses the tree.
COPY --from=src /src/ui/package.json /src/ui/package-lock.json* /src/ui/.npmrc ./
RUN npm ci --no-audit --no-fund
COPY --from=src /src/ui/ ./
ENV NEXT_TELEMETRY_DISABLED=1 NEXT_PUBLIC_HR_EDITION=selfhost
RUN npm run build

# ---- runtime ---------------------------------------------------------------------------------------------
FROM docker.io/cloudron/base:6.0.1@sha256:7b1e729960c3ca312d26e886917ba89483241bba0219ff292858e10d9d5768ee
ARG UPSTREAM_VERSION
ARG HR_SKILLS_REF
ARG WITH_DOC_PREVIEW=0
ARG WITH_MEDIA=0

ENV DEBIAN_FRONTEND=noninteractive PYTHONUNBUFFERED=1 PIP_NO_CACHE_DIR=1 NEXT_TELEMETRY_DISABLED=1
# The uv-managed CPython carries a PEP 668 marker, which makes a bare `pip install` (upstream's skills installer and
# first-boot installers run them) refuse. Inside a container image the marker protects nothing.
ENV PIP_BREAK_SYSTEM_PACKAGES=1

# tmux: openhands drives the real binary. iptables (and ip6tables): the egress firewall start.sh installs.
# libicu78: the skills' officecli is a .NET binary that aborts without ICU. Upstream's image gets it only as a side
# effect of installing LibreOffice (WITH_DOC_PREVIEW), so a lean build must ask for it.
# tini, setpriv (util-linux), git, curl, bash already come with the base.
RUN apt-get update -y && apt-get install -y --no-install-recommends tmux iptables ca-certificates libicu78 \
    && rm -rf /var/lib/apt/lists/*

# Optional parts that genuinely belong in the image layer. Off by default: the memory and size budget decides.
RUN set -eux; \
    if [ "$WITH_DOC_PREVIEW" = "1" ]; then \
      apt-get update -y && apt-get install -y --no-install-recommends \
        libreoffice-impress libreoffice-writer libreoffice-calc fonts-dejavu-core \
      && rm -rf /var/lib/apt/lists/*; \
    fi; \
    if [ "$WITH_MEDIA" = "1" ]; then \
      apt-get update -y && apt-get install -y --no-install-recommends ffmpeg \
      && rm -rf /var/lib/apt/lists/*; \
    fi

# Node 22 (upstream's floor for pi is 22.19), from the official image by digest. npm comes with it.
COPY --from=ui /usr/local/bin/node /usr/local/bin/node
COPY --from=ui /usr/local/lib/node_modules /usr/local/lib/node_modules
RUN ln -s ../lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm \
 && ln -s ../lib/node_modules/npm/bin/npx-cli.js /usr/local/bin/npx \
 && node --version && npm --version

# Python 3.12, the minor upstream runs on (the base carries 3.14). A pinned uv-managed CPython, and upstream's
# entrypoint hard-codes PY=/usr/local/bin/python3, so that path points straight at it. No venv: a symlink to a
# venv's interpreter ignores the venv (sys.prefix is the base CPython, measured), so the dependencies would not
# import. They go into the interpreter's own site-packages instead, which also keeps `python3 -m venv` (used by
# the first-boot installer) behaving normally.
COPY --from=uvbin /uv /usr/local/bin/uv
ENV UV_PYTHON_INSTALL_DIR=/usr/local/python UV_PYTHON_PREFERENCE=only-managed
RUN uv python install 3.12.15 && ln -s "$(uv python find 3.12.15)" /usr/local/bin/python3 \
 && ln -s "$(dirname "$(uv python find 3.12.15)")/pip3" /usr/local/bin/pip3 \
 && ln -s "$(dirname "$(uv python find 3.12.15)")/pip3" /usr/local/bin/pip \
 && /usr/local/bin/python3 --version
# Cloudron's security advisory of 2026-10-21 asks for pip 26.2.2 or later in any image that carries pip; the
# build fails if the result is older.
RUN /usr/local/bin/python3 -m pip install --no-cache-dir --break-system-packages 'pip>=26.2.2' \
 && /usr/local/bin/python3 -c "from importlib.metadata import version; v=tuple(int(x) for x in version('pip').split('.')[:3]); assert v>=(26,2,2), v; print('pip', version('pip'))" \
 && pip --version

WORKDIR /app
COPY --from=src /src/gateway/requirements.txt /app/gateway/requirements.txt
COPY --from=src /src/runner/requirements.txt  /app/runner/requirements.txt
# The gateway's requirements include hosted-only clients (cloud identity); they are imported lazily and never
# used self-hosted, so they are stripped, as upstream does.
RUN grep -viE "^(azure-|azure_)" /app/gateway/requirements.txt > /app/gateway/req.local.txt \
 && uv pip install --python /usr/local/bin/python3 --break-system-packages -r /app/gateway/req.local.txt \
 && uv pip install --python /usr/local/bin/python3 --break-system-packages -r /app/runner/requirements.txt \
 && test "$(/usr/local/bin/python3 -c 'import sys; print(sys.version_info[:2])')" = "(3, 12)" \
 && /usr/local/bin/python3 -c 'import uvicorn, fastapi; print("python3 ok", uvicorn.__version__)'

# Built-in skills, pinned by commit sha so two builds of one tag ship the same catalogue.
ENV HR_BUILTIN_SKILLS_DIR=/opt/harnessrouter/skills OFFICECLI_RESIDENT_FLUSH=each
COPY --from=src /src/docker/install-skills.sh /tmp/install-skills.sh
RUN chmod +x /tmp/install-skills.sh \
 && WITH_BUILTIN_SKILLS=1 HR_SKILLS_REPO=https://github.com/HarnessRouter/skills.git \
    HR_SKILLS_REF="$HR_SKILLS_REF" HR_SKILLS_DIR=/opt/harnessrouter/skills /tmp/install-skills.sh \
 && rm -f /tmp/install-skills.sh

# Starter Kits are NOT built in (their licence terms are unread). The directory stays so the gateway finds none.
ENV HR_VERSION=${UPSTREAM_VERSION} HR_KITS_DIR=/opt/harnessrouter/kits
RUN mkdir -p /opt/harnessrouter/kits

COPY --from=src /src/gateway/ /app/gateway/
COPY --from=src /src/runner/  /app/runner/
COPY --from=src /src/docker/entrypoint.sh /app/entrypoint.sh
COPY --from=src /src/docker/locks/ /app/locks/
COPY --from=src /src/docker/hr-retention /usr/local/bin/hr-retention
# Apache-2.0 section 4(d): a redistribution carries upstream's NOTICE (and its LICENSE beside it).
COPY --from=src /src/LICENSE /src/NOTICE /app/
RUN chmod +x /app/entrypoint.sh /usr/local/bin/hr-retention

COPY --from=ui /ui/.next/standalone /app/ui/
COPY --from=ui /ui/.next/static     /app/ui/.next/static
COPY --from=ui /ui/public           /app/ui/public

# `agent` is the product's user (gateway and console); every agent process gets its own session uid on top.
# The container starts as root and the entrypoint drops privileges per process (the per-session uid switch
# needs root). Cloudron's root filesystem is READ-ONLY, and upstream's entrypoint writes two paths in it on
# every boot (measured locally): /env and /etc/profile.d/hr-environment.sh. Neither patches upstream: /env is a
# symlink into the data volume (start.sh creates the target) and the profile file a symlink into /run.
RUN useradd -M -u 10001 agent \
 && rm -rf /home/agent && ln -s /app/data/home /home/agent \
 && ln -s /app/data/.hr-env /env \
 && ln -s /app/data /data \
 && rm -rf /var/tmp && ln -s /tmp /var/tmp \
 && rm -f /etc/profile.d/hr-environment.sh && ln -s /run/hr-environment.sh /etc/profile.d/hr-environment.sh \
 && rm -rf /root/.npm /root/.cache \
 && chown -R agent:agent /app/gateway /app/runner /app/ui /app/locks \
 && chmod -R a+rX /opt/harnessrouter

ENV HOME=/home/agent HR_DATA_DIR=/app/data HARNESS_WORKSPACE=/app/data/workspaces
EXPOSE 3000

# `/var/tmp` -> `/tmp`: Cloudron's root is read-only and only /tmp and /run are writable, and upstream's entrypoint chowns
# /tmp, /var/tmp and /dev/shm on every boot (a read-only /var/tmp aborted it: measured on the lab, 2026-10-31).
# `/data` -> `/app/data` is a safety net: a few of upstream's defaults (the auth store, four opt-in backends' venvs)
# are literal /data paths, and /data does not exist on a read-only root. start.sh sets the important ones explicitly.
# start.sh prepares the volume, installs the egress firewall, drops CLOUDRON_* and execs upstream's entrypoint.
COPY start.sh /app/pkg/start.sh
COPY test/containment.sh /app/pkg/test/containment.sh
RUN chmod 0755 /app/pkg/start.sh /app/pkg/test/containment.sh
CMD ["/app/pkg/start.sh"]
