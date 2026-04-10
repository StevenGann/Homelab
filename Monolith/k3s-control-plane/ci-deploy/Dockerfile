FROM alpine:3.21

RUN apk add --no-cache openssh rsync jq findutils

# Dedicated user — no shell login, no password
RUN adduser -D -s /bin/sh ci

# Generate SSH host keys at build time (stable across restarts)
RUN ssh-keygen -A

# Bake in the handler and entrypoint
COPY ci-deploy-handler.sh /usr/local/bin/ci-deploy-handler.sh
COPY entrypoint.sh        /entrypoint.sh
COPY sshd_config          /etc/ssh/sshd_config

RUN chmod +x /usr/local/bin/ci-deploy-handler.sh /entrypoint.sh

EXPOSE 22

ENTRYPOINT ["/entrypoint.sh"]
