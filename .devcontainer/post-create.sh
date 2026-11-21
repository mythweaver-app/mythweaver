#!/usr/bin/env bash
set -euo pipefail

# The Dockerfile seeds vscode ownership for fresh volumes, but Docker never
# re-seeds a volume that already has content, so volumes created by an earlier
# pre-fix build stay root-owned. Repair only those; this is a no-op otherwise.
for dir in /mnt/mise-data /mnt/tokenizer-cache /workspaces/mythweaver/_build /workspaces/mythweaver/deps /workspaces/mythweaver/assets/node_modules; do
  [ -w "$dir" ] || sudo chown vscode:vscode "$dir"
done

mise install
mise exec -- mix local.hex --force
mise exec -- mix local.rebar --force
mise exec -- mix deps.get
mise exec -- bun install --cwd assets
mise exec -- mix setup
