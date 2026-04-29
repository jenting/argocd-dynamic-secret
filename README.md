# argocd-dynamic-secret

Proof-of-concept Docker Compose environment that demonstrates **dynamic ArgoCD API tokens** backed by HashiCorp Vault's OIDC Identity Provider. The client authenticates to Vault, receives a short-lived OIDC ID token containing group claims, and ArgoCD maps those groups to RBAC roles — eliminating static credentials entirely.

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  docker compose network (poc-network)                                        │
│                                                                              │
│  ┌──────────────────────────────────────────────────────────────────────┐    │
│  │  Vault :8200                                                         │    │
│  │  ┌───────────────────────────────────────────────────────────────┐   │    │
│  │  │  OIDC Identity Provider                                        │   │    │
│  │  │  • RS256 signing key     • groups / profile / email scopes    │   │    │
│  │  │  • authorize endpoint    • token endpoint (PKCE)              │   │    │
│  │  │  • JWKS endpoint (for ArgoCD to verify token signatures)      │   │    │
│  │  └────────────────────────────┬──────────────────────────────────┘   │    │
│  └───────────────────────────────│──────────────────────────────────────┘    │
│                                  │                                            │
│       1. userpass login          │ 2. PKCE authorize (headless)              │
│          → Vault token           │    → auth code                            │
│                              3. token exchange                                │
│                                  │    → ID token (groups, email)             │
│                                  │                                            │
│  ┌───────────────────┐   ┌───────┴────────────────────────────────────────┐  │
│  │  ArgoCD (k3s)     │   │  client container                               │  │
│  │  :8080 (NodePort) │◄──│  4. POST /api/v1/session  {token: <id_token>}  │  │
│  │                   │   │     → ArgoCD validates via Vault JWKS           │  │
│  │                   │◄──│  5. ArgoCD session token → CRUD applications    │  │
│  └───────────────────┘   └────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Dynamic Secret Flow (client)

```
Client                  Vault (OIDC Provider)        ArgoCD
  │                            │                        │
  │── 1. userpass login ───────►│                        │
  │◄── Vault token (TTL=1h) ───│                        │
  │                            │                        │
  │── 2. authorize (PKCE) ─────►│                        │
  │   X-Vault-Token: <token>   │                        │
  │◄── 302 redirect + auth code│                        │
  │                            │                        │
  │── 3. token exchange ────────►│                        │
  │   code + code_verifier     │                        │
  │◄── OIDC ID token (RS256) ──│                        │
  │   claims: groups, email     │                        │
  │                            │                        │
  │── 4. POST /api/v1/session ──────────────────────────►│
  │      { token: <id_token> } │  verifies via JWKS     │
  │◄── ArgoCD session token ─────────────────────────── │
  │                            │                        │
  │── 5. Bearer: session_token ─────────────────────────►│
  │   create/update/sync/delete application             │
```

### Components

| Service | Image | Role |
|---------|-------|------|
| `vault` | `hashicorp/vault:1.15` | OIDC Identity Provider (dev mode): signing key, scopes, provider endpoint, userpass auth |
| `k3s` | `rancher/k3s:v1.28.5-k3s1` | Lightweight Kubernetes (runs ArgoCD) |
| `setup` | `alpine:3.19` | One-shot: configures Vault OIDC + AppRole + KV; installs + patches ArgoCD with OIDC config |
| `client` | `alpine:3.19` | One-shot: userpass → PKCE OIDC flow → ID token → ArgoCD session → CRUD |

### Why this demonstrates "dynamic secrets"

| Property | Details |
|----------|---------|
| **No static ArgoCD credentials** | The client never holds a long-lived ArgoCD token — it obtains a session on every run |
| **Short-lived ID token** | Vault issues an OIDC ID token with a configurable TTL (default 30 min) — it auto-expires |
| **Group-based access** | The `groups` claim in the ID token drives ArgoCD RBAC — no static role assignments |
| **Vault JWKS verification** | ArgoCD fetches Vault's JWKS to verify token signatures — no shared secret required |
| **PKCE for code security** | Authorization code flow uses PKCE (S256), preventing code interception |

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
3. Run **setup** – configures Vault OIDC provider + AppRole; installs ArgoCD; patches ArgoCD ConfigMaps with Vault OIDC settings
4. Run **client** – userpass login → PKCE OIDC authorize → ID token (with `groups`) → ArgoCD session → CRUD

Watch progress in real time:

```bash
docker compose logs -f setup    # watch setup steps
docker compose logs -f client   # watch the OIDC dynamic-secret client output
```

---

## Access

| Service | URL | Credentials |
|---------|-----|-------------|
| ArgoCD UI | http://localhost:8080 | `admin` / see client summary output |
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

| Resource | Path / Value |
|----------|------|
| Signing key | `identity/oidc/key/argocd-key` (RS256, 24 h rotation) |
| Scopes | `identity/oidc/scope/{groups,profile,email}` |
| OIDC Client | `identity/oidc/client/argocd` (`id_token_ttl=30m`) |
| OIDC Provider | `identity/oidc/provider/argocd` |
| Discovery URL | `http://vault:8200/v1/identity/oidc/provider/argocd/.well-known/openid-configuration` |
| JWKS URI | `http://vault:8200/v1/identity/oidc/provider/argocd/.well-known/keys` |
| Demo user | `argocd-admin` / `password` (userpass auth) |
| Demo group | `argocd-admins` (internal group, member: `argocd-admin` entity, present in `groups` claim) |
| AppRole role | `auth/approle/role/argocd-client` (available as additional auth option) |

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
| `scripts/vault-setup.sh` | Configures Vault OIDC Provider (key → scopes → client → provider → userpass user → entity → group) + AppRole |
| `scripts/argocd-install.sh` | Installs ArgoCD in k3s, patches argocd-server to run `--insecure`, creates NodePort service |
| `scripts/argocd-configure.sh` | Patches `argocd-cm` + `argocd-rbac-cm` with Vault OIDC settings; restarts argocd-server |
| `scripts/client.sh` | Client: userpass login → PKCE authorize → ID token (groups) → ArgoCD session → create/update/sync/delete |

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

### OIDC ID token expired
The Vault OIDC ID token has a 30-minute TTL (`id_token_ttl=30m` on the OIDC client). Re-run the client to get a fresh token:
```bash
docker compose stop client && docker compose up client
```

### ArgoCD session creation fails (client Step 6)
- Ensure ArgoCD's `argocd-cm` OIDC config has been applied (re-run `setup`)
- Check that the `issuer` in `argocd-cm` exactly matches `VAULT_OIDC_ISSUER` in `vault-oidc.env`
- Verify Vault's JWKS is reachable from ArgoCD: `curl http://vault:8200/v1/identity/oidc/provider/argocd/.well-known/keys`