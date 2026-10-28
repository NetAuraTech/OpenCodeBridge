# cloudflared Named Tunnel Research

## Overview

This fact sheet documents the configuration, behavior, and operational aspects of `cloudflared` for named tunnels (also known as "locally-managed tunnels"). The research addresses the requirements for running a Cloudflare tunnel on a specific domain with Cloudflare Access, suitable for bridging to a localhost-only server.

---

## 1. Tunnel Run Mode: Token vs Named Tunnel

### Token Mode (Remotely-managed)
- Requires a token obtained from the Cloudflare dashboard or API
- Used when creating tunnels remotely via `cloudflared tunnel create` with `--token` flag
- **Not applicable** for this use case

### Named Tunnel Mode (Locally-managed)
- Tunnel identified by a human-readable name (e.g., `my-tunnel`)
- Requires running `cloudflared tunnel create <NAME>` during initial setup
- Tunnel UUID is generated and stored in credentials file
- **Relevant for this use case**

**Command for creating a named tunnel:**
```bash
cloudflared tunnel create <NAME>
```

**Running a named tunnel:**
```bash
# Using tunnel name
cloudflared tunnel run <NAME>

# Or using UUID
cloudflared tunnel run <UUID>

# With custom config file
cloudflared tunnel --config /path/to/config.yml run <NAME>
```

---

## 2. Configuration Files

### Credentials File
- **Location**: Auto-generated in `~/.cloudflared/` directory (Linux)
- **Format**: JSON file
- **Contents**: Tunnel UUID, connection metadata
- **Example path**: `/root/.cloudflared/6ff42ae2-765d-4adf-8112-31c55c1551ef.json`

### Main Configuration File
- **Location**: Default `~/.cloudflared/config.yml` or specified via `--config` flag
- **Required when**: Using ingress routes to define hostname-to-service mappings
- **Format**: YAML

**Basic configuration structure:**
```yaml
tunnel: <TUNNEL-UUID>
credentials-file: /root/.cloudflared/<TUNNEL-UUID>.json

ingress:
  - hostname: app.example.com
    service: http://localhost:8000
  - hostname: example.com
    service: https://localhost:8000
  - service: http_status:404  # Catch-all rule (required)
```

### Credentials File (For Published Applications)
When using ingress rules, you may need to explicitly specify the credentials file:
```yaml
tunnel: 6ff42ae2-765d-4adf-8112-31c55c1551ef
credentials-file: /root/.cloudflared/6ff42ae2-765d-4adf-8112-31c55c1551ef.json

ingress:
  - hostname: gitlab.widgetcorp.tech
    service: http://localhost:80
  - service: http_status:404
```

### Configuration File Requirements
- Must include a **catch-all rule** at the end of ingress rules
- If no configuration file exists, `cloudflared` proxies outbound traffic on port 8080
- Ingress rules are evaluated **top to bottom**; first match wins

### Validation Commands
```bash
# Validate ingress rules
cloudflared tunnel ingress validate

# Test a specific URL against ingress rules
cloudflared tunnel ingress rule https://foo.example.com
```

---

## 3. Ingress Routes

### Route Definition
Ingress rules map public hostnames to local services:
```yaml
ingress:
  - hostname: app.example.com
    service: http://localhost:8080
```

### Route Types
1. **Hostname-based**:
   ```yaml
   - hostname: example.com
     service: https://localhost:8000
   ```

2. **Path-based (regex)**:
   ```yaml
   - hostname: static.example.com
     path: \.(jpg|png|css|js)$
     service: https://localhost:8001
   ```

3. **Wildcard hostname**:
   ```yaml
   - hostname: "*.example.com"
     service: https://localhost:8002
   ```

4. **Catch-all (required)**:
   ```yaml
   - service: https://localhost:8003
   ```
   Or explicitly:
   ```yaml
   - service: http_status:404
   ```

### Path Normalization (Security Feature)
- **Available in**: Version 2026.10.0+
- **Default**: Off
- **Purpose**: Normalizes URLs before matching (removes `.` and `..` segments, converts backslashes, merges repeated slashes)
- **Important for**: Rules requiring Cloudflare Access JWT validation
- **Enable with**: `--disable-path-normalization=false`

### Traffic Flow
1. `cloudflared` receives incoming request
2. Evaluates ingress rules **top to bottom**
3. Matches by hostname, path, or both
4. Routes matched traffic to specified origin
5. Last rule **must** be a catch-all

---

## 4. Process Behavior & Lifecycle

### Automatic Reconnection
- When `cloudflared` process stops (`Down` status in dashboard)
- When network connectivity is lost
- Retries with exponential backoff: **1, 2, 4, 8, 16, 32 seconds** (up to 64s)
- Falls back from QUIC to HTTP/2 if QUIC fails

### Connection Protocol
- **Default**: `auto` (tries QUIC first, falls back to HTTP/2)
- **Options**: `auto`, `quic`, `http2`
- **QUIC port**: 7844 (UDP)
- **HTTP/2 port**: 80 (TCP)

### Exit Codes & Signals
- **SIGINT/SIGTERM**: 
  - Enters grace period (default 30s)
  - Stops accepting new requests
  - Waits for in-progress requests to complete
  - Shuts down after grace period or second signal
  - **Configurable via**: `--grace-period` or `TUNNEL_GRACE_PERIOD`

- **Exit codes**: Not explicitly documented; process behavior follows standard Unix conventions

### Error States

| Status | Meaning | Resolution |
|--------|----------|------------|
| `Inactive` | Tunnel created but never run | Start `cloudflared` to establish connection |
| `Down` | Process stopped | Restart `cloudflared` service/process |
| `Degraded` | Some connections failed | Check logs and firewall rules |
| `Healthy` | Four active connections | Normal operation |

---

## 5. Auto-Update Behavior

### Default Behavior
- **Enabled by default** for standalone binaries running as services
- **Update frequency**: `--autoupdate-freq` (default: 24 hours)
- **Process**: Spawns new process, old process exits (no wait)
- **Impact**: Active connections may be interrupted

### Limitations
- ❌ **Does NOT work** on Windows
- ❌ **Does NOT work** with package manager installations (apt, etc.)
- ❌ **Does NOT work** in interactive terminal sessions

### Update Commands
```bash
# Manual update
cloudflared update

# Run with no auto-update
cloudflared tunnel --no-autoupdate run --token <TOKEN>
```

### Zero-Downtime Updates
**Option A: Multiple instances**
1. Install new `cloudflared` instance with new tunnel
2. Configure to same origin service
3. Swap DNS priority
4. Remove old instance

**Option B: Cloudflare Load Balancer**
1. Add new instance as pool member
2. Swap priority
3. Remove old instance

**Trade-off**: New instance drops long-lived connections (WebSocket, SSH) and UDP flows; UDP modeled on timeouts

---

## 6. Recommended Production Configuration

### For This Use Case (Localhost Server Bridge)

**1. Run as systemd service (Linux)**

```ini
[Unit]
Description=Cloudflare Tunnel for app.example.com
After=network.target

[Service]
TimeoutStartSec=0
Type=notify
ExecStart=/usr/local/bin/cloudflared tunnel --loglevel info --logfile /var/log/cloudflared/cloudflared.log run --config /etc/cloudflared/config.yml
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
```

**2. Disable auto-update in production**

```ini
ExecStart=/usr/local/bin/cloudflared tunnel --no-autoupdate --loglevel info --logfile /var/log/cloudflared/cloudflared.log run --config /etc/cloudflared/config.yml
```

Or configure update frequency:
```ini
ExecStart=/usr/local/bin/cloudflared tunnel --autoupdate-freq 168h --no-autoupdate run ...
```

**3. Custom configuration file**

```yaml
tunnel: <TUNNEL-UUID>
credentials-file: /etc/cloudflared/<TUNNEL-UUID>.json

ingress:
  - hostname: app.example.com
    service: http://127.0.0.1:3000
  - service: http_status:404
```

---

## 7. Security Considerations

### Path Normalization
- **Recommended**: Enable in 2026.10.0+ when using Access JWT validation
- **Command**: `--disable-path-normalization=false`

### Localhost Binding
- **Binding services to `127.0.0.1`** prevents binding conflicts
- Recommended for:
  ```yaml
  service: http://127.0.0.1:3000
  ```

### Firewall Rules
- Allow outbound UDP:port 7844 (preferred) or TCP:port 80/443
- Cloudflare Tunnel IPs (e.g., 198.41.192.227)

---

## Newly-Surfaced Fog

### Questions for Further Research
1. **Credential file location**: Is the credentials file always in `~/.cloudflared/` or configurable?
2. **Multiple tunnels**: Can one `cloudflared` process manage multiple tunnels via configuration?
3. **DNS TTL management**: Does `cloudflared tunnel route dns` create records with specific TTLs that affect failover?
4. **Access integration**: How does ingress interact with Cloudflare Access JWT validation? Does it require additional configuration?
5. **Metrics and monitoring**: The `--metrics` flag (default `127.0.0.1:20241–20245`) - what Prometheus metrics are exposed?

---

## Sources

1. [Run parameters · Cloudflare Docs](https://developers.cloudflare.com/tunnel/reference/run-parameters/)
2. [Configuration file · Cloudflare Docs](https://developers.cloudflare.com/tunnel/features/locally-managed-tunnels/configuration-file/)
3. [Configuration · Cloudflare Docs](https://developers.cloudflare.com/tunnel/configuration/)
4. [Create a locally-managed tunnel · Cloudflare Docs](https://developers.cloudflare.com/tunnel/features/locally-managed-tunnels/create-local-tunnel/)
5. [Tunnel tokens · Cloudflare Docs](https://developers.cloudflare.com/tunnel/reference/tunnel-tokens/)
6. [Routing · Cloudflare Docs](https://developers.cloudflare.com/tunnel/concepts/routing/)
7. [Useful commands · Cloudflare One docs](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/do-more-with-tunnels/local-management/tunnel-useful-commands/)
8. [Update cloudflared · Cloudflare Docs](https://developers.cloudflare.com/tunnel/guides/update-cloudflared/)
9. [Run parameters · Cloudflare One docs](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/configure-tunnels/run-parameters/)
