#!/usr/bin/env bash
# Allow this machine's current public IP through the environment's AWS
# security group, replacing the IP this operator allowed before.
#   scripts/allow-my-ip.sh dev            # ports 22 and 8080
#   PORTS="22" OPERATOR=alice scripts/allow-my-ip.sh dev
# Reads aws_security_group_id / aws_region from inventories/<env>/group_vars/all/main.yml.
# Each operator's rules are tagged "operator:<name>" (default: $USER@hostname), and
# only rules with your own tag are replaced — teammates' IPs are never touched.
set -euo pipefail

env="${1:?usage: $0 dev|uat|prod}"
case "$env" in dev|uat|prod) ;; *) echo "unknown environment: $env" >&2; exit 1 ;; esac

root="$(cd "$(dirname "$0")/.." && pwd)"
vars="$root/inventories/$env/group_vars/all/main.yml"
ports="${PORTS:-22 8080}"
operator="${OPERATOR:-${USER:-$(id -un)}@$(hostname -s)}"
tag="operator:${operator//[^a-zA-Z0-9._@-]/-}"

# Plain "key: value" lookup — enough for these two scalars, no yq needed.
var() { awk -F': *' -v k="$1" '$1 == k { gsub(/["'\'' ]|#.*/, "", $2); print $2; exit }' "$vars"; }
sg="$(var aws_security_group_id)"
region="$(var aws_region)"
if [[ -z $sg || -z $region ]]; then
  echo "Set aws_security_group_id and aws_region in $vars first." >&2
  exit 1
fi

my_ip="$(curl -fsS --max-time 10 https://checkip.amazonaws.com | tr -d '[:space:]')"
[[ $my_ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "could not detect public IP (got '$my_ip')" >&2; exit 1; }
new="$my_ip/32"
echo "Security group $sg ($region): allowing $new on ports $ports as $tag"

for port in $ports; do
  # One "<cidr> <description>" line per rule on this port.
  rules="$(aws ec2 describe-security-groups --region "$region" --group-ids "$sg" \
    --query "SecurityGroups[0].IpPermissions[?IpProtocol=='tcp' && FromPort==\`$port\` && ToPort==\`$port\`].IpRanges[].[CidrIp,Description]" \
    --output text)"

  already=false
  while read -r cidr desc; do
    [[ -n ${cidr:-} ]] || continue
    if [[ $cidr == "$new" ]]; then already=true; continue; fi
    [[ $desc == "$tag" ]] || continue
    aws ec2 revoke-security-group-ingress --region "$region" --group-id "$sg" \
      --ip-permissions "IpProtocol=tcp,FromPort=$port,ToPort=$port,IpRanges=[{CidrIp=$cidr}]" >/dev/null
    echo "  port $port: removed your old $cidr"
  done <<< "$rules"

  if $already; then
    echo "  port $port: $new already allowed"
  else
    aws ec2 authorize-security-group-ingress --region "$region" --group-id "$sg" \
      --ip-permissions "IpProtocol=tcp,FromPort=$port,ToPort=$port,IpRanges=[{CidrIp=$new,Description=$tag}]" >/dev/null
    echo "  port $port: added $new"
  fi
done
