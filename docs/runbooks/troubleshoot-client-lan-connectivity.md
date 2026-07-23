# Troubleshoot — a client can't reach homelab services (but others can)

**Symptom shape this runbook is for:** one device fails to reach homelab
services — DNS names don't resolve, services won't load, hosts won't connect
even by raw IP — while **every other device on the network is fine**. The
failure is total for anything *off* the device's own subnet, but the device's
local subnet and general internet both work, so nothing looks obviously broken.

The homelab spans multiple `192.168.x.0/24` subnets routed by the UCG:

| Subnet | What's on it |
|--------|--------------|
| `192.168.10.0/24` | Homelab VLAN — Heimdall DNS (`.4`), Akasha (`.247`), the MetalLB service pool (`.10–.99`) |
| `192.168.0.0/24` | Main home subnet — e.g. Epsilon (`.105`) |
| `192.168.30.0/24` | Additional client subnet |

Reaching services from a *different* subnet than the one they live on depends
on the client's Layer-3 config being correct. When it isn't, you get exactly
the symptom above.

## The one diagnostic insight

**Sort the failures by subnet.** If *everything that fails is off-subnet* and
*everything on the client's own subnet works* (plus general internet works),
the fault is **the client's own IP-layer config — not the UCG, not DNS, not the
target service.** A whole-network routing/firewall problem would break other
devices too; this breaks only one.

Confirm the pattern before chasing anything:

| Test from the client | Expected if this runbook applies |
|----------------------|----------------------------------|
| Ping a host on its **own** subnet | ✅ works |
| Ping the **UCG gateway** (`192.168.<own>.1`) | ✅ works |
| Ping Akasha `192.168.10.247` (off-subnet, by IP) | ❌ fails |
| Resolve a `*.lab` name (DNS is `192.168.10.4`, off-subnet) | ❌ fails |
| General internet | usually ✅ (this is why nobody noticed) |

## Diagnose (Windows)

The single most useful command — it prints the **exact interface, source IP,
and next hop** Windows will use to reach a target. Run in **PowerShell** (it's a
cmdlet, not a `cmd.exe` command — from `cmd`, wrap it as
`powershell -Command "…"`):

```powershell
Find-NetRoute -RemoteIPAddress 192.168.10.247
```

Read the result:

- **`IPAddress`** — the source it will use. If this is *not* an address on the
  expected home NIC (e.g. it's a `10.x` / VPN-assigned address), traffic is
  leaving the wrong adapter. ← the usual smoking gun.
- **`NextHop`** — should be the UCG (`192.168.<own>.1`). Anything else means a
  route is sending the packet somewhere that can't reach the home LAN.
- **`DestinationPrefix`** — which route won. A `/1` prefix here (`0.0.0.0/1` or
  `128.0.0.0/1`) is the fingerprint of a full-tunnel VPN (see Cause A).

Back it up with the full picture:

```powershell
Get-NetAdapter | Format-Table Name, InterfaceDescription, ifIndex, Status
route print          # IPv4 table: default route + any rogue /1 or /16 entries + Persistent Routes
ipconfig /all        # mask, gateway, DNS, and any surprise adapters
```

## Root causes, most likely first

### A. Full-tunnel VPN swallowing all off-subnet traffic — CONFIRMED 2026-07-12

**This is what bit us.** A client on `192.168.30.241` couldn't RDP to
`192.168.0.134`, couldn't use SMB sharing, couldn't resolve Heimdall DNS
(`192.168.10.4`), and couldn't reach Akasha (`192.168.10.247`) even by IP —
while its own subnet and the internet worked. `Find-NetRoute` showed the packet
leaving a **VPN adapter** with source `10.2.18.205` via route
**`128.0.0.0/1` → `10.2.18.1`**.

**Why it produces exactly this pattern:** a full-tunnel VPN installs the route
pair `0.0.0.0/1` + `128.0.0.0/1`. Together they blanket the whole address space
and are *more specific* than the real `0.0.0.0/0` default — so they win without
ever touching the default route (which still innocently points at the LAN
gateway, so `route print` looks normal at a glance). The client's own
`192.168.<own>.0/24` connected route is **more specific still**, so local
traffic stays local — but every other subnet (`192.168.0.x`, `192.168.10.x`) is
funneled into the tunnel. The VPN exit has no route back to the home LAN, so
those subnets are black-holed. Internet still works (that's the tunnel's job),
which is why the failure hides.

**Fix — exclude the home subnets from the tunnel (split-tunnel / bypass rules):**
In the VPN client, add the home network as a bypass/split-tunnel route so LAN
traffic stays on the physical NIC. **PIA (Private Internet Access):** Settings →
**Split Tunnel** → add bypass rules. The plain "Allow LAN traffic" toggle only
frees the client's *own* `/24`; to reach the *other* home subnets you must add
each one explicitly. Cover all home subnets — simplest is the umbrella
**`192.168.0.0/16`**, or list them individually
(`192.168.0.0/24`, `192.168.10.0/24`, `192.168.30.0/24`, …).

Quick proof before reconfiguring: disconnect the VPN (or
`Disable-NetAdapter -InterfaceIndex <ifIndex>` as Admin) and re-run
`Find-NetRoute` — the source should flip to the home NIC and NextHop to the UCG.

### B. Subnet mask too broad (e.g. `/16` instead of `/24`)

If the client's mask is `255.255.0.0`, it believes all of `192.168.0.0/16` is
one local wire and **ARPs off-subnet IPs directly** instead of routing them
through the UCG. Those ARPs die on the wrong VLAN, so only the client's own
`/24` answers. `arp -a` shows incomplete entries for the off-subnet targets;
`ipconfig /all` shows the wrong mask. **Fix:** set `255.255.255.0` (or switch
the adapter to DHCP to match every working host).

### C. Missing / wrong default gateway

Correct mask but no usable `0.0.0.0/0` route (or one pointing at a dead/foreign
gateway): local subnet works, everything off-subnet fails. `route print` shows
the bad or absent default route. **Fix:** correct the gateway, or switch to DHCP.

### D. Rogue static route or virtual-adapter hijack

A leftover `route -p add`, or a virtual adapter (VirtualBox host-only, VMware,
Hyper-V vEthernet, WSL, Tailscale/ZeroTier) advertising an overlapping
`192.168.x` subnet, can steal traffic for specific ranges. `route print`
(check the **Persistent Routes** section) and the `Get-NetAdapter` list reveal
it. **Fix:** delete the route (`route -p delete <dest>`) or disable/reconfigure
the offending adapter.

## After it works — check SMB/RDP separately

Restoring routing fixes reachability. If **Windows File & Printer Sharing
(SMB)** or **RDP** is still flaky once you can reach the target by IP, that's a
separate layer: the adapter's network profile must be **Private**, not Public
(`Get-NetConnectionProfile` → `Set-NetConnectionProfile -NetworkCategory
Private`), and the target host's firewall must allow inbound SMB (445) / RDP
(3389).
