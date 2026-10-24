# Architecture

## Control flow

Everything starts from the operator's machine. `make` picks the environment's
inventory and vault, runs one Ansible playbook, and the playbook does all of its
work against the **bootstrap manager**: the first host under `managers` in that
environment's inventory. Only cluster lifecycle work (prepare, join, firewall,
node removal) touches the other nodes directly.

```mermaid
flowchart LR
    subgraph ctl["Operator machine (Ansible controller)"]
        make["make &lt;target&gt; ENV=dev|uat|prod"]
        repo["Git repo<br/>inventories/&lt;env&gt;/hosts.yml<br/>inventories/&lt;env&gt;/apps/*.yml, *.env<br/>group_vars/all/vault.yml (encrypted)"]
        pass[".vault/&lt;env&gt;.pass<br/>(never committed)"]
        make --> pb["ansible-playbook<br/>playbooks/*.yml"]
        repo --> pb
        pass --> pb
        pb -- "persist version / replicas / state" --> repo
    end

    pb -- "SSH, key per env" --> devc
    pb -- "SSH, key per env" --> uatc
    pb -- "SSH, key per env" --> prodc

    subgraph devc["DEV cluster"]
        dm1["manager-1"]:::mgr --- dw1["worker-1"]
    end
    subgraph uatc["UAT cluster"]
        um1["manager-1"]:::mgr --- uw1["worker-1"] & uw2["worker-2"]
    end
    subgraph prodc["PROD cluster"]
        pm1["manager-1"]:::mgr --- pm2["manager-2"]:::mgr --- pm3["manager-3"]:::mgr
        pm1 --- pw1["worker-1 (zone a)"] & pw2["worker-2 (zone b)"]
    end

    classDef mgr fill:#dbeafe,stroke:#2563eb
```

The three clusters share nothing: each has its own inventory, SSH key, vault
password, Swarm (Raft store, join tokens, CA) and application definitions.

## Inside one cluster

```mermaid
flowchart TB
    user(["Client"]) -- ":8080 (dev/uat), :80 (prod)" --> mesh

    subgraph cluster["Swarm cluster (one environment)"]
        mesh["Ingress routing mesh<br/>(any node accepts the published port)"]
        subgraph net["overlay network apps_net (IPsec-encrypted in uat/prod)"]
            web1["web.1"] & web2["web.2"] & web3["web.n"]
            cache["cache (Redis)<br/>no published port"]
        end
        mesh --> web1 & web2 & web3
        web1 -. "cache:6379" .-> cache

        cfg[("Docker configs<br/>web_index_vN, web_nginx_vN")]
        sec[("Docker secrets<br/>cache_redis_password_vN,<br/>web_api_token_vN")]
        cfg -. "files" .-> web1
        sec -. "/run/secrets/*" .-> cache
        hist[("/var/lib/swarm-automation/history/*.log<br/>on manager-1")]
    end
```

## Where each setting comes from

An application's final spec is merged in this order (later wins):

```
roles/swarm_app/defaults/main.yml   swarm_app_defaults  (rolling update, restart=any, ...)
inventories/<env>/group_vars/all    app_env_defaults    (per-environment rollout speed, placement)
inventories/<env>/apps/<app>.yml    the definition      (image, version, replicas, ports, configs, secrets, healthcheck)
inventories/<env>/apps/<app>.env    plain env vars      (make env-set / env-unset)
playbook overrides                  e.g. VERSION= / REPLICAS= for this run
vault_app_secrets (vault.yml)       secret values, referenced by key only
```

## Rolling update and automatic rollback

```mermaid
sequenceDiagram
    participant Op as make update
    participant A as Ansible (manager-1)
    participant S as Swarm
    Op->>A: APP=web VERSION=1.28-alpine
    A->>S: new configs (web_index_vN+1) + service spec
    loop one task at a time (parallelism 1, start-first)
        S->>S: start new task, wait for healthcheck
        S->>S: stop one old task, watch for `monitor` seconds
    end
    alt every new task healthy
        S-->>A: UpdateStatus = completed
        A->>A: N/N replicas running? smoke test via routing mesh
        A->>Op: write version: "1.28-alpine" to web.yml + history log
    else a new task fails its healthcheck
        S->>S: failure_action = rollback, restore previous spec
        S-->>A: UpdateStatus = rollback_completed
        A->>Op: FAIL — definition file left unchanged, history: auto-rollback
    end
```

Configs and secrets are immutable in Swarm, so a changed value becomes a new
object `<app>_<name>_v<N>`, which the service switches to in the same rolling
update. The current and previous generations are kept, so that
`docker service rollback` still has its files.

## Rename

Swarm has no rename, so `make rename` re-creates the service under the new
name and hands the published ports over:

```mermaid
sequenceDiagram
    participant A as Ansible
    participant S as Swarm
    A->>S: 1. create <new> from <old>'s definition, no published ports
    S-->>A: <new> healthy (N/N)
    A->>S: 2. docker service rm <old>
    A->>A: wait until every node dropped the port's mesh rule
    A->>S: publish the ports on <new>
    A->>A: verify every node routes the port (force re-attach once if not)
    A->>S: delete <old>'s configs and secrets
    A->>S: 3. converge <new> to its full definition (normally a no-op)
    A->>A: 4. rename <old>.yml/.env → <new>.*, move history log
```

The port is unserved between removing `<old>` and `<new>`'s first task
passing its health check on the routing mesh, measured at about 8–10 s on AWS
and 14 s in the lab. Apps without published ports have no gap. Two things that look like
shortcuts but don't work:

* **Starting `<new>` on temporary ports and switching them later:** Swarm
  does not re-program the routing mesh when a service that is already on it
  changes ports. The port went dead until the tasks were force-restarted.
* **Publishing on `<new>` before every node has released `<old>`'s rule:**
  both services program the same iptables rule, so `<old>`'s asynchronous
  cleanup can delete it.
