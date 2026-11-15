#!/bin/sh
# Static checks of the network design in docker-compose.yml (no containers needed).
# Service membership is checked for every service that is currently defined;
# services added in later phases are checked automatically once they exist.
# Network definitions are read from the raw YAML (docker compose config drops
# networks that no service uses yet); membership uses the resolved config.
# Requires PyYAML. Run from the repo root: sh tests/e2e/check_network_design.sh
set -u
docker compose config --format json 2>/dev/null | python -I -c '
import json, sys, yaml
c = json.load(sys.stdin)
svcs = c.get("services", {})
nets = yaml.safe_load(open("docker-compose.yml"))["networks"]
internal = {"proxy": True, "application": True, "metrics": True, "monitoring": True, "edge": False, "uiaccess": False}
expected = {
    "nginx": {"edge", "proxy"},
    "backend": {"proxy", "application", "metrics"},
    "postgres": {"application"},
    "postgres-exporter": {"application", "metrics"},
    "node-exporter": {"metrics"},
    "prometheus": {"metrics", "monitoring"},
    "grafana": {"edge", "monitoring"},
    "loki": {"monitoring"},
    "alloy": {"monitoring"},
    "docker-socket-proxy": {"monitoring"},
    "prometheus-ui": {"uiaccess", "monitoring"},  # localhost-only Prometheus UI forwarder
    "backend-test": {"application"},  # compose profile "test" only
}
published_ok = {"nginx", "grafana", "prometheus-ui"}
fail = 0
def check(ok, msg):
    global fail
    print(("PASS  " if ok else "FAIL  ") + msg)
    fail |= (not ok)
check(set(nets) == set(internal), "exactly the 6 networks are defined: " + ", ".join(sorted(nets)))
check([n for n, v in svcs.items() if "uiaccess" in v.get("networks", {})] == ["prometheus-ui"], "the uiaccess network contains only prometheus-ui")
check(all("prometheus" not in v.get("ports", []) and not svcs["prometheus"].get("ports") for v in [svcs["prometheus"]]), "prometheus itself publishes no ports")
for n, want in internal.items():
    check(bool(nets.get(n, {}).get("internal", False)) == want, f"network {n}: internal={want}")
for name, svc in svcs.items():
    have = set(svc.get("networks", {}))
    check(name in expected and have == expected[name], f"{name} networks == {sorted(expected.get(name, []))} (got {sorted(have)})")
    ports = svc.get("ports", [])
    if name in published_ok:
        check(all(p.get("host_ip") == "127.0.0.1" for p in ports), f"{name} publishes on 127.0.0.1 only")
    else:
        check(not ports, f"{name} publishes no ports")
shared = lambda a, b: bool(set(svcs.get(a, {}).get("networks", {})) & set(svcs.get(b, {}).get("networks", {})))
if "nginx" in svcs and "postgres" in svcs:
    check(not shared("nginx", "postgres"), "nginx and postgres share no network")
sys.exit(fail)
'
