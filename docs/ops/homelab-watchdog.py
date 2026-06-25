#!/usr/bin/env python3
"""Homelab Health Watchdog — hourly service check with auto-recovery.

Runs from Hermes. Checks all known services via HTTP, cross-references with
k8s pod status, and attempts basic recovery for down services. Reports
anything it can't fix to the Captain.
"""

import subprocess, json, sys, time
from urllib.request import Request, urlopen
from urllib.error import URLError, HTTPError

# ── Service catalog ─────────────────────────────────────────────────────────
# (name, url, acceptable_codes, k8s_namespace, k8s_label)
SERVICES = [
    # Dashboards & infra
    ("Uptime Kuma",       "http://192.168.10.51",       (200,302,307), None, None),
    ("Headlamp",          "http://192.168.10.50",       (200,302,307), None, None),
    ("Homarr",            "http://192.168.10.53:7575",  (200,302,307), None, None),
    ("Beszel",            "http://192.168.10.68:8090/api/health", (200,), None, None),
    ("Speedtest Tracker", "http://192.168.10.67/api/speedtest/latest", (200,), None, None),
    ("Heimdall",          "http://192.168.10.4",        (302,307,200,401,404), None, None),
    ("Hermes",            "http://192.168.10.52",       (401,200), None, None),
    # Media stack (k8s-managed)
    ("Seerr",             "http://192.168.10.54",       (200,302,307), "media", "app=jellyseerr"),
    ("Prowlarr",          "http://192.168.10.55",       (200,302,307), "media", "app=prowlarr"),
    ("Sonarr",            "http://192.168.10.56",       (200,302,307), "media", "app=sonarr"),
    ("Radarr",            "http://192.168.10.57",       (200,302,307), "media", "app=radarr"),
    ("qBittorrent",       "http://192.168.10.58:8085",  (200,302,307), "media", "app=qbittorrent"),
    ("qBittorrent B",     "http://192.168.10.83:8085",  (200,302,307), "media", "app=qbittorrent2"),
    ("qBittorrent C",     "http://192.168.10.84:8085",  (200,302,307), "media", "app=qbittorrent3"),
    ("Cleanuparr",        "http://192.168.10.59",       (200,302,307), "media", "app=cleanuparr"),
    ("Kapowarr",          "http://192.168.10.60",       (200,302,307), "media", "app=kapowarr"),
    ("Youtarr",           "http://192.168.10.61",       (200,302,307), "media", "app=youtarr"),
    ("Tdarr",             "http://192.168.10.62",       (200,302,307), "media", "app=tdarr"),
    ("Trailarr",          "http://192.168.10.63",       (200,302,307), "media", "app=trailarr"),
    ("SuggestArr",        "http://192.168.10.64",       (200,302,307), "media", "app=suggestarr"),
    ("Lidarr",            "http://192.168.10.65",       (200,302,307), "media", "app=lidarr"),
    ("Navidrome",         "http://192.168.10.66",       (200,302,307), "media", "app=navidrome"),
    # New services (separate namespaces)
    ("n8n",               "http://192.168.10.71",       (200,302,307), "n8n", "app=n8n"),
    ("Listenarr",         "http://192.168.10.73",       (200,302,307,401), "listenarr", "app=listenarr"),
    ("Musicseerr",        "http://192.168.10.74",       (200,302,307,401), "musicseerr", "app=musicseerr"),
    ("boxarr",            "http://192.168.10.75:8888",  (200,302,307,401), "boxarr", "app=boxarr"),
    ("Jellystat",         "http://192.168.10.76",       (200,302,307), "jellystat", "app=jellystat"),
    ("Sortarr",           "http://192.168.10.77:8787",  (200,302,307,401), "sortarr", "app=sortarr"),
    # Non-k8s
    ("Jellyfin",          "http://192.168.10.247:30013/health", (200,), None, None),
    ("Akasha",            "https://192.168.10.247",     (200,302,307), None, None),
    ("Pterodactyl",       "http://192.168.10.69",       (200,302,307), None, None),
]

KUBECTL_CMD = [
    "ssh", "-i", "/opt/data/home/.ssh/id_ed25519", "-o", "StrictHostKeyChecking=no",
    "owner@192.168.10.4",
    "docker", "exec", "k3s-control-plane-k3s-server-1", "kubectl"
]

def kubectl(args):
    """Run a kubectl command, return (stdout, success)."""
    try:
        r = subprocess.run(KUBECTL_CMD + args, capture_output=True, text=True, timeout=15)
        return r.stdout.strip(), r.returncode == 0
    except Exception as e:
        return str(e), False

def check_http(url, acceptable_codes, timeout=8):
    """Check HTTP, return (status_code, error)."""
    try:
        req = Request(url, headers={"User-Agent": "Homelab-Watchdog/1.0"})
        # Don't verify SSL for internal services
        import ssl
        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        resp = urlopen(req, timeout=timeout, context=ctx)
        return resp.status, None
    except HTTPError as e:
        return e.code, None
    except URLError as e:
        return None, str(e.reason)
    except Exception as e:
        return None, str(e)

def try_recover(name, namespace, label):
    """Attempt basic recovery for a k8s service. Returns recovery note or None."""
    if not namespace or not label:
        return None

    # Get pod status
    out, ok = kubectl(["get", "pod", "-n", namespace, "-l", label, "-o", "json"])
    if not ok:
        return "kubectl failed (Heimdall unreachable?)"

    try:
        pods = json.loads(out).get("items", [])
    except:
        return "could not parse pod list"

    if not pods:
        return f"no pods found in {namespace} with label {label}"

    dead_pods = []
    for p in pods:
        name_pod = p["metadata"]["name"]
        ready = all(c.get("ready", False) for c in p.get("status", {}).get("containerStatuses", []))
        if not ready:
            dead_pods.append(name_pod)

    if not dead_pods:
        return None  # Pods look fine, issue is elsewhere

    # Try restarting dead pods
    results = []
    for dp in dead_pods:
        out, ok = kubectl(["delete", "pod", "-n", namespace, dp])
        if ok:
            results.append(f"deleted pod {dp}")
        else:
            results.append(f"failed to delete {dp}: {out[:100]}")

    return "; ".join(results)

def main():
    issues = []
    recovered = []
    needs_captain = []

    for name, url, ok_codes, ns, label in SERVICES:
        code, err = check_http(url, ok_codes)

        if err:
            # Connection-level failure
            recovery = try_recover(name, ns, label)
            if recovery:
                recovered.append(f"{name} ({url}): {err} → {recovery}")
            else:
                needs_captain.append(f"{name} ({url}): {err}")
        elif code and code not in ok_codes:
            # HTTP-level failure (wrong status)
            issues.append(f"{name} ({url}): HTTP {code} (expected {ok_codes})")

    # Build report
    lines = ["## 🔍 Homelab Watchdog Report", ""]

    if not issues and not recovered and not needs_captain:
        lines.append(f"✅ All {len(SERVICES)} services healthy at {time.strftime('%H:%M')}.")

    if recovered:
        lines.append(f"### 🔧 Auto-Recovered ({len(recovered)})")
        for r in recovered:
            lines.append(f"- {r}")

    if needs_captain:
        lines.append(f"### ⚠️ Needs Attention — Could Not Auto-Fix ({len(needs_captain)})")
        for n in needs_captain:
            lines.append(f"- {n}")

    if issues:
        lines.append(f"### ⚡ HTTP Status Issues ({len(issues)})")
        for i in issues:
            lines.append(f"- {i}")

    print("\n".join(lines))

if __name__ == "__main__":
    main()
