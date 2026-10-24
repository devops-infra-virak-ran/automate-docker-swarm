#!/usr/bin/env bash
# Local rehearsal lab: 4 Docker-in-Docker containers stand in for VMs
# (lab-manager-1, lab-worker-1..3) on 192.168.99.0/24. Ansible reaches them
# through the docker connection plugin instead of SSH, so the OS-preparation
# roles (apt, sshd, ufw) are skipped; everything Swarm-related runs for real.
# lab-worker-3 is started but not in the inventory: use it for `make node-add`.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
image="${LAB_IMAGE:-docker:27-dind}"

docker network inspect swarmlab >/dev/null 2>&1 \
  || docker network create --subnet 192.168.99.0/24 swarmlab >/dev/null

ip=11
for node in lab-manager-1 lab-worker-1 lab-worker-2 lab-worker-3; do
  if ! docker inspect "$node" >/dev/null 2>&1; then
    docker run -d --privileged --name "$node" --hostname "$node" \
      --network swarmlab --ip "192.168.99.$ip" -e DOCKER_TLS_CERTDIR= "$image" >/dev/null
  fi
  ip=$((ip + 1))
done

for node in lab-manager-1 lab-worker-1 lab-worker-2 lab-worker-3; do
  docker exec "$node" sh -c 'command -v python3 >/dev/null || apk add -q --no-cache python3 py3-docker-py'
  for _ in $(seq 30); do docker exec "$node" docker info >/dev/null 2>&1 && break; sleep 1; done
done

# The lab deploys the DEV application definitions (a private copy, so
# update/scale/rename in the lab never touch inventories/dev/apps).
if [[ ! -d $here/inventory/apps ]]; then
  cp -r "$here/../../inventories/dev/apps" "$here/inventory/apps"
fi
echo "Lab is up. Next: make cluster-init ENV=lab && make deploy ENV=lab"
