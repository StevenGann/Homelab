#!/usr/bin/env python3
"""
healthcheck.py — Hyperion IaC integration test runner

Treats each infrastructure check as a discrete test case. Results include
per-check pass/fail timestamps and consecutive run counts so trends are visible.

Adding a new check:
    @check("my_check", category="mycat", description="What this validates")
    def check_my_thing():
        ok, msg = some_assertion(...)
        return ok, msg

HTTP API:
    GET  /          → full results (all checks + summary)
    GET  /summary   → pass/fail counts only
    POST /scan      → trigger async rescan, returns 202
    GET  /scan      → trigger async rescan, returns 202

Environment variables:
    NGINX_URL        Base URL for nginx image server (default: http://nginx:50011)
    SCAN_INTERVAL    Seconds between automatic scans (default: 600)
    HTTP_PORT        Port for HTTP API (default: 8080)
    CI_STATUS_FILE   Path to ci-deploy heartbeat file (default: /images/ci-deploy-status.json)
    SSH_TIMEOUT      Seconds for SSH port probe timeout (default: 5)
"""

import json
import os
import socket
import threading
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, HTTPServer

# ── Configuration ──────────────────────────────────────────────────────────────
NGINX_BASE     = os.environ.get("NGINX_URL",      "http://nginx:50011")
SCAN_INTERVAL  = int(os.environ.get("SCAN_INTERVAL",  "600"))
HTTP_PORT      = int(os.environ.get("HTTP_PORT",       "8080"))
CI_STATUS_FILE = os.environ.get("CI_STATUS_FILE", "/images/ci-deploy-status.json")
SSH_TIMEOUT    = float(os.environ.get("SSH_TIMEOUT",   "5"))

NODES = {
    "alpha":   "192.168.10.101",
    "beta":    "192.168.10.102",
    "gamma":   "192.168.10.103",
    "delta":   "192.168.10.104",
    "epsilon": "192.168.10.105",
    "zeta":    "192.168.10.106",
    "eta":     "192.168.10.107",
    "theta":   "192.168.10.108",
    "iota":    "192.168.10.109",
    "kappa":   "192.168.10.110",
}

# ── Check registry ─────────────────────────────────────────────────────────────
# Each entry: { name, category, description, fn }
_registry = []

def check(name, category, description):
    """Decorator that registers a function as a named test case."""
    def decorator(fn):
        _registry.append({
            "name":        name,
            "category":    category,
            "description": description,
            "fn":          fn,
        })
        return fn
    return decorator

# ── State ──────────────────────────────────────────────────────────────────────
_lock      = threading.Lock()
_results   = {}   # name → result dict
_last_scan = None
_scanning  = False
_scan_event = threading.Event()

def _now():
    return datetime.now(timezone.utc).isoformat()

def _build_result(name, passed, message, prev):
    """Merge a pass/fail outcome with the previous result to track timestamps."""
    ts = _now()
    status = "pass" if passed else "fail"
    consecutive = prev.get("consecutive_passes" if passed else "consecutive_fails", 0) + 1
    return {
        "status":             status,
        "message":            message,
        "last_pass":          ts if passed      else prev.get("last_pass"),
        "last_fail":          ts if not passed  else prev.get("last_fail"),
        "last_checked":       ts,
        "consecutive_passes": consecutive if passed    else 0,
        "consecutive_fails":  consecutive if not passed else 0,
    }

def _unknown_result():
    return {
        "status":             "unknown",
        "message":            "Not yet checked",
        "last_pass":          None,
        "last_fail":          None,
        "last_checked":       None,
        "consecutive_passes": 0,
        "consecutive_fails":  0,
    }

# ── Assertion helpers ──────────────────────────────────────────────────────────
def http_head(url, timeout=10.0):
    """Return (ok, message) for a HEAD request."""
    try:
        req = urllib.request.Request(url, method="HEAD")
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return True, f"HTTP {r.status}"
    except urllib.error.HTTPError as e:
        return False, f"HTTP {e.code}"
    except Exception as e:
        return False, str(e)

def http_json(url, timeout=10.0):
    """Return (ok, message, data_or_None) for a GET that should return JSON."""
    try:
        with urllib.request.urlopen(url, timeout=timeout) as r:
            data = json.loads(r.read().decode())
            return True, f"HTTP {r.status}", data
    except urllib.error.HTTPError as e:
        return False, f"HTTP {e.code}", None
    except json.JSONDecodeError as e:
        return False, f"Invalid JSON: {e}", None
    except Exception as e:
        return False, str(e), None

def tcp_port_open(host, port, timeout=SSH_TIMEOUT):
    """Return (ok, message) for a TCP connection probe."""
    try:
        with socket.create_connection((host, port), timeout=timeout):
            return True, f"Port {port} open"
    except socket.timeout:
        return False, "Timeout"
    except ConnectionRefusedError:
        return False, "Connection refused"
    except OSError as e:
        return False, str(e)

# ── Test cases — infra ─────────────────────────────────────────────────────────

@check("nginx_reachable", category="infra",
       description="nginx image server responds on port 50011")
def check_nginx_reachable():
    return http_head(f"{NGINX_BASE}/")


@check("node_manifest_valid", category="images",
       description="node/manifest.json is present and contains expected fields")
def check_node_manifest():
    ok, msg, data = http_json(f"{NGINX_BASE}/node/manifest.json")
    if not ok:
        return False, msg
    required = {"current_version", "image_file"}
    missing = required - set(data.keys())
    if missing:
        return False, f"Missing fields: {missing}"
    return True, f"version={data['current_version']}  file={data['image_file']}"


@check("node_img_file_exists", category="images",
       description="Node IMG referenced in manifest is served by nginx")
def check_node_img_file():
    _, _, data = http_json(f"{NGINX_BASE}/node/manifest.json")
    if not data:
        return False, "Cannot check — manifest unavailable"
    img = data.get("image_file")
    if not img:
        return False, "manifest missing 'image_file'"
    ok, msg = http_head(f"{NGINX_BASE}/node/{img}")
    return ok, f"{img}: {msg}"


@check("bootstrap_img_exists", category="images",
       description="Bootstrap IMG is present and served by nginx")
def check_bootstrap_img():
    return http_head(f"{NGINX_BASE}/bootstrap/rpi-bootstrap.img")


@check("ci_deploy_polling", category="services",
       description="ci-deploy wrote a heartbeat within 3× its poll interval and reported no errors")
def check_ci_deploy():
    try:
        with open(CI_STATUS_FILE) as f:
            data = json.load(f)
    except FileNotFoundError:
        return False, f"Heartbeat file not found: {CI_STATUS_FILE}"
    except Exception as e:
        return False, f"Cannot read heartbeat file: {e}"

    last_poll = data.get("last_poll")
    if not last_poll:
        return False, "Heartbeat file missing 'last_poll' field"

    try:
        poll_dt = datetime.fromisoformat(last_poll)
        age_s = (datetime.now(timezone.utc) - poll_dt).total_seconds()
    except ValueError:
        return False, f"Cannot parse last_poll timestamp: {last_poll!r}"

    poll_interval = int(data.get("poll_interval", 300))
    grace = poll_interval * 3
    if age_s > grace:
        return False, f"Last poll {int(age_s)}s ago — stale (grace={grace}s)"

    if data.get("last_error"):
        return False, f"Last poll error: {data['last_error']}"

    node_ver = data.get("node_version", "unknown")
    return True, f"Last poll {int(age_s)}s ago  node_version={node_ver}"


# ── Test cases — nodes ─────────────────────────────────────────────────────────
# One check per node, auto-generated so adding nodes is a one-line change above.

def _make_node_check(greek, ip):
    @check(f"node_ssh_{greek}", category="nodes",
           description=f"hyperion-{greek} ({ip}) accepts connections on port 22")
    def _check():
        return tcp_port_open(ip, 22)
    _check.__name__ = f"check_node_ssh_{greek}"
    return _check

for _greek, _ip in NODES.items():
    _make_node_check(_greek, _ip)

# ── Scan engine ────────────────────────────────────────────────────────────────
def _run_scan():
    global _last_scan, _scanning

    with _lock:
        _scanning = True

    new_results = {}
    for entry in _registry:
        name = entry["name"]
        with _lock:
            prev = _results.get(name, _unknown_result())
        try:
            passed, message = entry["fn"]()
        except Exception as e:
            passed, message = False, f"Check raised exception: {e}"
        new_results[name] = _build_result(name, passed, message, prev)

    with _lock:
        _results.update(new_results)
        _last_scan = _now()
        _scanning  = False


def _scanner_loop():
    time.sleep(3)   # let HTTP server start first
    while True:
        _run_scan()
        _scan_event.wait(timeout=SCAN_INTERVAL)
        _scan_event.clear()

# ── Response helpers ───────────────────────────────────────────────────────────
def _full_response():
    with _lock:
        results = dict(_results)
        last_scan = _last_scan
        scanning  = _scanning

    checks = []
    for entry in _registry:
        name = entry["name"]
        result = results.get(name, _unknown_result())
        checks.append({
            "name":        name,
            "category":    entry["category"],
            "description": entry["description"],
            **result,
        })

    total  = len(checks)
    passed = sum(1 for c in checks if c["status"] == "pass")
    failed = sum(1 for c in checks if c["status"] == "fail")
    unknown = total - passed - failed

    return {
        "last_scan": last_scan,
        "scanning":  scanning,
        "summary": {
            "total":   total,
            "passed":  passed,
            "failed":  failed,
            "unknown": unknown,
            "healthy": failed == 0 and unknown == 0,
        },
        "checks": checks,
    }

def _summary_response():
    full = _full_response()
    return {
        "last_scan": full["last_scan"],
        "scanning":  full["scanning"],
        "summary":   full["summary"],
    }

# ── HTTP handler ───────────────────────────────────────────────────────────────
class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass  # suppress per-request noise; errors still go to stderr

    def _send_json(self, status, data):
        body = json.dumps(data, indent=2).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", len(body))
        self.end_headers()
        self.wfile.write(body)

    def _trigger_scan(self):
        _scan_event.set()
        self._send_json(202, {"message": "Scan triggered", "queued_at": _now()})

    def do_GET(self):
        if self.path in ("/", "/checks"):
            self._send_json(200, _full_response())
        elif self.path == "/summary":
            self._send_json(200, _summary_response())
        elif self.path == "/scan":
            self._trigger_scan()
        else:
            self._send_json(404, {"error": "Not found"})

    def do_POST(self):
        if self.path == "/scan":
            self._trigger_scan()
        else:
            self._send_json(404, {"error": "Not found"})


# ── Entry point ────────────────────────────────────────────────────────────────
if __name__ == "__main__":
    print(f"[healthcheck] {len(_registry)} checks registered across "
          f"{len({e['category'] for e in _registry})} categories")
    print(f"[healthcheck] Scan interval: {SCAN_INTERVAL}s  |  HTTP port: {HTTP_PORT}")

    threading.Thread(target=_scanner_loop, daemon=True).start()

    server = HTTPServer(("0.0.0.0", HTTP_PORT), Handler)
    server.serve_forever()
