#!/usr/bin/env bash
set -euo pipefail

USERNAME="${USERNAME:-dev}"

# --- 1. Wait for dind to finish generating client certs ---
# dind writes /certs/client/{ca,cert,key}.pem on first boot. If we don't wait,
# the dev user lands in a shell where `docker ps` fails with a TLS error.
if [ -n "${DOCKER_CERT_PATH:-}" ]; then
    echo "entrypoint: waiting for dind client certs at ${DOCKER_CERT_PATH}..."
    for i in $(seq 1 60); do
        if [ -f "${DOCKER_CERT_PATH}/ca.pem" ] \
           && [ -f "${DOCKER_CERT_PATH}/cert.pem" ] \
           && [ -f "${DOCKER_CERT_PATH}/key.pem" ]; then
            echo "entrypoint: dind certs present."
            break
        fi
        sleep 1
    done
    if [ ! -f "${DOCKER_CERT_PATH}/ca.pem" ]; then
        echo "entrypoint: WARNING — dind certs never appeared. \`docker\` inside the container will fail until dind is healthy." >&2
    fi
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
