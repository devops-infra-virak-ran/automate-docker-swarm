# Live demo script (about 15 minutes)

Run this against DEV, or against the local lab: replace `ENV=dev` with
`ENV=lab` and run `make lab-up` first. Keep a second terminal running a
traffic probe so the audience can watch for errors during updates:

```bash
# terminal 2 — one line per request; any FAIL is visible immediately
NODE=<any node IP>   # lab: run it inside a node: docker exec lab-worker-1 sh -c '...'
while true; do curl -s -m1 http://$NODE:8080/info || echo FAIL; echo; sleep 0.5; done
```

Before the demo: `make lab-down && make lab-up` (or a clean DEV cluster), and
`git stash` any leftover changes under `inventories/dev/apps/`.

---

## 1. Environments (criterion 1)

```bash
tree -L 3 inventories                 # three independent environments
diff inventories/dev/group_vars/all/main.yml inventories/prod/group_vars/all/main.yml
head -1 inventories/prod/group_vars/all/vault.yml   # $ANSIBLE_VAULT;1.2;AES256;prod
make help
```

Points to make: separate hosts, SSH keys, vault passwords and rollout
policies. PROD has 3 managers for quorum, a slower rollout, apps only on
workers spread across zones, and an encrypted overlay.

## 2. Cluster management (criterion 2)

```bash
make bootstrap ENV=dev        # prepare + swarm init/join (lab: cluster only)
make bootstrap ENV=dev        # again: changed=0, i.e. idempotent
make status ENV=dev           # quorum OK, nodes ready, services
make nodes ENV=dev
```

Adding and removing a node (lab: uncomment `lab-worker-3` in
`tests/lab/inventory/hosts.yml`):

```bash
make node-add    ENV=dev NODE=dev-worker-2
make node-drain  ENV=dev NODE=dev-worker-1    # tasks move away
make node-activate ENV=dev NODE=dev-worker-1
make node-remove ENV=dev NODE=dev-worker-2    # demote → drain → leave → rm
```

## 3. Applications (criterion 3)

```bash
make deploy ENV=dev
make list   ENV=dev                            # in sync
curl http://$NODE:8080/info                    # "replica" changes per request: load balancing
make scale  ENV=dev APP=web REPLICAS=4
git diff inventories/dev/apps/web.yml          # replicas: 4 written back
make rename ENV=dev APP=web NEW_NAME=frontend  # controlled re-creation
make list   ENV=dev
make rename ENV=dev APP=frontend NEW_NAME=web  # and back
make remove ENV=dev APP=cache && make list ENV=dev   # cache: removed
```

## 4. Configuration (criterion 4)

```bash
make env-list ENV=dev APP=web
make env-set  ENV=dev APP=web KEY=GREETING VALUE="Hello class"   # rolling update, no errors in terminal 2
curl http://$NODE:8080/info                                      # greeting changed
make env-set  ENV=dev APP=web KEY=DB_PASSWORD VALUE=x            # refused: belongs in the vault
make configs  ENV=dev                                            # versioned configs/secrets, names only
make vault-view ENV=dev
```

Secrets are files, not env vars. On the node that runs the cache:

```bash
docker exec <cache container> ls -l /run/secrets      # redis_password
docker service inspect cache | grep -i pass           # nothing: values never in the spec
```

## 5. Deployment strategy (criterion 5)

```bash
make update   ENV=dev APP=web VERSION=1.28-alpine   # terminal 2: versions alternate, then all 1.28, no FAIL
make history  ENV=dev APP=web
```

Then a broken release. The health check fails on purpose, Swarm rolls back on
its own, and the playbook reports it:

```bash
make env-set  ENV=dev APP=web KEY=FORCE_UNHEALTHY VALUE=true
#  -> FAILED: update ended in state 'rollback_completed' … web.env was restored
make history  ENV=dev APP=web    # action=auto-rollback recorded
make list     ENV=dev            # still in sync on the old spec
```

Manual rollback. Use the pinned form first: Swarm clears its stored previous
spec after an automatic rollback, so the native form has nothing to return to
at this point.

```bash
make rollback ENV=dev APP=web VERSION=1.27-alpine  # redeploy a known version (from make history)
make rollback ENV=dev APP=web                      # Swarm-native: straight back to the previous spec (1.28)
git diff inventories/dev/apps/web.yml              # version written back each time
```

## 6. Security (criterion 6)

```bash
make rollback ENV=prod APP=web                     # refused without CONFIRM=yes
ssh -o PubkeyAuthentication=no ubuntu@$NODE        # Permission denied (publickey)
ssh ubuntu@$NODE 'sudo ufw status; sudo sshd -T | grep -E "passwordauth|permitroot"'
cat .gitignore                                     # .vault/ never committed
```

## 7. Wrap-up (criterion 7)

Open the requirement table in [reference.md](reference.md) and the
[architecture diagram](architecture.md), and run `make test`.
