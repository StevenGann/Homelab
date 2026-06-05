# qBittorrent (VPN-fronted via gluetun / ProtonVPN)

qBittorrent runs in a two-container pod that shares a network namespace with
**gluetun**, so all torrent + WebUI traffic egresses through the ProtonVPN
WireGuard tunnel (`tun0`) behind gluetun's kill-switch. The NFS download volume
is mounted by the kubelet at the host level, so file I/O does **not** traverse
the VPN — only network traffic does.

```
┌─ pod (shared netns) ─────────────────────────────────────────────┐
│  gluetun  ── tun0 (10.2.0.2) ── ProtonVPN WireGuard ── internet   │
│     │  NAT-PMP port forwarding → /tmp/gluetun/forwarded_port      │
│     │  kill-switch: OUTPUT DROP except -o tun0                     │
│  qbittorrent ── WebUI :8085 ── must bind libtorrent to tun0       │
│     ▲ port-sync.sh (ConfigMap, /custom-services.d/)               │
│       reads forwarded_port → sets listen_port + binds tun0        │
└──────────────────────────────────────────────────────────────────┘
```

Files: `deployment.yaml`, `service.yaml`, `port-sync-configmap.yaml`,
`pvc.yaml`, `secret.sops.yaml`.

## How port forwarding + interface binding work

ProtonVPN assigns a **random forwarded port** via NAT-PMP that **changes on every
reconnect**. gluetun writes it to `/tmp/gluetun/forwarded_port` (a shared
`emptyDir` both containers mount at `/tmp/gluetun`). `port-sync.sh` runs as a
linuxserver.io custom service (`/custom-services.d/`) and on startup — then every
30 s — pushes two things to qBittorrent via its WebUI API:

1. `listen_port` = the current forwarded port.
2. `current_network_interface = tun0` — binds libtorrent to the VPN interface.
   It also clears `announce_ip` so qBittorrent doesn't advertise a stale exit IP
   to trackers.

Both settings persist on the config PVC, but the script reapplies them on every
start so the app is correct even after a PVC reset or a port change.

---

## Post-mortem: "DHT dead, external IP N/A" (2026-06-04)

### Symptoms

- qBittorrent reported **external IP: N/A**.
- **DHT was dead** — `dht_nodes: 0`.
- `connection_status: "firewalled"`, zero download/upload.

…even though ProtonVPN port forwarding was enabled and the forwarded port was
being synced into `listen_port` correctly.

### What was NOT wrong (all verified healthy)

- gluetun connected; public IP correct; NAT-PMP forwarding active (port written
  to `/tmp/gluetun/forwarded_port`, allowed inbound on `tun0` for TCP+UDP).
- port-sync script ran and set `listen_port` to the forwarded port.
- Outbound **UDP through the tunnel worked** when tested manually
  (`nslookup google.com 8.8.8.8` from the pod succeeded — and since gluetun's
  `OUTPUT` chain DROPs everything except `-o tun0`, a successful UDP query proves
  UDP egress is tunneled).

### Root cause

qBittorrent's **Network Interface was set to "Any"**
(`current_network_interface: ""`). Its startup log showed it bound to loopback
and **eth0** — but **never to `tun0`**:

```
Successfully listening on IP: "127.0.0.1".      Port: "TCP/UTP 38603"
Successfully listening on IP: "10.42.10.65".    Port: "TCP/UTP 38603"   ← eth0
(tun0 / 10.2.0.2 absent)
```

With "Any interface", libtorrent **sourced its DHT/peer traffic from
`10.42.10.65` (eth0)**. The pod's policy routing then sent those packets out
eth0, *around* the tunnel:

```
ip rule:  100:  from 10.42.10.65 lookup 200
table 200:      default via 10.42.10.1 dev eth0      ← bypasses tun0
```

…and gluetun's kill-switch dropped them (the `OUTPUT` chain only permits
`-o tun0` to the internet). Net effect: **tun0 sat idle, DHT never bootstrapped,
the listen port was unreachable inbound (`firewalled`), and qBittorrent never
learned its external address → "N/A".**

> Why did a manual `curl` from the same container work while qBittorrent didn't?
> `curl` binds no source address, so the kernel performs route-based source
> selection and picks `tun0`. libtorrent, having enumerated eth0 as its
> interface, pinned its source to `10.42.10.65` — straight into the kill-switch.

### The fix

Bind qBittorrent to the VPN interface:

```jsonc
// app/setPreferences
{ "current_network_interface": "tun0", "announce_ip": "" }
```

Effect was immediate — DHT recovered within seconds:

| t (s) | dht_nodes | connection  | external IP (v4)  | download   |
|------:|----------:|-------------|-------------------|-----------|
|   ~8  |     0     | firewalled  | "" (N/A)          | 0         |
|  ~24  |     2     | firewalled  | 156.146.54.102    | 0         |
|  ~32  |   137     | **connected** | 156.146.54.102  | 4.2 MB/s  |
| later |   272     | connected   | 156.146.54.102    | ~40 MB/s  |

Binding by interface **name** (`tun0`) — not by address — is robust here:
gluetun always names the interface `tun0`, and this ProtonVPN config always
assigns `10.2.0.2` (`WIREGUARD_ADDRESSES=10.2.0.2/32`), so the bind survives
reconnects and forwarded-port changes.

The bind (plus the stale-`announce_ip` clear) is now baked into `port-sync.sh`
so it is reapplied on every startup — see `port-sync-configmap.yaml`.

### Diagnostic recipe (for next time)

There is no host `kubectl`; run it inside the Heimdall control-plane container:

```bash
H="ssh owner@192.168.10.4 sudo docker exec k3s-control-plane-k3s-server-1 kubectl"
P=$($H get pod -n media -l app=qbittorrent -o name)

# 1. Is the VPN up and is a port forwarded?
$H logs -n media $P -c gluetun | grep -iE 'public ip|port forward'

# 2. Connection health (the money shot):
$H exec -n media $P -c qbittorrent -- \
  curl -s -u admin:<pw> http://localhost:8085/api/v2/transfer/info
#   → connection_status / dht_nodes / last_external_address_v4

# 3. Which interfaces did qBittorrent bind? (look for tun0 / the VPN IP)
$H exec -n media $P -c qbittorrent -- \
  grep -i 'listening on IP' /config/qBittorrent/logs/qbittorrent.log

# 4. Is the tunnel actually carrying qBittorrent's traffic, or is it idle?
$H exec -n media $P -c gluetun -- \
  cat /sys/class/net/tun0/statistics/tx_packets   # frozen == app not egressing via VPN
```

**Tell-tale:** the qBittorrent listen log shows eth0 / the pod IP but **no
`tun0`**, while `tun0` tx counters stay frozen → it's the interface-bind issue
above.
