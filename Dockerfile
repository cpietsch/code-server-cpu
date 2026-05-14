# syntax=docker/dockerfile:1.6
FROM ubuntu:24.04

ARG USERNAME=dev
ARG USER_UID=1000
ARG USER_GID=1000
ARG NODE_VERSION=22.11.0
ARG PYTHON_VERSION=3.12
ARG TZ=Europe/Berlin
# Build-time only: suppress apt prompts during image build without leaking
# noninteractive mode into the final container's runtime environment.
ARG DEBIAN_FRONTEND=noninteractive

ENV LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    TZ=${TZ}

# ---- Base system + build essentials ----
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl wget gnupg lsb-release \
        git git-lfs openssh-server sudo locales tzdata \
        build-essential pkg-config \
        zsh tmux vim nano htop jq ripgrep fd-find bat unzip zip \
        iputils-ping dnsutils net-tools \
        python${PYTHON_VERSION} python${PYTHON_VERSION}-venv python${PYTHON_VERSION}-dev \
        python3-pip python3-setuptools pipx \
    && ln -sf /usr/bin/python${PYTHON_VERSION} /usr/local/bin/python \
    && ln -sf /usr/bin/python${PYTHON_VERSION} /usr/local/bin/python3 \
    && ln -sf /usr/bin/fdfind /usr/local/bin/fd \
    && ln -sf /usr/bin/batcat /usr/local/bin/bat \
    && rm -rf /var/lib/apt/lists/*

# ---- Node.js via nvm (shared install so root and dev user both get it) ----
ARG NVM_VERSION=v0.40.1
# Optional pinning: if set, the nvm install script is verified against this
# SHA256 before being executed. Leave empty to skip (best-effort install).
ARG NVM_INSTALL_SHA256=
ENV NVM_DIR=/usr/local/nvm
RUN set -eux; \
    mkdir -p "$NVM_DIR"; \
    curl -fsSL "https://raw.githubusercontent.com/nvm-sh/nvm/${NVM_VERSION}/install.sh" \
        -o /tmp/nvm-install.sh; \
    if [ -n "${NVM_INSTALL_SHA256}" ]; then \
        echo "${NVM_INSTALL_SHA256}  /tmp/nvm-install.sh" | sha256sum -c -; \
    fi; \
    bash /tmp/nvm-install.sh; \
    rm /tmp/nvm-install.sh; \
    . "$NVM_DIR/nvm.sh"; \
    nvm install "${NODE_VERSION}"; \
    nvm alias default "${NODE_VERSION}"; \
    nvm use default; \
    # corepack ships with Node; use it for pnpm/yarn so we get current versions
    # on demand instead of legacy Yarn v1 from npm.
    corepack enable; \
    corepack prepare pnpm@latest --activate; \
    corepack prepare yarn@stable --activate; \
    chmod -R a+rwX "$NVM_DIR"; \
    # Symlink node + every binary the active version ships (npm, npx, corepack,
    # pnpm, yarn, ...) into /usr/local/bin so they resolve in any SSH session
    # even before nvm.sh is sourced. Loop instead of hardcoding NODE_VERSION
    # paths so a NODE_VERSION bump doesn't leave dangling symlinks.
    NODE_BIN="$NVM_DIR/versions/node/v${NODE_VERSION}/bin"; \
    for bin in "$NODE_BIN"/*; do \
        ln -sf "$bin" "/usr/local/bin/$(basename "$bin")"; \
    done; \
    # /etc/profile.d/ is bash-only; mirror into zshenv so zsh login sessions
    # also pick up NVM_DIR (needed for `nvm use <other-version>` later).
    printf '%s\n' \
        'export NVM_DIR="/usr/local/nvm"' \
        '[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"' \
        > /etc/profile.d/nvm.sh; \
    mkdir -p /etc/zsh; \
    printf '%s\n' \
        'export NVM_DIR="/usr/local/nvm"' \
        '[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"' \
        >> /etc/zsh/zshenv; \
    node --version; \
    npm --version

# ---- uv (fast Python package manager) ----
# Optional SHA256 pin, same pattern as nvm.
ARG UV_INSTALL_SHA256=
RUN set -eux; \
    curl -fsSL https://astral.sh/uv/install.sh -o /tmp/uv-install.sh; \
    if [ -n "${UV_INSTALL_SHA256}" ]; then \
        echo "${UV_INSTALL_SHA256}  /tmp/uv-install.sh" | sha256sum -c -; \
    fi; \
    UV_INSTALL_DIR=/usr/local/bin sh /tmp/uv-install.sh; \
    rm /tmp/uv-install.sh

# ---- Docker CLI + GitHub CLI (no daemon; talk to dind over TCP) ----
RUN set -eux; \
    install -m 0755 -d /etc/apt/keyrings; \
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc; \
    chmod a+r /etc/apt/keyrings/docker.asc; \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo $VERSION_CODENAME) stable" \
        > /etc/apt/sources.list.d/docker.list; \
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        | gpg --dearmor -o /usr/share/keyrings/githubcli-archive-keyring.gpg; \
    chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg; \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        docker-ce-cli docker-compose-plugin docker-buildx-plugin \
        gh; \
    rm -rf /var/lib/apt/lists/*

# ---- SSH server ----
RUN mkdir -p /var/run/sshd /etc/ssh/sshd_config.d
COPY sshd_dev.conf /etc/ssh/sshd_config.d/10-dev.conf

# ---- User setup ----
# Ubuntu 24.04 ships with a default "ubuntu" user/group at UID/GID 1000.
# Remove whatever currently owns our target UID/GID so we can claim them.
# Note: /home/${USERNAME} is masked at runtime by the devbox-home volume,
# so anything created here under that path (e.g. workspace, .ssh) will be
# hidden on first boot. The entrypoint recreates .ssh; the workspace
# subdirectory is provided by a separate named volume.
RUN set -eux; \
    if existing_user="$(getent passwd ${USER_UID} | cut -d: -f1)" && [ -n "$existing_user" ]; then \
        userdel --remove "$existing_user" || true; \
    fi; \
    if existing_group="$(getent group ${USER_GID} | cut -d: -f1)" && [ -n "$existing_group" ]; then \
        groupdel "$existing_group" || true; \
    fi; \
    groupadd --gid ${USER_GID} ${USERNAME}; \
    useradd --uid ${USER_UID} --gid ${USER_GID} -m -s /bin/zsh ${USERNAME}; \
    echo "${USERNAME} ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/${USERNAME}; \
    chmod 0440 /etc/sudoers.d/${USERNAME}; \
    mkdir -p /home/${USERNAME}/.ssh /home/${USERNAME}/workspace; \
    chown -R ${USERNAME}:${USERNAME} /home/${USERNAME}

# The docker CLI talks to the dind daemon over TCP+TLS (DOCKER_HOST in the
# environment). No local docker socket, no group membership needed.

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

EXPOSE 22
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["/usr/sbin/sshd", "-D", "-e"]
