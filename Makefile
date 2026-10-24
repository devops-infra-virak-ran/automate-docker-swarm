# Docker Swarm automation — management interface.
# Every target is a thin wrapper around an Ansible playbook; run `make help`.
#
#   make <target> ENV=dev|uat|prod [APP=..] [VERSION=..] [REPLICAS=..] [NODE=..] ...
#   ENV=lab targets the local Docker-in-Docker rehearsal lab (make lab-up).

SHELL        := /bin/bash
.DEFAULT_GOAL := help

ENV  ?= dev
ENVS := dev uat prod
ifeq ($(filter $(ENV),$(ENVS) lab),)
$(error ENV must be one of: $(ENVS) lab (got '$(ENV)'))
endif

ifeq ($(ENV),lab)
INVENTORY  := tests/lab/inventory/hosts.yml
LAB_ARGS   := --skip-tags prepare
else
INVENTORY  := inventories/$(ENV)/hosts.yml
endif
VAULT_FILE := inventories/$(ENV)/group_vars/all/vault.yml
VAULT_PASS := .vault/$(ENV).pass
VAULT_ID   := $(ENV)@$(VAULT_PASS)

# Use the project virtualenv created by `make setup`, without activating it.
ifneq ($(wildcard .venv/bin/ansible-playbook),)
export PATH := $(CURDIR)/.venv/bin:$(PATH)
endif

ifeq ($(wildcard collections/ansible_collections/ansible/posix),)
ifeq ($(filter setup deps lab-up lab-down,$(MAKECMDGOALS)),)
$(warning Ansible collections are not installed yet — run: make setup && make deps)
endif
endif

ANSIBLE_PLAYBOOK ?= ansible-playbook
ANSIBLE          ?= ansible
ANSIBLE_VAULT    ?= ansible-vault

# Extra ansible-playbook arguments, e.g. EXTRA="--check --diff" or EXTRA=-vv
EXTRA ?=

VAULT_ARGS := $(if $(wildcard $(VAULT_PASS)),--vault-id $(VAULT_ID),)
PLAY       := $(ANSIBLE_PLAYBOOK) -i $(INVENTORY) $(VAULT_ARGS) $(LAB_ARGS) -e confirm=$(CONFIRM) $(EXTRA)

# $(call require,VAR1 VAR2) — stop with a usage hint if a variable is empty.
require = $(foreach v,$(1),$(if $(strip $($(v))),,$(error $(v) is required: make $@ ENV=$(ENV) $(v)=...)))

# Destructive operations in PROD need CONFIRM=yes (the playbooks check too).
define guard_prod
	@if [ "$(ENV)" = prod ] && [ "$(CONFIRM)" != yes ]; then \
	  echo "Refusing '$@' on PROD without CONFIRM=yes"; exit 1; fi
endef

# An encrypted vault needs its password file.
define check_vault
	@if [ -f $(VAULT_FILE) ] && head -1 $(VAULT_FILE) | grep -q '^\$$ANSIBLE_VAULT' && [ ! -f $(VAULT_PASS) ]; then \
	  echo "$(VAULT_FILE) is encrypted but $(VAULT_PASS) is missing — get it from your password manager."; exit 1; fi
endef

.PHONY: help
help: ## Show this help
	@awk 'BEGIN {FS = ":.*## "; printf "Usage: make <target> ENV=dev|uat|prod [VAR=value ...]\n"} \
	  /^##@/ {printf "\n\033[1m%s\033[0m\n", substr($$0, 5)} \
	  /^[a-zA-Z_-]+:.*## / {printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

##@ Setup
.PHONY: setup deps vault-init vault-edit vault-view lint test allow-ip ping
setup: ## Create .venv with Ansible (run once)
	python3 -m venv .venv
	.venv/bin/pip install --upgrade pip ansible-core

deps: ## Install the Ansible collections this project needs
	ansible-galaxy collection install -r requirements.yml -p collections

vault-init: ## Create .vault/ENV.pass and the encrypted ENV vault (random secrets)
	scripts/vault-init.sh $(ENV)

vault-edit: ## Edit the encrypted ENV vault
	$(check_vault)
	$(ANSIBLE_VAULT) edit --vault-id $(VAULT_ID) $(VAULT_FILE)

vault-view: ## Show the decrypted ENV vault
	$(check_vault)
	$(ANSIBLE_VAULT) view --vault-id $(VAULT_ID) $(VAULT_FILE)

lint: ## Syntax-check every playbook against every environment (+ ansible-lint if installed)
	@for e in $(ENVS); do for p in playbooks/*.yml; do \
	  $(ANSIBLE_PLAYBOOK) -i inventories/$$e/hosts.yml --syntax-check $$p >/dev/null || { echo "FAIL $$e $$p"; exit 1; }; \
	done; echo "syntax ok: $$e"; done
	@if command -v ansible-lint >/dev/null; then ansible-lint playbooks/ roles/; else echo "(ansible-lint not installed, skipped)"; fi

test: lint ## Unit tests for the filter plugins + lint
	python3 -m unittest discover -s tests -p 'test_*.py'

allow-ip: ## Allow your current public IP on ports 22/8080 in the ENV security group [PORTS="22 8080"]
	PORTS="$(or $(PORTS),22 8080)" scripts/allow-my-ip.sh $(ENV)

ping: ## Check SSH + Python on every node in ENV
	$(check_vault)
	$(ANSIBLE) -i $(INVENTORY) $(VAULT_ARGS) swarm_nodes -m ansible.builtin.ping

##@ Cluster
.PHONY: bootstrap prepare cluster-init status nodes node-add node-remove node-drain node-activate
bootstrap: ## Prepare the VMs and create the swarm (prepare + cluster-init)
	$(check_vault)
	$(PLAY) playbooks/site.yml $(if $(SERIAL),-e serial=$(SERIAL),)

prepare: ## Packages, SSH hardening, firewall, Docker (SERIAL=1 on live clusters)
	$(PLAY) playbooks/prepare.yml $(if $(SERIAL),-e serial=$(SERIAL),)

cluster-init: ## Initialise the swarm and join every inventory node
	$(PLAY) playbooks/cluster-init.yml

status: ## Cluster health: quorum, nodes, degraded services
	$(PLAY) playbooks/cluster-status.yml

nodes: ## List swarm nodes
	$(PLAY) playbooks/node-list.yml

node-add: ## Add a node already in the inventory: NODE=<name>
	$(call require,NODE)
	$(PLAY) playbooks/node-add.yml -e node_name=$(NODE)

node-remove: ## Demote, drain and remove a node: NODE=<name>
	$(call require,NODE)
	$(guard_prod)
	$(PLAY) playbooks/node-remove.yml -e node_name=$(NODE)

node-drain: ## Move all tasks off a node for maintenance: NODE=<name>
	$(call require,NODE)
	$(PLAY) playbooks/node-availability.yml -e node_name=$(NODE) -e availability=drain

node-activate: ## Put a drained node back into service: NODE=<name>
	$(call require,NODE)
	$(PLAY) playbooks/node-availability.yml -e node_name=$(NODE) -e availability=active

##@ Applications
.PHONY: deploy list urls update scale rename remove rollback history
deploy: ## Deploy all apps, or one with APP=<name>
	$(check_vault)
	$(PLAY) playbooks/app-deploy.yml $(if $(APP),-e app_name=$(APP),)

list: ## Defined vs running apps, with drift detection
	$(PLAY) playbooks/app-list.yml

urls: ## Show the URL of every app with a published port
	@python3 scripts/urls.py $(ENV)

update: ## Rolling update: APP=<name> VERSION=<tag>
	$(call require,APP VERSION)
	$(check_vault)
	$(PLAY) playbooks/app-update.yml -e app_name=$(APP) -e app_version=$(VERSION)

scale: ## Scale: APP=<name> REPLICAS=<n>
	$(call require,APP REPLICAS)
	$(check_vault)
	$(PLAY) playbooks/app-scale.yml -e app_name=$(APP) -e app_replicas=$(REPLICAS)

rename: ## Rename via controlled re-creation: APP=<old> NEW_NAME=<new>
	$(call require,APP NEW_NAME)
	$(guard_prod)
	$(check_vault)
	$(PLAY) playbooks/app-rename.yml -e app_name=$(APP) -e app_new_name=$(NEW_NAME)

remove: ## Remove an app and its configs/secrets: APP=<name>
	$(call require,APP)
	$(guard_prod)
	$(PLAY) playbooks/app-remove.yml -e app_name=$(APP)

rollback: ## Roll back: APP=<name> [VERSION=<tag>] (no VERSION = Swarm's previous spec)
	$(call require,APP)
	$(guard_prod)
	$(check_vault)
	$(PLAY) playbooks/app-rollback.yml -e app_name=$(APP) $(if $(VERSION),-e app_version=$(VERSION),)

history: ## Deployment history: APP=<name> [LINES=20]
	$(call require,APP)
	$(PLAY) playbooks/app-history.yml -e app_name=$(APP) $(if $(LINES),-e lines=$(LINES),)

##@ Configuration
.PHONY: env-list env-set env-unset configs
export VALUE
env-list: ## Show an app's environment variables: APP=<name>
	$(call require,APP)
	$(PLAY) playbooks/app-env.yml -e app_name=$(APP) -e env_action=list

env-set: ## Set an env var and roll it out: APP=<name> KEY=<NAME> VALUE=<value>
	$(call require,APP KEY)
	$(check_vault)
	$(PLAY) playbooks/app-env.yml -e app_name=$(APP) -e env_action=set -e env_key=$(KEY) $(if $(FORCE),-e force=$(FORCE),) \
	  -e "$$(python3 -c 'import json, os; print(json.dumps({"env_value": os.environ.get("VALUE", "")}))')"

env-unset: ## Remove an env var and roll it out: APP=<name> KEY=<NAME>
	$(call require,APP KEY)
	$(check_vault)
	$(PLAY) playbooks/app-env.yml -e app_name=$(APP) -e env_action=unset -e env_key=$(KEY)

configs: ## List managed Docker configs and secrets (names only)
	$(PLAY) playbooks/config-list.yml

##@ Local lab (Docker-in-Docker, no VMs needed)
.PHONY: lab-up lab-down
lab-up: ## Start 4 local dind "VMs" for rehearsing — then use ENV=lab
	tests/lab/up.sh

lab-down: ## Remove the local lab
	tests/lab/down.sh
