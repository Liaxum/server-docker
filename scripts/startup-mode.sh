#!/usr/bin/env bash
#
# Narrow this clone to the files needed to boot the cluster, or widen it back.
#
#   ./scripts/startup-mode.sh           # startup mode: only the floor stacks
#   ./scripts/startup-mode.sh --full    # everything again
#   ./scripts/startup-mode.sh --list    # print the startup paths
#
# Nothing is deleted from history -- this is git sparse-checkout, so widening
# restores the files without touching the network.
#
# For a fresh machine, skip the full clone entirely:
#
#   git clone --filter=blob:none --sparse <url> server-docker
#   cd server-docker
#   git sparse-checkout set scripts traefik apps/vpn apps/nfs apps/monitor
#
# Cone mode always keeps root files, so README.md and .gitignore come along.

set -euo pipefail

cd -- "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

# The bootstrap floor: what Komodo needs in order to exist. Everything above
# this line -- filebrowser, gitlab, pihole, portfolio, games -- is deployed by
# Komodo itself and is not needed to bring the cluster up.
STARTUP_PATHS=(scripts traefik apps/vpn apps/nfs apps/monitor)

case "${1:-}" in
  --list) printf '%s\n' "${STARTUP_PATHS[@]}"; exit 0 ;;
  --full)
    git sparse-checkout disable
    echo "full checkout restored"
    ;;
  -h|--help)
    awk 'NR>1 && /^#/ { sub(/^# ?/, ""); print; next } NR>1 { exit }' "${BASH_SOURCE[0]}"
    exit 0 ;;
  "")
    git sparse-checkout set "${STARTUP_PATHS[@]}"
    echo "startup mode: ${STARTUP_PATHS[*]}"
    ;;
  *) echo "unknown argument: $1 (try --help)" >&2; exit 1 ;;
esac

git sparse-checkout list 2>/dev/null || true
