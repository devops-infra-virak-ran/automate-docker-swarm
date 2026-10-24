#!/usr/bin/env bash
# Remove the lab containers, network and the lab's copy of the app definitions.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
docker rm -f lab-manager-1 lab-worker-1 lab-worker-2 lab-worker-3 >/dev/null 2>&1 || true
docker network rm swarmlab >/dev/null 2>&1 || true
rm -rf "$here/inventory/apps"
echo "Lab removed."
