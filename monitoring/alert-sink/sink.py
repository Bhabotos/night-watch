"""Local Alertmanager webhook receiver (Night Watch).

Receives Alertmanager webhook POSTs and prints one JSON line per alert to stdout, so every notification
(firing and resolved) is visible with `docker logs` and is collected into Loki by Alloy. It needs no
credentials, makes no outbound connections and keeps no state. Standard library only.
"""

import json
from http.server import BaseHTTPRequestHandler, HTTPServer

MAX_BODY = 1_000_000


class Handler(BaseHTTPRequestHandler):
    def _reply(self, code: int, text: str) -> None:
        self.send_response(code)
        self.send_header("Content-Type", "text/plain")
        self.end_headers()
        self.wfile.write(text.encode())

    def do_GET(self) -> None:  # health check
        self._reply(200, "ok")

    def do_POST(self) -> None:
        length = min(int(self.headers.get("Content-Length", 0)), MAX_BODY)
        try:
            payload = json.loads(self.rfile.read(length))
            alerts = payload["alerts"]
        except (ValueError, KeyError, TypeError):
            self._reply(400, "invalid Alertmanager payload")
            return
        for alert in alerts:
            labels, notes = alert.get("labels", {}), alert.get("annotations", {})
            print(json.dumps({
                "event": "notification",
                "status": alert.get("status"),
                "alertname": labels.get("alertname"),
                "severity": labels.get("severity"),
                "tier": labels.get("tier"),
                "summary": notes.get("summary"),
                "startsAt": alert.get("startsAt"),
                "endsAt": alert.get("endsAt"),
            }), flush=True)
        self._reply(200, "ok")

    def log_message(self, *args) -> None:  # no per-request access log
        pass


if __name__ == "__main__":
    HTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
