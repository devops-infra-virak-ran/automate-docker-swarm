#!/usr/bin/env bash
# Create the per-environment vault password and the encrypted vault file.
#   scripts/vault-init.sh dev
# - .vault/<env>.pass: random password, mode 600, never committed (.gitignore)
# - inventories/<env>/group_vars/all/vault.yml: copied from vault.example.yml,
#   every CHANGE_ME replaced by a random value, then encrypted.
set -euo pipefail

env="${1:?usage: $0 dev|uat|prod}"
case "$env" in dev|uat|prod) ;; *) echo "unknown environment: $env" >&2; exit 1 ;; esac

root="$(cd "$(dirname "$0")/.." && pwd)"
pass="$root/.vault/$env.pass"
vault="$root/inventories/$env/group_vars/all/vault.yml"
example="$root/inventories/$env/vault.example.yml"

mkdir -p "$root/.vault"
chmod 700 "$root/.vault"

if [[ ! -f $pass ]]; then
  (umask 077 && openssl rand -base64 48 > "$pass")
  echo "Created $pass"
  echo "  -> store it in your password manager; without it the $env vault cannot be decrypted."
fi

if [[ -f $vault ]]; then
  echo "$vault already exists — edit it with: make vault-edit ENV=$env"
  exit 0
fi

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
while IFS= read -r line; do
  while [[ $line == *CHANGE_ME* ]]; do
    line="${line/CHANGE_ME/$(openssl rand -hex 16)}"
  done
  printf '%s\n' "$line"
done < "$example" > "$tmp"

ansible-vault encrypt --vault-id "$env@$pass" --output "$vault" "$tmp"
echo "Created encrypted $vault (random values). Commit it; view with: make vault-view ENV=$env"
