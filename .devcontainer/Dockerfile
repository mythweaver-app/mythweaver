FROM mcr.microsoft.com/devcontainers/base:noble

# inotify-tools: inotifywait, required by the file_system dep's default Linux backend.
# libncurses-dev/libssl-dev: link targets for the precompiled OTP builds mise fetches.
# postgresql-client: psql for ad-hoc database inspection.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      inotify-tools \
      libncurses-dev \
      libssl-dev \
      postgresql-client \
 && apt-get clean && rm -rf /var/lib/apt/lists/*

# Docker seeds a fresh named volume from whatever the image has at the mount
# point, so these directories must exist and be vscode-owned here or the
# volumes come up root:root and unwritable by remoteUser. Seeding still applies
# to the three paths later covered by the workspace bind mount.
RUN mkdir -p \
      /mnt/mise-data \
      /mnt/tokenizer-cache \
      /workspaces/mythweaver/_build \
      /workspaces/mythweaver/deps \
      /workspaces/mythweaver/assets/node_modules \
 && chown -R vscode:vscode \
      /mnt/mise-data \
      /mnt/tokenizer-cache \
      /workspaces/mythweaver
