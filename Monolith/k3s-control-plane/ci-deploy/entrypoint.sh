#!/bin/sh
set -e

if [ -z "${CI_PUBLIC_KEY:-}" ]; then
    echo "ERROR: CI_PUBLIC_KEY environment variable is not set." >&2
    exit 1
fi

# Write authorized_keys with the restricted command wrapper
mkdir -p /home/ci/.ssh
printf 'command="/usr/local/bin/ci-deploy-handler.sh",no-pty,no-port-forwarding,no-X11-forwarding,no-agent-forwarding %s\n' \
    "$CI_PUBLIC_KEY" > /home/ci/.ssh/authorized_keys
chmod 700 /home/ci/.ssh
chmod 600 /home/ci/.ssh/authorized_keys
chown -R ci:ci /home/ci/.ssh

exec /usr/sbin/sshd -D -e
