# Cloudflare dashboard setup

What the app does and what you still do yourself in the Cloudflare
dashboard, for a tunnel that is exposed on a public hostname and
protected by Cloudflare Access.

The app (assisted setup, ADR-0003) handles the local side on its own:

- the tunnel itself: `cloudflared tunnel login` (browser consent) and
  `cloudflared tunnel create <name>`, run by the app against its
  app-managed cloudflared binary;
- the credentials file `~/.cloudflared/<tunnel-uuid>.json`, written by
  cloudflared;
- the app-owned config `~/.config/opencodebridge/cloudflared.yml`,
  including the ingress that routes the hostname to the bridge port.

Two steps live in the dashboard and are yours to do. The wizard lists
them with the exact values to copy for your tunnel; this document is
the generic reference.

## 1. DNS route (public hostname)

Point your hostname at the tunnel with a **proxied** CNAME, in the
public DNS zone that owns the hostname.

Dashboard → *\<your-zone\>* → **DNS** → **Records** → **Add record**:

| Field    | Value                                          |
| -------- | ---------------------------------------------- |
| Type     | `CNAME`                                        |
| Name     | the hostname's label (e.g. `myapp`)            |
| Target   | `<tunnel-uuid>.cfargotunnel.com`               |
| Proxied  | **ON** (orange cloud)                          |
| TTL      | Auto                                           |

- **Proxied is required**: it sends traffic through the Cloudflare
  edge, which is what makes the Access application below apply. An
  orange-cloud (DNS-only) CNAME would bypass it.
- The tunnel's own **Routes** tab is the same thing under a different
  name (it creates an equivalent record for the public hostname).
  Leave it alone — a single CNAME record is enough. The tab's private
  DNS / IP routes are a different mechanism, not needed for a public
  hostname.
- After saving, the hostname may take a minute or two to resolve
  publicly; routers can also serve a cached negative answer for a
  while.

## 2. Cloudflare Access application

Protect the hostname so the tunnel is never open to the internet. The
app refuses to start cloudflared until an unauthenticated request is
challenged, so this step is what unblocks the tunnel.

Dashboard → **Zero Trust** → **Access** → **Applications** →
**Add an application** → **Self-hosted**:

| Field                          | Value                                   |
| ------------------------------ | --------------------------------------- |
| Name                           | anything (e.g. `OpenCodeBridge`)        |
| Service URL                    | `https://<hostname>` — no path, no port |
| Accept all available identity providers | **on**            |
| Session Duration               | default (24h)                           |

Then create the policy — **Access policies** → **Create new policy**:

| Field   | Value                                                          |
| ------- | ---------------------------------------------------------------- |
| Action  | **Allow**                                                        |
| Include (OR) | **Emails** — your Cloudflare account email(s)             |

Do not associate an existing policy from the dropdown unless you
intend to: whatever you attach is what gets enforced. **Save policy**,
associate it to the application, then **Create** the application.

## 3. Verify in the app

**Check now** in the app runs the precondition pass. The tunnel starts
only when every step is met:

| Step        | What the app checks                                            |
| ----------- | -------------------------------------------------------------- |
| credentials | `~/.cloudflared/<uuid>.json` exists and carries a `TunnelID`   |
| config      | `~/.config/opencodebridge/cloudflared.yml` parses (app-owned)   |
| dns_route   | the hostname resolves publicly                                  |
| access      | an unauthenticated `GET https://<hostname>/` is challenged (a 302 to the Access login, or 401/403); a 2xx means the tunnel would be open, and the app stays stopped |
| binary      | the app-managed cloudflared binary is present                  |

When everything is green the app starts cloudflared, waits for the
edge connections, and the status flips to *Tunnel up*.

Order does not matter: create the Access application and the DNS route
in any order — the app simply waits for both, and never exposes the
tunnel half-configured.
