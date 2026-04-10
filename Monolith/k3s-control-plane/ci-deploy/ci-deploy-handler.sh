#!/bin/sh
# Restricted SSH command handler for the CI deploy key.
# Invoked automatically by sshd via the command= directive in authorized_keys.
# Only the operations below are permitted — everything else is rejected.

IMAGES_ROOT="/images"

case "$SSH_ORIGINAL_COMMAND" in
    rsync\ --server*)
        # Allow rsync in server mode (used by the CI rsync client to upload files)
        exec rsync --server "$@"
        ;;
    "update-manifest node "*)
        MANIFEST="${SSH_ORIGINAL_COMMAND#update-manifest node }"
        echo "$MANIFEST" > "$IMAGES_ROOT/node/manifest.json"
        ;;
    "update-symlink node "*)
        IMG="${SSH_ORIGINAL_COMMAND#update-symlink node }"
        ln -sf "$IMG" "$IMAGES_ROOT/node/rpi-node-latest.img.zst"
        ;;
    prune-node-images)
        # Keep the 3 most recent .img.zst files; delete older ones
        ls -t "$IMAGES_ROOT"/node/*.img.zst 2>/dev/null | tail -n +4 | xargs -r rm -f
        ;;
    *)
        echo "Forbidden: $SSH_ORIGINAL_COMMAND" >&2
        exit 1
        ;;
esac
