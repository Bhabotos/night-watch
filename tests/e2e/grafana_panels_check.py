"""Runs every query of every provisioned dashboard through Grafana against Prometheus.

A panel passes only if Grafana executes each query without error AND it returns at least one
series with at least one data point. Prometheus and Loki targets are both supported; dashboard
variables (which the browser interpolates, not Grafana's backend) are replaced by "match everything"
values, so the queries behave like the dashboard's default "All" selection. (Grafana returns an *empty frame* for a metric that does not
exist, so counting frames is not enough.) Queries listed in ALLOW_EMPTY may legitimately return
nothing. Standard library only.

Usage: GRAFANA_URL=http://127.0.0.1:3001 GRAFANA_ADMIN_USER=... GRAFANA_ADMIN_PASSWORD=... \
       python -I tests/e2e/grafana_panels_check.py
"""

import base64
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

URL = os.environ.get("GRAFANA_URL", "http://127.0.0.1:3001").rstrip("/")


def auth_header() -> str:
    """Read at call time, so the pure helpers below can be imported (and unit-tested) without credentials."""
    token = base64.b64encode(
        f"{os.environ['GRAFANA_ADMIN_USER']}:{os.environ['GRAFANA_ADMIN_PASSWORD']}".encode()
    ).decode()
    return f"Basic {token}"


# (dashboard uid, panel title) pairs whose queries may be empty on a quiet system
# (for example "increase over the range" series do not exist until the metric has changed).
ALLOW_EMPTY: set[tuple[str, str]] = {
    # Healthy systems legitimately have none of these in the last hour. Their queries must still
    # *execute* without error; only "no rows" is tolerated.
    ("logs", "nginx 5xx responses"),
    ("logs", "Dropped by Alloy (5m rate)"),
    ("logs", "Errors and critical"),
    ("logs", "Errors and critical (all services)"),
    ("logs", "Warnings (all services)"),
    ("logs", "nginx error log"),
    # PostgreSQL only logs at start-up and on errors: an hour with no line is normal.
    ("logs", "PostgreSQL"),
    # The 4xx/5xx series do not exist until the first such response after the backend (re)starts.
    ("app-tasks", "Client and server errors per second"),
}

# Community dashboard Node Exporter Full (rYdddlPWk) charts collectors that the Docker Desktop VM does not
# expose or that this stack does not enable. A query on one of these metrics may be empty; every other
# query of the dashboard must return data. Keyed by dashboard uid, matched as a substring of the query.
ALLOW_EMPTY_METRICS: dict[str, tuple[str, ...]] = {
    "rYdddlPWk": (
        "node_pressure_", "node_cpu_guest_seconds_total", "node_memory_Zswap", "node_processes_",
        "node_cpu_scaling_", "node_interrupts_total", "node_hwmon_", "node_cooling_device_",
        "node_cpu_core_throttles_total", "node_edac_", "node_systemd_", "node_tcp_connection_states",
    ),
}


LABEL_VALUES = re.compile(r"^\s*label_values\(\s*(?:(.*),\s*)?([A-Za-z_][A-Za-z0-9_]*)\s*\)\s*$", re.DOTALL)


def iter_panels(panels: list[dict]):
    """Every panel, including those nested inside (collapsed) rows."""
    for panel in panels:
        yield panel
        yield from iter_panels(panel.get("panels", []))


def variable_values(dashboard: dict, datasource_uid=None, label_lookup=None) -> dict[str, str]:
    """Replacement for each dashboard variable.

    - textbox: empty
    - datasource: the uid of the first datasource of that type (datasource_uid(type) -> uid)
    - query variable on Prometheus written as label_values(...): its first real value
      (label_lookup(selector or None, label) -> list), because dashboards such as Node Exporter Full
      match instance and job exactly and "match everything" would select nothing
    - anything else: regex-match-all
    Variables are resolved in order, so a variable may depend on an earlier one.
    """
    values: dict[str, str] = {}
    for var in dashboard.get("templating", {}).get("list", []):
        name, kind = var["name"], var["type"]
        if kind == "textbox":
            values[name] = ""
        elif kind == "datasource" and datasource_uid:
            values[name] = datasource_uid(var.get("query", "")) or ".+"
        elif kind == "query" and label_lookup and var.get("datasource", {}).get("type") == "prometheus":
            query = var.get("query", "")
            query = query.get("query", "") if isinstance(query, dict) else query
            match = LABEL_VALUES.match(query)
            selector = interpolate(match.group(1), values) if match and match.group(1) else None
            found = label_lookup(selector, match.group(2)) if match else []
            values[name] = found[0] if found else ".+"
        else:
            values[name] = ".+"
    return values


def resolve_datasource(ref: dict | None, panel_ref: dict | None, values: dict[str, str], type_of=None) -> dict | None:
    """The datasource a target really queries: its own, else the panel's (inherited); variables resolved."""
    ref = ref or panel_ref
    if not ref:
        return None
    uid = interpolate(ref.get("uid", ""), values)
    kind = ref.get("type") or (type_of(uid) if type_of else None)
    return {"type": kind, "uid": uid} if kind else None


def interpolate(expr: str, values: dict[str, str]) -> str:
    # Longest names first so that $service does not clobber a variable called $service_x.
    for name in sorted(values, key=len, reverse=True):
        expr = expr.replace("${" + name + "}", values[name]).replace("$" + name, values[name])
    return expr


def rows(frame: dict) -> int:
    values = frame.get("data", {}).get("values", [])
    return max((len(column) for column in values), default=0)


def call(path: str, payload: dict | None = None) -> dict:
    request = urllib.request.Request(
        URL + path,
        data=json.dumps(payload).encode() if payload is not None else None,
        headers={"Authorization": auth_header(), "Content-Type": "application/json"},
    )
    with urllib.request.urlopen(request, timeout=30) as response:  # noqa: S310 (fixed local URL)
        return json.load(response)


def main() -> int:
    failures = 0
    checked = 0
    datasources = call("/api/datasources")
    uid_for_type = lambda kind: next((d["uid"] for d in datasources if d["type"] == kind), None)  # noqa: E731
    type_of_uid = lambda uid: next((d["type"] for d in datasources if d["uid"] == uid), None)  # noqa: E731

    def label_lookup(selector: str | None, label: str) -> list[str]:
        path = f"/api/datasources/uid/{uid_for_type('prometheus')}/resources/api/v1/label/{label}/values"
        if selector:
            path += "?match[]=" + urllib.parse.quote(selector)
        return call(path).get("data", [])

    for hit in call("/api/search?type=dash-db"):
        dashboard = call(f"/api/dashboards/uid/{hit['uid']}")["dashboard"]
        print(f"== {dashboard['title']} ({dashboard['uid']})")
        substitutions = variable_values(dashboard, uid_for_type, label_lookup)
        for panel in iter_panels(dashboard["panels"]):
            if panel["type"] in ("row", "text") or not panel.get("targets"):
                continue
            queries = []
            for t in panel["targets"]:
                datasource = resolve_datasource(t.get("datasource"), panel.get("datasource"), substitutions, type_of_uid)
                if datasource is None or "expr" not in t or t.get("hide"):
                    continue
                query = {
                    "refId": t["refId"],
                    "datasource": datasource,
                    "expr": interpolate(t["expr"], substitutions),
                    "legendFormat": t.get("legendFormat", ""),
                    "intervalMs": 15000,
                    "maxDataPoints": 500,
                }
                if datasource["type"] == "loki":
                    query["queryType"] = t.get("queryType", "range")
                    query["maxLines"] = t.get("maxLines", 100)
                else:
                    query["instant"] = t.get("instant", False)
                    query["range"] = t.get("range", True)
                queries.append(query)
            if not queries:
                continue
            now = int(time.time() * 1000)
            try:
                result = call(
                    "/api/ds/query",
                    {"queries": queries, "from": str(now - 3600_000), "to": str(now)},
                )["results"]
            except urllib.error.HTTPError as exc:
                # Grafana answers 400 with per-query errors in the body.
                result = json.loads(exc.read() or b"{}").get("results", {})
            for query in queries:
                checked += 1
                outcome = result.get(query["refId"], {})
                error = outcome.get("error")
                frames = sum(1 for f in outcome.get("frames", []) if rows(f) > 0)
                allowed = (dashboard["uid"], panel["title"]) in ALLOW_EMPTY or any(
                    metric in query["expr"] for metric in ALLOW_EMPTY_METRICS.get(dashboard["uid"], ())
                )
                if error:
                    status, failures = f"ERROR {error[:100]}", failures + 1
                elif not outcome:
                    status, failures = "ERROR no result returned", failures + 1
                elif frames == 0 and not allowed:
                    status, failures = "NO DATA", failures + 1
                else:
                    status = f"ok ({frames} series)"
                print(f"  {'PASS' if status.startswith('ok') else 'FAIL'}  {panel['title']} [{query['refId']}] {status}")
    print(f"{checked} queries checked, {failures} failed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
