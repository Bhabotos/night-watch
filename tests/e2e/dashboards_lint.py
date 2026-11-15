"""Static checks of the provisioned dashboard JSON (no Grafana needed). Standard library only.

Usage: python -I tests/e2e/dashboards_lint.py [dashboards_dir]
"""

import json
import re
import sys
from pathlib import Path

DIR = Path(sys.argv[1] if len(sys.argv) > 1 else "monitoring/grafana/dashboards")
EXPECTED = {
    "host-vm": "Host (Docker VM)",
    "app-tasks": "Application (Tasks API)",
    "postgres": "PostgreSQL",
    "logs": "Logs (Loki)",
}
PROM = {"type": "prometheus", "uid": "prometheus"}
LOKI = {"type": "loki", "uid": "loki"}
ALLOWED_DS = (PROM, LOKI)
# Labels that must never appear in a Loki stream selector: they are per-request values and would
# either be unindexed (structured metadata) or explode the index if turned into labels.
HIGH_CARDINALITY = re.compile(r"\{[^}]*\b(request_id|path|remote_addr|user_agent|status|method|route)\s*(=|!=|=~|!~)")
DISK_LABEL = "Docker data disk"
SECRET_WORDS = re.compile(r"password|passwd|secret|token|api[_-]?key", re.IGNORECASE)

failures = 0


def check(ok: bool, message: str) -> None:
    global failures
    print(("PASS  " if ok else "FAIL  ") + message)
    failures += not ok


boards = {}
for path in sorted(DIR.glob("*.json")):
    try:
        boards[path.name] = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        check(False, f"{path.name}: invalid JSON ({exc})")

check({b["uid"] for b in boards.values()} == set(EXPECTED), f"exactly the expected dashboards exist: {sorted(EXPECTED)}")
check(len({b["uid"] for b in boards.values()}) == len(boards), "dashboard uids are unique")
check(len({b["title"] for b in boards.values()}) == len(boards), "dashboard titles are unique")

for name, board in boards.items():
    prefix = f"{name}:"
    check(EXPECTED.get(board["uid"]) == board["title"], f"{prefix} title matches uid ({board['title']})")
    check(board.get("editable") is False, f"{prefix} not editable (provisioned, repo is the source of truth)")
    check("monitoring-3tier" in board.get("tags", []), f"{prefix} tagged monitoring-3tier")
    check(bool(board.get("refresh")) and board["time"]["from"].startswith("now-"), f"{prefix} has refresh and relative time range")
    check(bool(board.get("description")), f"{prefix} has a description")

    panels = board["panels"]
    ids = [p["id"] for p in panels]
    check(len(ids) == len(set(ids)), f"{prefix} panel ids are unique")
    check(any(p["type"] == "row" for p in panels), f"{prefix} is organised in rows")

    # No two panels overlap and nothing is wider than the 24-column grid.
    cells = set()
    overlap = False
    for p in panels:
        g = p["gridPos"]
        if g["x"] + g["w"] > 24:
            overlap = True
        for x in range(g["x"], g["x"] + g["w"]):
            for y in range(g["y"], g["y"] + g["h"]):
                overlap |= (x, y) in cells
                cells.add((x, y))
    check(not overlap, f"{prefix} panels fit the grid without overlapping")

    data_panels = [p for p in panels if p["type"] not in ("row", "text")]
    check(all(p.get("title") for p in data_panels), f"{prefix} every panel has a title")
    check(
        all(p["fieldConfig"]["defaults"].get("unit") for p in data_panels if p["type"] != "logs"),
        f"{prefix} every chart panel declares a unit",
    )
    check(
        all(p["datasource"] in ALLOWED_DS for p in data_panels),
        f"{prefix} every panel uses a provisioned datasource (Prometheus or Loki) by uid",
    )
    targets = [(p, t) for p in data_panels for t in p["targets"]]
    check(all(t.get("expr") and t.get("refId") for _, t in targets), f"{prefix} every query has an expression and refId")
    check(
        all(t["datasource"] == p["datasource"] for p, t in targets),
        f"{prefix} every query uses the same provisioned datasource as its panel (by uid)",
    )
    check(
        all(len({t["refId"] for t in p["targets"]}) == len(p["targets"]) for p in data_panels),
        f"{prefix} refIds are unique within each panel",
    )
    check(SECRET_WORDS.search(json.dumps(board)) is None, f"{prefix} contains no secret-like words")
    check(
        all("node_network_" not in t["expr"] for _, t in targets),
        f"{prefix} has no node_network_* query (it would describe node-exporter's own container, not the VM)",
    )
    check(
        all(re.search(r"datname=\"(?!tasks\")", t["expr"]) is None for _, t in targets),
        f"{prefix} PostgreSQL queries only target the tasks database",
    )

    # Disk metrics must be labelled "Docker data disk" and must not claim to cover Windows drives.
    disk_panels = [p for p in data_panels if any("node_filesystem" in t["expr"] for t in p["targets"])]
    if board["uid"] == "host-vm":
        check(len(disk_panels) >= 3, f"{prefix} has disk panels ({len(disk_panels)} found)")
        check(
            all(DISK_LABEL in p["title"] for p in disk_panels),
            f"{prefix} every filesystem panel title contains '{DISK_LABEL}'",
        )
        notes = [p for p in panels if p["type"] == "text"]
        check(
            any("Windows" in p["options"]["content"] and DISK_LABEL in p["options"]["content"] for p in notes),
            f"{prefix} states that Windows drives are not monitored and the disk is the {DISK_LABEL}",
        )
        io_titles = [p["title"] for p in data_panels if any("node_disk_" in t["expr"] for t in p["targets"])]
        check(
            all("VM block devices" in t for t in io_titles),
            f"{prefix} disk I/O panels say they cover VM block devices, not just the {DISK_LABEL}",
        )
        check(
            not any(re.search(r"\b[C-Z]:", p["title"]) for p in data_panels),
            f"{prefix} no panel title mentions a Windows drive letter",
        )
    else:
        check(not disk_panels, f"{prefix} has no filesystem panels")

logs = next((b for b in boards.values() if b["uid"] == "logs"), None)
if logs:
    log_targets = [t for p in logs["panels"] if p["type"] not in ("row", "text") for t in p["targets"] if t["datasource"] == LOKI]
    check(len(log_targets) >= 12, f"logs: has Loki queries ({len(log_targets)})")
    check(
        all(HIGH_CARDINALITY.search(t["expr"]) is None for t in log_targets),
        "logs: no stream selector uses a per-request label (request_id, path, status, ...)",
    )
    check(
        all(t["expr"].lstrip().startswith(("{", "sum", "count", "quantile", "rate")) for t in log_targets),
        "logs: every Loki query starts with a stream selector or an aggregation of one",
    )
    check(
        all('job="docker"' in t["expr"] or 'service="' in t["expr"] for t in log_targets),
        "logs: every Loki selector is scoped (job or service)",
    )
    variables = {v["name"]: v for v in logs["templating"]["list"]}
    check(set(variables) == {"service", "level", "search"}, "logs: variables are service, level, search")
    check(
        all(variables[n].get("includeAll") and variables[n].get("allValue") == ".+" for n in ("service", "level")),
        "logs: service and level default to All with a match-everything value",
    )
    check(
        any(p["type"] == "logs" for p in logs["panels"]) and sum(p["type"] == "logs" for p in logs["panels"]) >= 6,
        "logs: has log panels for errors, warnings, backend, nginx access, nginx error and PostgreSQL",
    )
    prom_panels = [p for p in logs["panels"] if p["type"] not in ("row", "text") and p["datasource"] == PROM]
    check(len(prom_panels) >= 3, f"logs: has pipeline-health panels from Prometheus ({len(prom_panels)})")

print(f"{failures} failure(s)")
sys.exit(1 if failures else 0)
