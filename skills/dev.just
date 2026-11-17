# Development container (podman + Helix + toolchain). Imported by the main justfile.
#
# Adapt: names, uid/gid (the image's non-root user), published ports, volumes.

dev-image := "myproject-dev"
dev-container := "myproject-dev"
dev-dockerfile := "dev.Dockerfile"

# Build the development container
dev-build:
    podman build --tag {{dev-image}} --file {{dev-dockerfile}} .

# Start the development container if not already running
_dev-container-up:
    #!/usr/bin/env bash
    set -euo pipefail

    if podman container exists {{dev-container}}; then
        podman start {{dev-container}} >/dev/null
    else
        # Share the host Helix config (read-only). XDG_CONFIG_HOME is set so
        # Helix finds it regardless of which user/HOME the container runs as.
        host_helix="${XDG_CONFIG_HOME:-$HOME/.config}/helix"
        helix_args=()
        if [ -d "$host_helix" ]; then
            helix_args=(--volume "$host_helix:/config/helix:ro,Z")
        fi

        # --userns=keep-id:uid=,gid= maps YOUR host uid onto the image's
        # non-root user. Find the uid with `id` inside the image.
        # Add a --volume NAME:/path per cache/venv volume, and a --publish
        # per port the host browser must reach.
        podman run --detach \
            --name {{dev-container}} \
            --userns=keep-id:uid=1000,gid=1000 \
            --security-opt=no-new-privileges \
            --cap-drop=all \
            --env HOME=/tmp \
            --env XDG_CONFIG_HOME=/config \
            --volume "$PWD:/workspace:Z" \
            "${helix_args[@]}" \
            --workdir /workspace \
            {{dev-image}} \
            sleep infinity
    fi

# Run "args" in the development container
dev *args: _dev-container-up
    podman exec -it \
        --env TERM=$TERM \
        --env COLORTERM=truecolor \
        --workdir /workspace \
        {{dev-container}} \
        {{args}}

# Run the "helix" editor
hx *args: _dev-container-up
    podman exec -it \
        --env TERM=$TERM \
        --env COLORTERM=truecolor \
        --workdir /workspace \
        {{dev-container}} \
        hx {{args}}

# Launch bash in the development container
dev-shell: _dev-container-up
    podman exec -it \
        --env TERM=$TERM \
        --env COLORTERM=truecolor \
        --workdir /workspace \
        {{dev-container}} \
        bash

# Stop the development container
dev-stop:
    podman stop {{dev-container}}

# Remove the development container entirely (flag changes need this)
dev-clean:
    podman rm --force {{dev-container}}

# Rebuild the development container
dev-rebuild: dev-clean dev-build
