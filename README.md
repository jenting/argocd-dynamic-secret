# argocd-dynamic-secret

Proof-of-concept Docker Compose environment that demonstrates **dynamic ArgoCD API tokens** backed by HashiCorp Vault acting as the OIDC Identity Provider.

## Overview

```
┌──────────────────────────────────────────────────────────────────────┐
│  docker compose network (poc-network)                                │
│                                                                      │
│  ┌─────────────┐        OIDC Provider         ┌──────────────────┐  │
│  │   Vault      │◄────────────────────────────►│  ArgoCD (k3s)    │  │
│  │  :8200       │  Discovery / JWKS / Token    │  :8080 (NodePort)│  │
│  └──────┬──────┘                              └──────────────────┘  │
│         │                                                            │
│  userpass auth                                                       │
│         │                                                            │
│  ┌──────▼──────────────────────────────────────────────────────┐    │
│  │  demo container                                              │    │
│  │  1. Login to Vault  → short-lived Vault token               │    │
│  │  2. Get OIDC token  → JWT with groups/email claims (dynamic) │    │
│  │  3. Use ArgoCD API token (TTL=1h) → create/update/delete app │    │
│  └─────────────────────────────────────────────────────────────┘    │
└──────────────────────────────────────────────────────────────────────┘
```

### Components

| Service | Image | Role |
|---------|-------|------|
| `vault` | `hashicorp/vault:1.15` | OIDC Identity Provider (dev mode) |
| `k3s` | `rancher/k3s:v1.28.5-k3s1` | Lightweight Kubernetes (runs ArgoCD) |
| `setup` | `alpine:3.19` | One-shot: configures Vault OIDC + installs/configures ArgoCD |
| `demo` | `alpine:3.19` | One-shot: runs the full dynamic-secret demo flow |

### Dynamic Secret Flow

1. **Vault issues a short-lived OIDC ID token** on behalf of the authenticated user.
   The token includes `groups` and `email` claims (expiry controlled by Vault).
2. **ArgoCD trusts Vault** as an OIDC provider (configured via `argocd-cm`).
   Group-to-role mapping is in `argocd-rbac-cm`:
   `g, argocd-admins, role:admin`
3. **ArgoCD generates a session/API token** after verifying the OIDC token against
   Vault's JWKS endpoint.
4. **The API token** (with configurable TTL) is used for
   `create / read / update / sync / delete` ArgoCD Application API calls.

---

## Prerequisites

| Tool | Minimum version | Notes |
|------|----------------|-------|
| Docker Engine | 24.x | |
| Docker Compose | v2.20+ | `service_completed_successfully` condition required |
| Internet access | – | Downloads ArgoCD manifests (~20 MB) and kubectl binary |

> **macOS / Windows:** Docker Desktop 4.x satisfies both requirements.

---

## Quick Start

```bash
# Clone and start everything
git clone https://github.com/jenting/argocd-dynamic-secret.git
cd argocd-dynamic-secret
docker compose up
```

Docker Compose will:
1. Start **Vault** (dev mode, root token = `root`)
2. Start **k3s** (Kubernetes)
3. Run **setup** – configures Vault OIDC, installs ArgoCD, patches ArgoCD ConfigMaps, generates an API token
4. Run **demo** – executes the full dynamic-secret flow and prints a summary

Watch progress in real time:

```bash
docker compose logs -f setup   # watch setup steps
docker compose logs -f demo    # watch the demo output
```

---

## Access

| Service | URL | Credentials |
|---------|-----|-------------|
| ArgoCD UI | http://localhost:8080 | `admin` / see demo summary |
| Vault UI | http://localhost:8200 | token: `root` |
| Kubernetes API | https://localhost:6443 | kubeconfig in `k3s-output` volume |

### Browser OIDC login (ArgoCD)

Open **http://localhost:8080** and click **"LOG IN VIA VAULT"**.
You will be redirected to the Vault OIDC authorization page.
Log in with `argocd-admin` / `password`.
Vault redirects back to ArgoCD with an OIDC code, and ArgoCD exchanges it
for an ID token, verifying the `argocd-admins` group membership to grant
`role:admin` access.

> **Note:** For the browser OIDC redirect to work, you need `vault` to be
> resolvable from your browser.  The simplest way is to add an entry to
> `/etc/hosts`:
> ```
> 127.0.0.1  vault
> ```
> Then set `ARGOCD_REDIRECT_URI=http://localhost:8080/auth/callback` (already
> the default).

---

## Configuration Reference

### Vault (OIDC Provider)

| Resource | Path |
|----------|------|
| Signing key | `identity/oidc/key/argocd-key` (RS256, 24 h rotation) |
| Scopes | `identity/oidc/scope/{groups,profile,email}` |
| Client | `identity/oidc/client/argocd` |
| Provider | `identity/oidc/provider/argocd` |
| Discovery URL | `http://vault:8200/v1/identity/oidc/provider/argocd/.well-known/openid-configuration` |
| Demo user | `argocd-admin` / `password` (userpass auth) |
| Demo group | `argocd-admins` (internal group, member: `argocd-admin` entity) |

### ArgoCD (`argocd-cm` patch)

```yaml
oidc.config: |
  name: Vault
  issuer: http://vault:8200/v1/identity/oidc/provider/argocd
  clientID: <auto-generated by Vault>
  clientSecret: <auto-generated by Vault>
  requestedScopes:
  - openid
  - profile
  - email
  - groups
  requestedIDTokenClaims:
    groups:
      essential: true
```

### ArgoCD RBAC (`argocd-rbac-cm` patch)

```csv
g, argocd-admins, role:admin
```

```yaml
policy.default: "role:readonly"
scopes: "[groups]"
```

---

## Scripts

| Script | Purpose |
|--------|---------|
| `scripts/setup.sh` | Master orchestrator; installs kubectl, fixes kubeconfig, calls sub-scripts |
| `scripts/vault-setup.sh` | Configures Vault Identity OIDC Provider (key → scopes → client → provider → user → entity → group) |
| `scripts/argocd-install.sh` | Installs ArgoCD in k3s, patches argocd-server to run `--insecure`, creates NodePort service |
| `scripts/argocd-configure.sh` | Patches `argocd-cm` + `argocd-rbac-cm`, restarts argocd-server, creates API token |
| `scripts/demo.sh` | End-to-end demo: Vault login → OIDC token → ArgoCD API token → create/update/sync/delete app |

---

## Cleanup

```bash
docker compose down -v   # removes containers AND named volumes (Kubernetes data)
```

---

## Troubleshooting

### setup container exits with error
```bash
docker compose logs setup
```
Common causes:
- k3s took too long to start – re-run `docker compose up`
- Internet not reachable – ArgoCD manifests could not be downloaded

### ArgoCD OIDC login fails in browser
- Ensure `vault` resolves to `127.0.0.1` in your `/etc/hosts`
- Check that `ARGOCD_REDIRECT_URI` matches the URL you use in the browser

### Vault token expired
The root token (`root`) never expires in dev mode. User tokens (`argocd-admin`) have the default lease (32 days in dev mode).

### ArgoCD API token expired
ArgoCD API tokens in this PoC have a 1-hour TTL. Re-run the setup to generate a new one:
```bash
docker compose stop setup demo && docker compose up setup demo
```