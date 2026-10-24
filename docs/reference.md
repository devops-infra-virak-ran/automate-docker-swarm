# Reference

Everything about the project beyond "how do I run it" (that part is in the
[README](../README.md)). See also the [architecture](architecture.md) and the
[demo script](demo.md).

## How the requirements are covered

| # | Requirement | Where |
|---|---|---|
| 1 | **Environment management**: separate inventories and configs | `inventories/{dev,uat,prod}/` each holds its own `hosts.yml`, `group_vars`, encrypted vault, SSH key and app definitions. Nothing is shared between clusters. |
| 2 | **Cluster management**: init, add/remove nodes, list, status | `make bootstrap`, `cluster-init`, `node-add`, `node-remove`, `node-drain`/`node-activate`, `nodes`, `status` (quorum, not-ready nodes, degraded services) |
| 3 | **Application management**: deploy, list, update, scale, rename, remove | `make deploy`, `list` (with drift detection), `update`, `scale`, `rename` (controlled re-creation), `remove` |
| 4 | **Configuration management**: env vars, Docker configs, secrets | `<app>.env` + `make env-set/env-unset/env-list`; Jinja-rendered Docker configs; secrets from Ansible Vault, mounted as files; `make configs` |
| 5 | **Deployment strategy**: rolling updates, versioning, health checks, rollback | start-first rolling updates, health-gated, `failure_action: rollback`; version tag + labels + history log; `make rollback` (native or pinned) |
| 6 | **Security**: SSH keys, access control, secrets protection | key-only SSH (hardened sshd), per-env keys and vault passwords, ufw allow-list between nodes, operator accounts, encrypted overlay network, PROD `CONFIRM=yes` guard |
| 7 | **Documentation and demo** | [README](../README.md), this reference, [architecture](architecture.md), [demo script](demo.md), a local lab for rehearsal |

Key conditions:

- **Everything goes through Ansible.** No step needs a manual `docker` command.
- **Idempotent.** Re-running any playbook against a converged cluster reports
  `changed=0`, which is tested.
- **Independent environments.** Each one has its own cluster, inventory,
  vault and defaults.
- **Scale, update and rollback are supported.**
- **Rename is a controlled re-creation**, because Swarm has no native rename.
- **Existing VMs are used.** No provisioning, and Docker is left alone if it
  is already installed.
- **Makefile interface.** `make help` lists every target.

---

## Repository layout

```
.
├── Makefile                     # the management interface (make help)
├── ansible.cfg
├── requirements.yml             # community.docker, community.general, ansible.posix
├── inventories/
│   ├── dev/                     # one directory per environment, nothing shared
│   │   ├── hosts.yml            #   managers / workers, swarm_addr, node labels
│   │   ├── group_vars/all/
│   │   │   ├── main.yml         #   env settings: SSH key, firewall, rollout speed, placement
│   │   │   └── vault.yml        #   encrypted secrets (created by make vault-init)
│   │   ├── vault.example.yml    #   template for vault.yml
│   │   └── apps/
│   │       ├── web.yml          #   application definition (source of truth)
│   │       ├── web.env          #   its plain environment variables
│   │       └── cache.yml
│   ├── uat/
│   └── prod/
├── playbooks/                   # one playbook per operation (see table below)
├── roles/
│   ├── common/                  # packages, hostname, SSH hardening, operators, ufw
│   ├── docker/                  # Docker CE install (skipped if present), daemon.json
│   ├── swarm/                   # init, join (as manager/worker), role + label reconcile
│   └── swarm_app/               # catalog, resolve, configs/secrets, deploy, wait, remove, history
├── templates/apps/web/          # Jinja templates rendered into Docker configs
├── plugins/filter/swarm.py      # small helpers (.env parsing, tables, drift)
├── scripts/vault-init.sh
├── tests/
│   ├── test_filters.py          # unit tests (make test)
│   └── lab/                     # Docker-in-Docker rehearsal lab (make lab-up)
└── docs/
    ├── architecture.md
    └── demo.md
```

---

## Prerequisites

**Controller (your machine)**

- Python 3. `make setup` installs `ansible-core` (≥ 2.15, tested with 2.21) into `.venv`, and the Makefile uses it automatically
- `make deps` installs the collections into `./collections`
  (tested with community.docker 5.4)

**VMs**

- Ubuntu 22.04/24.04 or Debian 12, reachable over SSH with a key, and a
  user with passwordless `sudo`
- Each VM's private address goes in `swarm_addr`. Nodes must reach each other
  on 2377/tcp, 7946/tcp+udp and 4789/udp, plus ESP (IP protocol 50) where the
  overlay is encrypted (UAT/PROD). On AWS that means a security group that
  allows these ports *from itself*.
- Published app ports (8080 in DEV/UAT, 80 in PROD) must be open to your
  clients or your load balancer.

---


## Command reference

`ENV=dev|uat|prod` is required context for every target (default `dev`).

| Area | Command | What it does |
|---|---|---|
| Setup | `make deps` | Install the Ansible collections |
| | `make vault-init` / `vault-edit` / `vault-view` | Create, edit or show the environment's encrypted vault |
| | `make ping` | SSH + Python check on every node |
| | `make test` | Syntax-check all playbooks × all environments, ansible-lint, unit tests |
| Cluster | `make bootstrap [SERIAL=1]` | `prepare` + `cluster-init` |
| | `make prepare [SERIAL=1]` | Base packages, hostname, SSH hardening, operators, ufw, Docker |
| | `make cluster-init` | `swarm init` on the first manager, join everyone else, set roles and labels |
| | `make status` | Quorum, node readiness, inventory hosts missing from the swarm, degraded services |
| | `make nodes` | Node table: role, status, availability, manager status, engine, labels |
| | `make node-add NODE=x` | Prepare and join a node already added to `hosts.yml` (opens the firewall on the others) |
| | `make node-remove NODE=x` | Demote, drain, leave, remove (refuses to break quorum) |
| | `make node-drain NODE=x` / `node-activate NODE=x` | Maintenance mode on/off |
| Apps | `make deploy [APP=x]` | Converge one or all apps to their definitions |
| | `make list` | Defined vs running, with status `in sync`, `DRIFT`, `DEGRADED`, `MISSING`, `removed` or `unmanaged` |
| | `make update APP=x VERSION=tag` | Rolling update; on success the version is saved to `x.yml` |
| | `make scale APP=x REPLICAS=n` | Scale; saved to `x.yml` |
| | `make rename APP=x NEW_NAME=y` | Controlled re-creation under a new name (see below) |
| | `make remove APP=x` | Remove the service and its configs/secrets; `x.yml` becomes `state: absent` |
| | `make rollback APP=x [VERSION=tag]` | Swarm's previous spec, or redeploy a pinned version |
| | `make history APP=x` | Deploy log (who, when, what) plus Swarm's task history |
| Config | `make env-list APP=x` | Show the environment variables |
| | `make env-set APP=x KEY=K VALUE=V` | Set one and roll it out (restored if the rollout fails) |
| | `make env-unset APP=x KEY=K` | Remove one and roll it out |
| | `make configs` | Docker configs and secrets in this environment (names only) |

Destructive targets (`node-remove`, `remove`, `rename`, `rollback`) refuse
to run against PROD without `CONFIRM=yes`. The playbooks check this too.
Pass extra Ansible flags with `EXTRA`, for example `EXTRA="--check --diff"` or
`EXTRA=-vv`.

---

## Application definitions

Each file in `inventories/<env>/apps/` is one Swarm service, named after the
file. It is the source of truth: `update`, `scale`, `rollback`, `remove` and
`rename` write their result back to it, so the repo always matches the
cluster. Commit after each change.

```yaml
# inventories/dev/apps/web.yml
state: present                 # absent = removed and kept removed by `make deploy`
image: nginx
version: "1.27-alpine"         # always quoted: 1.10 unquoted would become 1.1
replicas: 2
publish:
  - published_port: 8080
    target_port: 80
configs:                       # rendered from templates/apps/<template>
  - name: index
    template: web/index.html.j2
    target: /usr/share/nginx/html/index.html
secrets:                       # value from vault_app_secrets[vault_key]
  - name: api_token            #   mounted at /run/secrets/api_token
    vault_key: web_api_token
healthcheck:
  test: ["CMD-SHELL", "wget -qO- http://127.0.0.1/healthz >/dev/null || exit 1"]
  interval: 5s
  retries: 3
resources:
  limits: { cpus: 0.25, memory: 64M }
smoke_check: { port: 8080, path: /healthz }   # checked through the routing mesh
# Optional: command, args, placement, update_config, rollback_config,
#           restart_config, stop_grace_period
```

Settings are merged in this order, later winning:
`roles/swarm_app/defaults` → `app_env_defaults` in the environment's
`group_vars` → the app file → `<app>.env` → the operation's override. That is
how PROD gets slower rollouts and worker-only, zone-spread placement without
repeating it in every app.

## Configuration and secrets

| Kind | Lives in | Reaches the container as | Change it with |
|---|---|---|---|
| Plain env vars | `apps/<app>.env` (committed) | environment variables (`APP_ENV` and `APP_VERSION` are added automatically) | `make env-set` / `env-unset` |
| Config files | `templates/apps/<app>/*.j2` (committed) | Docker config → read-only file | edit the template, `make deploy APP=x` |
| Secrets | `group_vars/all/vault.yml` (AES-256 encrypted) | Docker secret → `/run/secrets/<name>` (tmpfs, never in `docker inspect`) | `make vault-edit`, then `make deploy APP=x` |

Configs and secrets are immutable in Swarm. Every change creates a new
version `<app>_<name>_vN`, the service switches to it in a normal rolling
update, and the previous version is kept for rollback. `make env-set` refuses
names that look like credentials (`*PASSWORD*`, `*TOKEN*`, `*SECRET*`, ...).
Those belong in the vault.

## Deployment strategy

- **Rolling update.** One task at a time (`parallelism: 1`), the new task
  starts before the old one stops (`start-first`), and each new task is
  watched for `monitor` seconds. DEV takes 2 s between tasks with a 20 s
  watch, PROD 15 s with a 45 s watch.
- **Health checks.** Swarm only counts a task as running once its
  `healthcheck` passes. After the rollout Ansible waits until N/N replicas
  run, then calls `smoke_check` through the routing mesh.
- **Automatic rollback.** `failure_action: rollback`: if a new task fails its
  health check, Swarm restores the previous version by itself. The playbook
  then fails with a clear message, logs `action=auto-rollback`, and leaves
  the definition file unchanged.
- **Manual rollback.** `make rollback APP=x` uses Swarm's stored previous
  spec. `make rollback APP=x VERSION=tag` redeploys a known-good tag. Swarm keeps
  only one previous spec and clears it after an automatic rollback, so use the
  `VERSION` form then. `make history` lists the versions deployed before.
- **Versioning.** The image tag in `version:` (in git), the label
  `io.swarm-automation.version` on the service and containers, and an
  append-only log on the first manager (`make history`).
- **Restart policy is `any`, not `on-failure`.** A container that exits
  cleanly (for example on SIGTERM during a node reboot) would otherwise never
  be restarted, and the service would silently sit at 0/N.

Measured on real VMs (replicas on two hosts, probe inside the VPC): a rolling
update, an auto-rolled-back update and two rollbacks dropped **0 of about
2,100** requests. Measure from inside the network: a probe across a slow
internet link reports timeouts that have nothing to do with Swarm.

## Rename

Swarm cannot rename a service, so `make rename APP=web NEW_NAME=frontend`
re-creates it:

1. Start `frontend` from `web`'s definition **without** its published ports
   and wait until it is healthy.
2. Remove `web`, wait until every node has released the port in the routing
   mesh, publish the port on `frontend`, and verify that every node routes it
   (self-healing once if not). Then delete `web`'s configs and secrets.
3. Converge `frontend` to the full definition.
4. Rename `web.yml`/`web.env` to `frontend.*` and carry over the history log.

The published port is unserved from step 2 until `frontend`'s first task
passes its health check, about 8–10 s on AWS and 14 s in the lab. Services without published
ports have no gap. A failed rename can be re-run with the same command and
continues where it stopped. Other services that call `web` by DNS name need
updating. [Why it is done this way](architecture.md#rename).

## Security

| Concern | Measure |
|---|---|
| SSH | Keys only: `PasswordAuthentication no`, `KbdInteractiveAuthentication no`, `PermitRootLogin no`, `MaxAuthTries 3`, validated with `sshd -t` before reload. Ansible pins host keys (`accept-new`). |
| Environment isolation | A separate SSH key (`ansible_ssh_private_key_file`) and vault password (`.vault/<env>.pass`) per environment, so a DEV key cannot reach PROD |
| Access control | Membership of the `docker` group (root-equivalent) only for operators listed in `swarm_operators`, with exclusive `authorized_keys`. PROD destructive operations need `CONFIRM=yes`. Every change is logged with the operator's name. |
| Network | ufw: deny inbound by default, SSH from `ssh_allowed_cidrs`, Swarm ports only from the other nodes' addresses. UAT/PROD overlay traffic is IPsec-encrypted. Redis has no published port. |
| Secrets | Ansible Vault (AES-256), `no_log` on every task that handles values, Docker secrets on tmpfs (never env vars or `docker inspect`), env-var names that look like credentials are refused, `.vault/` is gitignored |
| Control plane | Swarm's mutual TLS between nodes. Join tokens are never printed (`no_log`). Optional `swarm_autolock` encrypts the Raft log at rest. |
| Host | Unattended security upgrades, Docker log rotation (10 MB × 3) |

Published service ports bypass ufw (Docker manages its own iptables chains),
so restrict them in the cloud security group or behind a load balancer.

## Testing

```bash
make test         # syntax-check every playbook × every env, ansible-lint (production profile), unit tests
make lab-up       # local Docker-in-Docker cluster
make bootstrap ENV=lab && make deploy ENV=lab && make list ENV=lab
make lab-down
```

What was verified, and how:

| Area | How it was tested | Result |
|---|---|---|
| Real VMs (AWS, 3 × t3.small Ubuntu 24.04, Docker 29.9) | `bootstrap` from fresh VMs over SSH, then deploy, update, failing update (auto-rollback), pinned and native rollback, rename (including a resumed one), scale, `node-add`, `node-remove`, `status`, and a switch to the IPsec-encrypted overlay | all pass. Bootstrap takes about 3 min and a re-run is `changed=0`. Password SSH refused. Cross-host web→Redis traffic over the encrypted overlay works through ufw. **0 failed requests out of about 2,100** (probe inside the VPC) during the updates and rollbacks. Rename gap about 8–10 s. |
| Local lab (Docker-in-Docker, 3–4 nodes) | Every Makefile target, including promote and demote via the inventory, `node-drain`/`activate` and drift detection | all pass; re-runs `changed=0` |
| Static | `make test`: syntax × 3 envs, ansible-lint (production profile), unit tests | pass |

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `make ping` times out | Your IP changed: run `make allow-ip ENV=<env>`. Or the public IP changed after a stop/start: update `ansible_host` in the inventory. Or ufw blocks 22 |
| Node stuck joining | 2377/7946/4789 (and ESP for encrypted overlays) are not open *between* the nodes. Check `swarm_addr` is the private IP. |
| `version is a QUOTED string` | Write `version: "1.10"`, not `version: 1.10` |
| `missing: <key>` from the vault | Add the key to the vault (`make vault-edit`) or fix `vault_key` |
| `update ended in state 'rollback_completed'` | The new version failed its health check and Swarm rolled back. Run `make history APP=x`, then `docker service ps x --no-trunc` on a manager. |
| Replicas never start | The failure message lists the most recent task errors (image pull, mount, placement). |
| `apps_net exists with encrypted=...` | `overlay_encrypted` was changed after apps were deployed. Remove the apps, run `docker network rm apps_net`, then deploy. |

## Limitations

- **Debian-family hosts only** (apt, ufw).
- **One application = one Swarm service.** Multi-service stacks are modelled
  as several apps on the shared overlay network.
- **`make update`/`scale` act on the definition plus one change.** If someone
  edited the cluster by hand, the next operation converges it back to the
  definition (`make list` shows `DRIFT` beforehand).
- **The deploy history lives on the first manager.** It is an audit aid, not
  a backup; git history of `apps/` is the durable record.
