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
import sys
import time
import urllib.error
import urllib.request

URL = os.environ.get("GRAFANA_URL", "http://127.0.0.1:3001").rstrip("/")
AUTH = base64.b64encode(
    f"{os.environ['GRAFANA_ADMIN_USER']}:{os.environ['GRAFANA_ADMIN_PASSWORD']}".encode()
).decode()

# (dashboard uid, panel title) pairs whose queries may be empty on a quiet system
# (for example "increase over the range" series do not exist until the metric has changed).
ALLOW_EMPTY: set[tuple[str, str]] = {
    # Healthy systems legitimately have none of these in the last hour. Their queries must still
    # *execute* without error; only "no rows" is tolerated.
    ("logs", "nginx 5xx responses"),
    ("logs", "Dropped by Alloy (5m rate)"),
    ("logs", "Errors and critical (all services)"),
    ("logs", "Warnings (all services)"),
    ("logs", "nginx error log"),
    # PostgreSQL only logs at start-up and on errors: an hour with no line is normal.
    ("logs", "PostgreSQL"),
    # The 4xx/5xx series do not exist until the first such response after the backend (re)starts.
    ("app-tasks", "Client and server errors per second"),
}


def variable_values(dashboard: dict) -> dict[str, str]:
    """Replacement for each dashboard variable: regex-match-all for selectors, empty for text boxes."""
    values = {}
    for var in dashboard.get("templating", {}).get("list", []):
        values[var["name"]] = "" if var["type"] == "textbox" else ".+"
    return values


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
        headers={"Authorization": f"Basic {AUTH}", "Content-Type": "application/json"},
    )
    with urllib.request.urlopen(request, timeout=30) as response:  # noqa: S310 (fixed local URL)
        return json.load(response)


def main() -> int:
    failures = 0
    checked = 0
    for hit in call("/api/search?type=dash-db"):
        dashboard = call(f"/api/dashboards/uid/{hit['uid']}")["dashboard"]
        print(f"== {dashboard['title']} ({dashboard['uid']})")
        for panel in dashboard["panels"]:
            if panel["type"] in ("row", "text"):
                continue
            substitutions = variable_values(dashboard)
            queries = []
            for t in panel["targets"]:
                query = {
                    "refId": t["refId"],
                    "datasource": t["datasource"],
                    "expr": interpolate(t["expr"], substitutions),
                    "legendFormat": t.get("legendFormat", ""),
                    "intervalMs": 15000,
                    "maxDataPoints": 500,
                }
                if t["datasource"]["type"] == "loki":
                    query["queryType"] = t.get("queryType", "range")
                    query["maxLines"] = t.get("maxLines", 100)
                else:
                    query["instant"] = t.get("instant", False)
                    query["range"] = t.get("range", True)
                queries.append(query)
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
                allowed = (dashboard["uid"], panel["title"]) in ALLOW_EMPTY
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
