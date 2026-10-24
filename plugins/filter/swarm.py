"""Small filters used by the swarm_app role."""

import re

_KEY = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")


def parse_dotenv(text):
    """Parse KEY=VALUE lines into a dict.

    Blank lines and lines starting with # are ignored; one level of matching
    single or double quotes around the value is stripped. Anything else that
    is not KEY=VALUE is an error, so a typo cannot silently drop a variable.
    """
    result = {}
    for lineno, raw in enumerate(text.splitlines(), start=1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        key, sep, value = line.partition("=")
        key = key.strip()
        if not sep or not _KEY.match(key):
            raise ValueError(f"invalid .env line {lineno}: {raw!r} (expected KEY=VALUE)")
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
            value = value[1:-1]
        result[key] = value
    return result


def env_list(env):
    """Turn {'K': v} into ['K=v', ...] with every value as a string."""
    out = []
    for key, value in sorted(env.items()):
        if isinstance(value, bool):
            value = "true" if value else "false"
        out.append(f"{key}={value}")
    return out


def image_tag(image):
    """'repo/name:tag@sha256:...' -> 'tag' ('' when there is no tag)."""
    ref = image.split("@", 1)[0]
    name, sep, tag = ref.rpartition(":")
    if not sep or "/" in tag:
        return ""
    return tag


def swarm_refs(results, kind):
    """Map registered docker_config/docker_secret loop results to the
    `configs:` / `secrets:` lists docker_swarm_service expects.

    Each result carries the versioned object name the module picked
    (<app>_<name>_vN) and the loop item it was created from.
    """
    refs = []
    for result in results:
        item = result["item"]
        if kind == "config":
            refs.append({"config_name": result["config_name"], "filename": item["target"]})
        elif kind == "secret":
            refs.append({"secret_name": result["secret_name"], "filename": item.get("target", item["name"])})
        else:
            raise ValueError(f"unknown kind {kind!r}")
    return refs


def swarm_publish_arg(port):
    """{'published_port': 8080, 'target_port': 80} -> '--publish-add=published=8080,target=80,protocol=tcp,mode=ingress'"""
    return "--publish-add=published={},target={},protocol={},mode={}".format(
        port["published_port"], port["target_port"],
        port.get("protocol") or "tcp", port.get("mode") or "ingress",
    )


def node_table(nodes):
    """Render verbose docker_swarm_info nodes as aligned text rows."""
    fmt = "{:<18} {:<8} {:<8} {:<8} {:<12} {:<9} {}"
    rows = [fmt.format("HOSTNAME", "ROLE", "STATUS", "AVAIL", "MANAGER", "ENGINE", "LABELS")]
    for node in sorted(nodes, key=lambda n: n["Description"]["Hostname"]):
        manager = node.get("ManagerStatus") or {}
        labels = node["Spec"].get("Labels") or {}
        rows.append(fmt.format(
            node["Description"]["Hostname"],
            node["Spec"]["Role"],
            node["Status"]["State"],
            node["Spec"]["Availability"],
            "Leader" if manager.get("Leader") else manager.get("Reachability", "-"),
            node["Description"].get("Engine", {}).get("EngineVersion", "?"),
            ",".join(f"{k}={v}" for k, v in sorted(labels.items())) or "-",
        ))
    return rows


_REPLICAS = re.compile(r"^(\d+)/(\d+)")


def degraded_services(lines):
    """From `docker service ls --format '{{.Name}} {{.Replicas}}'` lines,
    return the names whose running count is below the desired count."""
    degraded = []
    for line in lines:
        name, _, replicas = line.partition(" ")
        match = _REPLICAS.match(replicas.strip())
        if match and int(match.group(1)) < int(match.group(2)):
            degraded.append(f"{name} ({match.group(0)})")
    return degraded


def app_table(catalog, service_lines):
    """Compare definitions with what runs.

    catalog:       {name: definition dict}
    service_lines: `docker service ls --format '{{.Name}}\t{{.Replicas}}\t{{.Image}}\t{{.Ports}}'`
    """
    running = {}
    for line in service_lines:
        parts = (line.split("\t") + ["", "", "", ""])[:4]
        running[parts[0]] = {"replicas": parts[1], "image": parts[2], "ports": parts[3]}

    fmt = "{:<14} {:<9} {:<26} {:<8} {:<26} {:<9} {}"
    rows = [fmt.format("APP", "STATE", "DEFINED IMAGE", "RUNNING", "RUNNING IMAGE", "STATUS", "PORTS")]
    for name in sorted(set(catalog) | set(running)):
        spec = catalog.get(name) or {}
        live = running.get(name)
        state = spec.get("state", "present") if spec else "-"
        want_image = f"{spec.get('image')}:{spec.get('version')}" if spec else "-"
        want_replicas = int(spec.get("replicas", 1)) if spec else None
        if not spec:
            status = "unmanaged"
        elif state == "absent":
            status = "removed" if not live else "DRIFT"
        elif not live:
            status = "MISSING"
        else:
            run_image = live["image"].split("@", 1)[0]
            match = _REPLICAS.match(live["replicas"])
            healthy = match and match.group(1) == match.group(2)
            if run_image != want_image or not match or int(match.group(2)) != want_replicas:
                status = "DRIFT"
            elif not healthy:
                status = "DEGRADED"
            else:
                status = "in sync"
        rows.append(fmt.format(
            name, state, want_image,
            live["replicas"] if live else "-",
            live["image"].split("@", 1)[0] if live else "-",
            status,
            live["ports"] if live else "",
        ))
    return rows


class FilterModule:
    def filters(self):
        return {
            "parse_dotenv": parse_dotenv,
            "env_list": env_list,
            "image_tag": image_tag,
            "swarm_refs": swarm_refs,
            "swarm_publish_arg": swarm_publish_arg,
            "node_table": node_table,
            "degraded_services": degraded_services,
            "app_table": app_table,
        }
