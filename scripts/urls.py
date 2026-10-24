#!/usr/bin/env python3
"""Print the URL of every app with a published port in an environment.
  scripts/urls.py dev
Swarm's routing mesh answers on every node, so each node's address is listed.
Node addresses come from ansible_host in inventories/<env>/hosts.yml; apps and
ports from inventories/<env>/apps/<app>.yml (publish: / smoke_check:).
"""
import pathlib
import sys

import yaml


def hosts(group):
    """Yield (name, vars) for every host under an inventory group, recursively."""
    for name, hvars in (group.get("hosts") or {}).items():
        yield name, hvars or {}
    for child in (group.get("children") or {}).values():
        yield from hosts(child or {})


def main():
    env = sys.argv[1] if len(sys.argv) > 1 else "dev"
    if env == "lab":
        sys.exit("The lab publishes no ports to this machine; its apps are only reachable inside the lab network.")
    root = pathlib.Path(__file__).resolve().parent.parent
    inventory = yaml.safe_load((root / f"inventories/{env}/hosts.yml").read_text())
    nodes = {name: v.get("ansible_host", name) for name, v in hosts(inventory.get("all", {}))}
    apps_dir = root / f"inventories/{env}/apps"

    found = False
    for app_file in sorted(apps_dir.glob("*.yml")):
        app = yaml.safe_load(app_file.read_text()) or {}
        if app.get("state", "present") != "present":
            continue
        health = (app.get("smoke_check") or {}).get("path", "/")
        for pub in app.get("publish") or []:
            port = pub.get("published_port")
            if not port:
                continue
            found = True
            print(f"{app_file.stem}  (port {port}, health {health})")
            for name, addr in nodes.items():
                print(f"  {name:<16} http://{addr}:{port}/")
    if not found:
        print(f"No app in {apps_dir} publishes a port.")


if __name__ == "__main__":
    main()
