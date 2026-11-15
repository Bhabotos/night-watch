"""Tiny Loki query helper for the e2e scripts. Standard library only.

Loki is not published, so queries go through Grafana's datasource proxy (the same path Grafana
Explore uses): GET /api/datasources/proxy/uid/loki/loki/api/v1/...

Usage (credentials and URL from the environment, see check_phase7.sh):
  loki_query.py count   '<logql>' [minutes]   number of log lines returned
  loki_query.py lines   '<logql>' [minutes]   the lines, oldest first
  loki_query.py meta    '<logql>' [minutes]   JSON: labels (+ structured metadata) of the first stream
  loki_query.py labels  [minutes]             label names
  loki_query.py values  <label> [minutes]     label values
  loki_query.py series  '<selector>' [minutes]  number of series (streams) matching
  loki_query.py serieslabels '<selector>' [minutes]  label names used by the matching series
  loki_query.py seriesvalues <label> '<selector>' [minutes]  distinct values of a label in the matching series
  loki_query.py metric  '<logql metric>'      value of an instant metric query
  loki_query.py leak    <value|@ENVNAME> [minutes]  number of stored lines containing a secret

`leak` searches with a character-class regex ([a][b][c]) so the secret itself never appears in
the query text. Loki logs every query it runs, so a literal search would write the secret into
Loki's own log (this happened once during development; see docs/loki.md).
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

# Windows Python would otherwise print "\r\n", which breaks exact comparisons in the shell.
sys.stdout.reconfigure(newline="\n")

URL = os.environ.get("GRAFANA_URL", "http://127.0.0.1:3001").rstrip("/")
AUTH = base64.b64encode(
    f"{os.environ['GRAFANA_ADMIN_USER']}:{os.environ['GRAFANA_ADMIN_PASSWORD']}".encode()
).decode()


def get(path: str, params: dict) -> dict:
    query = urllib.parse.urlencode(params)
    request = urllib.request.Request(
        f"{URL}/api/datasources/proxy/uid/loki/loki/api/v1/{path}?{query}",
        headers={"Authorization": f"Basic {AUTH}"},
    )
    try:
        with urllib.request.urlopen(request, timeout=60) as response:  # noqa: S310 (fixed local URL)
            return json.load(response)
    except urllib.error.HTTPError as exc:
        sys.stderr.write(f"HTTP {exc.code}: {exc.read()[:300]!r}\n")
        raise SystemExit(2)


def window(minutes: float) -> dict:
    now = time.time()
    return {"start": int((now - minutes * 60) * 1e9), "end": int((now + 5) * 1e9)}


def streams(logql: str, minutes: float) -> list[dict]:
    result = get(
        "query_range",
        {"query": logql, "limit": 1000, "direction": "forward", **window(minutes)},
    )["data"]["result"]
    return result


def main(argv: list[str]) -> int:
    command, rest = argv[0], argv[1:]
    try:
        minutes = float(rest[1])
    except (IndexError, ValueError):  # not every command takes a window as its second argument
        minutes = 15
    if command == "count":
        print(sum(len(s["values"]) for s in streams(rest[0], minutes)))
    elif command == "lines":
        pairs = sorted((v[0], v[1]) for s in streams(rest[0], minutes) for v in s["values"])
        for _, line in pairs:
            print(line)
    elif command == "meta":
        found = streams(rest[0], minutes)
        print(json.dumps(found[0]["stream"] if found else {}, sort_keys=True))
    elif command == "labels":
        minutes = float(rest[0]) if rest else 15
        print("\n".join(sorted(get("labels", window(minutes))["data"])))
    elif command == "values":
        minutes = float(rest[1]) if len(rest) > 1 else 15
        print("\n".join(sorted(get(f"label/{rest[0]}/values", window(minutes))["data"])))
    elif command == "series":
        print(len(get("series", {"match[]": rest[0], **window(minutes)})["data"]))
    elif command == "serieslabels":
        found = get("series", {"match[]": rest[0], **window(minutes)})["data"]
        print("\n".join(sorted({key for series in found for key in series})))
    elif command == "leak":
        value = os.environ[rest[0][1:]] if rest[0].startswith("@") else rest[0]
        pattern = "".join("[" + re.escape(ch) + "]" for ch in value).replace("\\", "\\\\")
        query = '{job="docker"} |~ "' + pattern + '"'
        print(sum(len(found["values"]) for found in streams(query, minutes)))
    elif command == "seriesvalues":
        minutes = float(rest[2]) if len(rest) > 2 else 15
        found = get("series", {"match[]": rest[1], **window(minutes)})["data"]
        values = sorted({series[rest[0]] for series in found if rest[0] in series})
        print(chr(10).join(values))
    elif command == "metric":
        result = get("query", {"query": rest[0]})["data"]["result"]
        print(result[0]["value"][1] if result else "none")
    else:
        sys.stderr.write(__doc__ or "")
        return 64
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
