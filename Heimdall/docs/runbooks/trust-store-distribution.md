# Trust-store distribution — Caddy internal-CA root

> Heimdall's Caddy uses an **internal CA** for `*.lab` hostnames (`tls internal`).
> Every LAN client that wants to reach a `.lab` HTTPS service must trust the
> internal-CA root once. This runbook covers per-OS trust-store import.
>
> Punch list M6 + iter-1 known-concern #9.

## Fetch the root certificate

The Caddy internal-CA root lives inside the Caddy container at:
```
/data/caddy/pki/authorities/local/root.crt
```

This is bind-mounted to:
```
/opt/Homelab/Heimdall/caddy/data/caddy/pki/authorities/local/root.crt
```

Caddy's `:80` listener serves it as `http://heimdall.lab/ca.crt` (or by IP if DNS isn't ready yet):

```bash
curl -fsSL http://192.168.10.4/ca.crt -o caddy-internal-ca.crt
```

The `:80` block is LAN-only — nftables restricts source to `192.168.10.0/24`, and UCG does NOT forward port 80 from WAN. This is intentional.

You can also copy the file directly from Heimdall:

```bash
scp owner@192.168.10.4:/opt/Homelab/Heimdall/caddy/data/caddy/pki/authorities/local/root.crt caddy-internal-ca.crt
```

## Trust the root — per-OS

### macOS (system-wide)

```bash
sudo security add-trusted-cert -d -r trustRoot \
    -k /Library/Keychains/System.keychain \
    caddy-internal-ca.crt
```

Or via Keychain Access GUI: drag the file in, double-click, expand "Trust", set "When using this certificate" to "Always Trust", save.

### macOS (user-only, no sudo)

```bash
security add-trusted-cert -r trustRoot \
    -k ~/Library/Keychains/login.keychain-db \
    caddy-internal-ca.crt
```

### Linux — Ubuntu/Debian (system-wide)

```bash
sudo cp caddy-internal-ca.crt /usr/local/share/ca-certificates/caddy-internal-ca.crt
sudo update-ca-certificates
```

After this, `curl`, `wget`, Python `requests`, Go `net/http`, and any other tool that uses the system CA bundle will trust `*.lab`.

### Linux — RHEL/Fedora/CentOS (system-wide)

```bash
sudo cp caddy-internal-ca.crt /etc/pki/ca-trust/source/anchors/
sudo update-ca-trust
```

### Linux — Arch (system-wide)

```bash
sudo trust anchor --store caddy-internal-ca.crt
```

### Windows — system-wide

PowerShell as Administrator:

```powershell
Import-Certificate -FilePath "caddy-internal-ca.crt" `
    -CertStoreLocation "Cert:\LocalMachine\Root"
```

GUI alternative: double-click the `.crt` file → "Install Certificate" → "Local Machine" → "Place all certificates in the following store" → "Trusted Root Certification Authorities" → Finish.

### Windows — current-user-only (no admin)

```powershell
Import-Certificate -FilePath "caddy-internal-ca.crt" `
    -CertStoreLocation "Cert:\CurrentUser\Root"
```

### iOS / iPadOS

Apple requires a two-step process:

1. **Install the cert** — Mail or AirDrop the `.crt` file to the device. Tap it. Settings prompts to install. Confirm with passcode.
2. **Enable full trust** — Settings → General → About → Certificate Trust Settings → toggle "Enable Full Trust for Root Certificates" for the new cert. (This step is mandatory on iOS 10.3+; without it, the cert is installed but ignored.)

### Android

Modern Android (7.0+) makes this harder than other platforms because user-installed CAs are not trusted by apps by default — only by browsers. To get full trust:

- **Browsers only:** Settings → Security → Encryption & credentials → Install from device storage → CA certificate → select the `.crt`. Confirm the security warning.
- **App-wide trust:** apps must opt into trusting user CAs via their `network_security_config.xml`. Most apps do not. If a specific app needs to reach `.lab` HTTPS, this is a per-app problem. Worst case: switch that app's hostname to a public domain with a public LE cert (per the v1 escape hatch).

### Docker containers / Kubernetes pods

Pods don't share the host's CA trust store; they have their own. If a pod needs to reach a `.lab` HTTPS endpoint, the CA root must be mounted into the pod's filesystem and added to its trust store at build time (or via init-container).

For a `debian:bookworm` or `ubuntu`-based image:

```dockerfile
# In the pod's image build:
COPY caddy-internal-ca.crt /usr/local/share/ca-certificates/
RUN update-ca-certificates
```

For an `alpine`-based image:

```dockerfile
COPY caddy-internal-ca.crt /usr/local/share/ca-certificates/
RUN apk add --no-cache ca-certificates && update-ca-certificates
```

For a Go-based image that uses `crypto/x509`'s default cert pool, the system CA bundle suffices once `update-ca-certificates` runs.

Alternatively, mount the cert via a ConfigMap and configure the application to trust it explicitly (e.g., set `SSL_CERT_FILE` env var, or pass it via a CLI flag). This is the lighter-weight approach for one-off needs.

## Verification

After importing on a client:

```bash
curl -fsS https://komodo.lab | head
# → HTML response, no SSL warning.
```

If you still get a warning, the trust didn't take. Check:

- macOS: Keychain Access shows the cert under "System" or "login" with full trust enabled.
- Linux: `awk -v cmd='openssl x509 -noout -subject' '/BEGIN/{close(cmd)};{print | cmd}' < /etc/ssl/certs/ca-certificates.crt | grep -i caddy` shows the cert.
- Windows: `certmgr.msc` → Trusted Root Certification Authorities → Certificates lists the cert.

## When you'd want to NOT use internal CA

The v1 default is internal CA for all `.lab` hostnames because it eliminates the Let's Encrypt rate-limit cert-loss SPOF. If you need a hostname reachable from devices you don't control (a phone outside the LAN, a guest's laptop, an IoT device's app), flip THAT one hostname to public LE.

Mechanism: edit the relevant Caddyfile block — remove `tls internal`, ensure the domain has a real public DNS record pointing at the UCG WAN IP, and ensure UCG forwards 443 → Heimdall. Caddy will use HTTP-01 ACME against Let's Encrypt automatically. You'll need to add the WAN port-forward for port 80 temporarily (or use DNS-01 via the `caddy-dns/<provider>` plugin — see the [iter-1 escape hatch](../../docs/pipeline-runs/20260517T213331Z-dev-heimdall-finalize/iter-1/04-revision.md)).

Everything else stays `tls internal`. The trust-store distribution burden is bounded to operator-controlled devices.
