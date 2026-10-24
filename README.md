# Docker Swarm Automation with Ansible

Set up and manage Docker Swarm clusters for DEV, UAT and PROD on existing
Linux VMs, using `make` commands.

More detail: [reference](docs/reference.md) · [architecture](docs/architecture.md) · [demo script](docs/demo.md)

## Requirements

- On your machine: Python 3 with `venv` (`sudo apt install python3-venv` if `make setup` fails)
- VMs: Ubuntu 22.04/24.04, SSH key access, a user with `sudo`
- The VMs must reach each other on ports 2377/tcp, 7946/tcp+udp, 4789/udp
  (plus ESP for UAT/PROD)

### Windows

Ansible does not run on Windows itself — use WSL2 and do everything in the Ubuntu terminal:

```powershell
wsl --install -d Ubuntu      # PowerShell as Administrator, then reboot
```

```bash
sudo apt update && sudo apt install -y make python3-venv git unzip
curl -sSo awscliv2.zip https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip && unzip -q awscliv2.zip && sudo ./aws/install   # only for make allow-ip
git clone <repo-url> ~/docker-swarm-automation   # inside ~, NOT /mnt/c/... (permissions break there)
cp /mnt/c/Users/<you>/Downloads/swarm-dev ~/.ssh/ && chmod 600 ~/.ssh/swarm-dev
```

Then follow the steps below from that folder.

## How to run

```bash
# 1. Install Ansible into .venv (once), then its collections
make setup
make deps

# 2. Put your VM IPs in the inventory (and the SSH key path in group_vars)
#    inventories/dev/hosts.yml
#    inventories/dev/group_vars/all/main.yml
make allow-ip ENV=dev   # AWS: let your current IP through the security group
make ping ENV=dev

# 3. Create the encrypted secrets file (keep .vault/dev.pass safe, don't commit it)
make vault-init ENV=dev

# 4. Install Docker and create the swarm
make bootstrap ENV=dev

# 5. Deploy the apps
make deploy ENV=dev
make list ENV=dev
make urls ENV=dev       # where to open each app
curl http://<any-node-ip>:8080/info
```

Use `ENV=uat` or `ENV=prod` for the other environments.

## Common commands

```bash
make status   ENV=dev                              # cluster health
make nodes    ENV=dev                              # list nodes
make update   ENV=dev APP=web VERSION=1.28-alpine  # rolling update
make scale    ENV=dev APP=web REPLICAS=3
make rollback ENV=dev APP=web VERSION=1.27-alpine
make rename   ENV=dev APP=web NEW_NAME=frontend
make remove   ENV=dev APP=web
make env-set  ENV=dev APP=web KEY=LOG_LEVEL VALUE=info
make cluster-destroy ENV=dev CONFIRM=yes           # remove swarm + apps, keep VMs (rebuild: bootstrap + deploy)
make help                                          # every command
```

In PROD, `remove`, `rename`, `rollback` and `node-remove` also need `CONFIRM=yes`.

## Try it without VMs

```bash
make lab-up                  # 4 local Docker containers act as VMs
make bootstrap ENV=lab
make deploy ENV=lab
make lab-down                # remove them
```
# automate-docker-swarm
