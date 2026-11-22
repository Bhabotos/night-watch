"""Offline regression tests for tests/e2e/grafana_panels_check.py and the provisioned dashboards.

They need neither Grafana nor credentials. Run from the repo root:

    python -I -m unittest discover -s tests/e2e -p "test_*.py" -v

Guards the Night Watch dashboards: the community dashboard (Node Exporter Full, grafana.com 1860) whose
targets inherit the panel datasource and use a datasource variable, panels nested in collapsed rows, and the
Three-Tier App - Production dashboard's requirements (6+ panels, 3+ visualization types, one row per tier).
"""

import importlib.util
import json
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DASHBOARDS = ROOT / "monitoring" / "grafana" / "dashboards"
spec = importlib.util.spec_from_file_location("grafana_panels_check", ROOT / "tests" / "e2e" / "grafana_panels_check.py")
checker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checker)  # importing must not require GRAFANA_ADMIN_* credentials

REQUIRED = {
    "app-tasks": "Application (Tasks API)",
    "host-vm": "Host (Docker VM)",
    "postgres": "PostgreSQL",
    "logs": "Logs (Loki)",
    "rYdddlPWk": "Node Exporter Full",
    "three-tier-production": "Three-Tier App – Production",
}


def load_all() -> dict[str, dict]:
    boards = {}
    for path in sorted(DASHBOARDS.rglob("*.json")):
        board = json.loads(path.read_text(encoding="utf-8"))
        boards[board["uid"]] = board
    return boards


def fake_lookup(selector, label):
    data = {
        ("job", "node_uname_info"): ["node", "other"],
        ("nodename", 'node_uname_info{job="node"}'): ["docker-desktop"],
        ("instance", 'node_uname_info{job="node", nodename="docker-desktop"}'): ["node-exporter:9100"],
    }
    return data.get((label, selector), [])


class IterPanels(unittest.TestCase):
    def test_includes_panels_nested_in_rows(self):
        tree = [{"type": "row", "panels": [{"type": "stat", "title": "inner"}]}, {"type": "stat", "title": "outer"}]
        self.assertEqual([p.get("title") for p in checker.iter_panels(tree)], [None, "inner", "outer"])


class DatasourceResolution(unittest.TestCase):
    def test_target_inherits_panel_datasource(self):
        panel = {"type": "prometheus", "uid": "prometheus"}
        self.assertEqual(checker.resolve_datasource(None, panel, {}), panel)

    def test_variable_uid_is_resolved(self):
        ref = {"type": "prometheus", "uid": "${ds_prometheus}"}
        self.assertEqual(checker.resolve_datasource(ref, None, {"ds_prometheus": "prometheus"}),
                         {"type": "prometheus", "uid": "prometheus"})

    def test_type_is_looked_up_when_missing(self):
        self.assertEqual(checker.resolve_datasource({"uid": "loki"}, None, {}, lambda uid: "loki"),
                         {"type": "loki", "uid": "loki"})

    def test_no_datasource_anywhere(self):
        self.assertIsNone(checker.resolve_datasource(None, None, {}))


class VariableValues(unittest.TestCase):
    def test_node_exporter_variables_resolve_to_real_values(self):
        values = checker.variable_values(load_all()["rYdddlPWk"], lambda kind: "prometheus", fake_lookup)
        self.assertEqual(values["ds_prometheus"], "prometheus")
        self.assertEqual(values["job"], "node")
        self.assertEqual(values["nodename"], "docker-desktop")
        self.assertEqual(values["node"], "node-exporter:9100")

    def test_defaults_without_lookups(self):
        board = {"templating": {"list": [{"name": "t", "type": "textbox"}, {"name": "s", "type": "custom"}]}}
        self.assertEqual(checker.variable_values(board), {"t": "", "s": ".+"})


class ProvisionedDashboards(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.boards = load_all()

    def test_required_dashboards_exist_by_uid_and_title(self):
        for uid, title in REQUIRED.items():
            self.assertIn(uid, self.boards)
            self.assertEqual(self.boards[uid]["title"], title)

    def test_uids_and_titles_are_unique(self):
        files = list(DASHBOARDS.rglob("*.json"))
        self.assertEqual(len(files), len(self.boards))
        self.assertEqual(len({b["title"] for b in self.boards.values()}), len(self.boards))

    def test_every_community_query_resolves_to_prometheus(self):
        board = self.boards["rYdddlPWk"]
        values = checker.variable_values(board, lambda kind: "prometheus", fake_lookup)
        resolved = 0
        for panel in checker.iter_panels(board["panels"]):
            for target in panel.get("targets") or []:
                if "expr" not in target:
                    continue
                datasource = checker.resolve_datasource(target.get("datasource"), panel.get("datasource"), values)
                self.assertEqual(datasource, {"type": "prometheus", "uid": "prometheus"}, panel.get("title"))
                self.assertNotIn("${ds_", checker.interpolate(target["expr"], values))
                resolved += 1
        self.assertGreater(resolved, 150)  # nested panels are included, not just the top level

    def test_production_dashboard_meets_the_assignment(self):
        board = self.boards["three-tier-production"]
        panels = [p for p in board["panels"] if p["type"] != "row"]
        rows = [p["title"] for p in board["panels"] if p["type"] == "row"]
        self.assertGreaterEqual(len(panels), 6)
        self.assertGreaterEqual(len({p["type"] for p in panels}), 3)
        self.assertTrue({"stat", "gauge", "timeseries"} <= {p["type"] for p in panels})
        self.assertTrue({"table", "bargauge"} & {p["type"] for p in panels})
        for tier in ("Frontend", "Backend", "Database", "Server"):
            self.assertTrue(any(tier in row for row in rows), tier)

    def test_production_dashboard_covers_the_required_metrics(self):
        text = json.dumps(self.boards["three-tier-production"])
        for needle in ("probe_success", "app:http_requests", "app:http_errors", "app:http_request_duration_seconds",
                       "pg_up", "pg_stat_activity_count", "node_cpu_utilisation", "node_memory_utilisation",
                       "node_filesystem_utilisation"):
            self.assertIn(needle, text)


if __name__ == "__main__":
    unittest.main()
