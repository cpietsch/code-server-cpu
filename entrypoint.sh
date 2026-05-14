#!/usr/bin/env bash
set -euo pipefail

USERNAME="${USERNAME:-dev}"

# --- 1. Wait for dind to finish generating client certs ---
# dind writes /certs/client/{ca,cert,key}.pem on first boot. If we don't wait,
# the dev user lands in a shell where `docker ps` fails with a TLS error.
# We fail hard if certs never appear: a container that boots into a broken
# `docker` is worse than a clear restart loop the operator can see in logs.
CERT_WAIT_TIMEOUT="${CERT_WAIT_TIMEOUT:-60}"
if [ -n "${DOCKER_CERT_PATH:-}" ]; then
    echo "entrypoint: waiting up to ${CERT_WAIT_TIMEOUT}s for dind client certs at ${DOCKER_CERT_PATH}..."
    if ! timeout "${CERT_WAIT_TIMEOUT}" sh -c '
        until [ -f "$1/ca.pem" ] && [ -f "$1/cert.pem" ] && [ -f "$1/key.pem" ]; do
            sleep 1
        done
    ' _ "${DOCKER_CERT_PATH}"; then
        echo "entrypoint: ERROR — dind certs never appeared at ${DOCKER_CERT_PATH}. Aborting so the orchestrator restarts us." >&2
        exit 1
    fi
    echo "entrypoint: dind certs present."
fi

# --- 2. Seed authorized_keys from the SSH_AUTHORIZED_KEYS env var ---
SSH_DIR="/home/${USERNAME}/.ssh"
mkdir -p "${SSH_DIR}"
if [ -n "${SSH_AUTHORIZED_KEYS:-}" ]; then
    printf '%s\n' "${SSH_AUTHORIZED_KEYS}" > "${SSH_DIR}/authorized_keys"
fi
chown -R "${USERNAME}:${USERNAME}" "${SSH_DIR}"
chmod 700 "${SSH_DIR}"
[ -f "${SSH_DIR}/authorized_keys" ] && chmod 600 "${SSH_DIR}/authorized_keys"

# --- 3. SSH host keys (persisted in the sshhostkeys volume) ---
ssh-keygen -A

# --- 4. Export DOCKER_HOST / DOCKER_TLS_VERIFY / DOCKER_CERT_PATH to the
#        dev user's shells. sshd resets most env vars on login, so we inject
#        them via /etc/profile.d (bash) and /etc/zsh/zshenv (zsh).
cat > /etc/profile.d/docker-client.sh <<EOF
export DOCKER_HOST="${DOCKER_HOST:-}"
export DOCKER_TLS_VERIFY="${DOCKER_TLS_VERIFY:-}"
export DOCKER_CERT_PATH="${DOCKER_CERT_PATH:-}"
EOF
chmod 0644 /etc/profile.d/docker-client.sh

if ! grep -q 'profile.d/docker-client.sh' /etc/zsh/zshenv 2>/dev/null; then
    echo '[ -r /etc/profile.d/docker-client.sh ] && . /etc/profile.d/docker-client.sh' >> /etc/zsh/zshenv
fi

# --- 5. Hand over to the CMD (sshd -D -e) ---
exec "$@"
