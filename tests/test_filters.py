"""Unit tests for plugins/filter/swarm.py — run with: make test"""

import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "plugins", "filter"))

import swarm  # noqa: E402


class ParseDotenv(unittest.TestCase):
    def test_basic_comments_quotes(self):
        text = "# comment\n\nLOG_LEVEL=debug\nGREETING=\"Hello from DEV\"\nEMPTY=\nURL=http://x/?a=b\n"
        self.assertEqual(
            swarm.parse_dotenv(text),
            {"LOG_LEVEL": "debug", "GREETING": "Hello from DEV", "EMPTY": "", "URL": "http://x/?a=b"},
        )

    def test_rejects_garbage(self):
        with self.assertRaises(ValueError):
            swarm.parse_dotenv("NOT A VALID LINE")
        with self.assertRaises(ValueError):
            swarm.parse_dotenv("1BAD=x")


class EnvList(unittest.TestCase):
    def test_stringifies_and_sorts(self):
        self.assertEqual(
            swarm.env_list({"B": 1, "A": True, "C": "x y"}),
            ["A=true", "B=1", "C=x y"],
        )


class ImageTag(unittest.TestCase):
    def test_tags(self):
        self.assertEqual(swarm.image_tag("nginx:1.28-alpine@sha256:abc"), "1.28-alpine")
        self.assertEqual(swarm.image_tag("registry:5000/team/app:2.0"), "2.0")
        self.assertEqual(swarm.image_tag("registry:5000/team/app"), "")
        self.assertEqual(swarm.image_tag("nginx"), "")


class SwarmRefs(unittest.TestCase):
    def test_configs_and_secrets(self):
        configs = [{"config_name": "web_index_v3", "item": {"name": "index", "target": "/usr/share/nginx/html/index.html"}}]
        secrets = [{"secret_name": "cache_pw_v2", "item": {"name": "redis_password", "vault_key": "k"}}]
        self.assertEqual(
            swarm.swarm_refs(configs, "config"),
            [{"config_name": "web_index_v3", "filename": "/usr/share/nginx/html/index.html"}],
        )
        self.assertEqual(
            swarm.swarm_refs(secrets, "secret"),
            [{"secret_name": "cache_pw_v2", "filename": "redis_password"}],
        )


class PublishArg(unittest.TestCase):
    def test_defaults(self):
        self.assertEqual(
            swarm.swarm_publish_arg({"published_port": 8080, "target_port": 80}),
            "--publish-add=published=8080,target=80,protocol=tcp,mode=ingress",
        )


class DegradedServices(unittest.TestCase):
    def test_detects_short_services(self):
        lines = ["web 4/4", "api 1/3", "job 0/0", "spread 2/3 (max 1 per node)"]
        self.assertEqual(swarm.degraded_services(lines), ["api (1/3)", "spread (2/3)"])


class AppTable(unittest.TestCase):
    def test_statuses(self):
        catalog = {
            "web": {"image": "nginx", "version": "1.28-alpine", "replicas": 2},
            "old": {"image": "nginx", "version": "1", "state": "absent"},
            "new": {"image": "nginx", "version": "1"},
            "slow": {"image": "nginx", "version": "1", "replicas": 3},
        }
        lines = [
            "web\t2/2\tnginx:1.28-alpine@sha256:abc\t*:8080->80/tcp",
            "slow\t1/3\tnginx:1\t",
            "stray\t1/1\tbusybox:1\t",
        ]
        status = {row.split()[0]: row.split()[5] for row in swarm.app_table(catalog, lines)[1:]}
        self.assertEqual(status, {"web": "in", "old": "removed", "new": "MISSING", "slow": "DEGRADED", "stray": "unmanaged"})

    def test_drift_on_version_or_replicas(self):
        catalog = {"web": {"image": "nginx", "version": "1.28-alpine", "replicas": 2}}
        rows = swarm.app_table(catalog, ["web\t6/6\tnginx:1.28-alpine\t"])
        self.assertIn("DRIFT", rows[1])
        rows = swarm.app_table(catalog, ["web\t2/2\tnginx:1.27-alpine\t"])
        self.assertIn("DRIFT", rows[1])


if __name__ == "__main__":
    unittest.main()
