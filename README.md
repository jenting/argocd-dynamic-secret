# argocd-dynamic-secret

Proof-of-concept Docker Compose environment that demonstrates **dynamic ArgoCD API tokens** backed by HashiCorp Vault — covering both machine-client access (AppRole + KV) and human browser login (OIDC).

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  docker compose network (poc-network)                                        │
│                                                                              │
│  ┌──────────────────────────────────────────────────────────────────────┐    │
│  │  Vault :8200                                                         │    │
│  │  ┌─────────────────┐  ┌──────────────────┐  ┌─────────────────────┐ │    │
│  │  │  OIDC Provider  │  │  AppRole auth     │  │  KV secret engine   │ │    │
│  │  │  (browser login)│  │  (machine login)  │  │  argocd/api-token   │ │    │
│  │  └────────┬────────┘  └────────┬─────────┘  └──────────┬──────────┘ │    │
│  └───────────│────────────────────│───────────────────────│────────────┘    │
│              │                    │                        │                  │
│              │ JWKS/discovery     │ 1. AppRole login       │ 3. read token    │
│              │                    │    → Vault token(1h)   │                  │
│              ▼                    ▼                        │                  │
│  ┌───────────────────┐   ┌────────────────────────────────▼───────────────┐  │
│  │  ArgoCD (k3s)     │   │  client container                               │  │
│  │  :8080 (NodePort) │◄──│  2. Vault token → read secret/argocd/api-token │  │
│  │                   │   │  4. ArgoCD API token → create/update/delete app │  │
│  └───────────────────┘   └────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Dynamic Secret Flow (client)

```
Client                  Vault                    ArgoCD
  │                       │                         │
  │── AppRole login ──────►│                         │
  │◄── short-lived        │                         │
  │    Vault token (1h) ──│                         │
  │                       │                         │
  │── read KV ────────────►│                         │
  │   secret/argocd/      │                         │
  │   api-token           │                         │
  │◄── ArgoCD API token ──│                         │
  │    (TTL=1h, dynamic)  │                         │
  │                       │                         │
  │── Bearer token ───────────────────────────────►│
  │   create/update/sync/delete application         │
```

### Components

| Service | Image | Role |
|---------|-------|------|
| `vault` | `hashicorp/vault:1.15` | OIDC Provider + AppRole auth + KV secret engine (dev mode) |
| `k3s` | `rancher/k3s:v1.28.5-k3s1` | Lightweight Kubernetes (runs ArgoCD) |
| `setup` | `alpine:3.19` | One-shot: configures Vault (OIDC + AppRole + KV), installs + configures ArgoCD, stores dynamic token in Vault KV |
| `client` | `alpine:3.19` | One-shot client: AppRole login → read token from Vault KV → ArgoCD CRUD |

### Why this demonstrates "dynamic secrets"

| Property | Details |
|----------|---------|
| **No static credentials** | The client holds only AppRole `role_id` / `secret_id`; the ArgoCD API token is never baked into its environment |
| **Short TTL** | The ArgoCD API token has a 1-hour TTL — it auto-expires |
| **Vault as broker** | The token lives in `secret/argocd/api-token` (Vault KV); the client fetches it on every run |
| **Short-lived Vault token** | The AppRole login returns a 1-hour Vault token used only to read from KV |
| **OIDC for humans** | Browser users log into ArgoCD via Vault OIDC with group-based RBAC |

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
3. Run **setup** – configures Vault (OIDC + AppRole + KV), installs ArgoCD, patches ArgoCD ConfigMaps, generates an API token and stores it in Vault KV
4. Run **client** – authenticates to Vault via AppRole, reads the dynamic token from Vault KV, then creates/updates/syncs/deletes an ArgoCD application

Watch progress in real time:

```bash
docker compose logs -f setup    # watch setup steps
docker compose logs -f client   # watch the dynamic-secret client output
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

### Vault (OIDC Provider + AppRole + KV)

| Resource | Path / Value |
|----------|------|
| Signing key | `identity/oidc/key/argocd-key` (RS256, 24 h rotation) |
| Scopes | `identity/oidc/scope/{groups,profile,email}` |
| OIDC Client | `identity/oidc/client/argocd` |
| OIDC Provider | `identity/oidc/provider/argocd` |
| Discovery URL | `http://vault:8200/v1/identity/oidc/provider/argocd/.well-known/openid-configuration` |
| Demo user (OIDC) | `argocd-admin` / `password` (userpass auth) |
| Demo group | `argocd-admins` (internal group, member: `argocd-admin` entity) |
| AppRole role | `auth/approle/role/argocd-client` (token_ttl=1h, secret_id_ttl=10m) |
| Client policy | `sys/policies/acl/argocd-client` (read `secret/data/argocd/api-token`) |
| Dynamic secret | `secret/data/argocd/api-token` (KV v2, ArgoCD API token + metadata) |

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
| `scripts/vault-setup.sh` | Configures Vault OIDC Provider + AppRole auth + generates AppRole credentials |
| `scripts/argocd-install.sh` | Installs ArgoCD in k3s, patches argocd-server to run `--insecure`, creates NodePort service |
| `scripts/argocd-configure.sh` | Patches `argocd-cm` + `argocd-rbac-cm`, restarts argocd-server, creates API token, **stores token in Vault KV** |
| `scripts/client.sh` | Client: AppRole login → read `secret/argocd/api-token` from Vault KV → create/update/sync/delete app |

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
docker compose stop setup client && docker compose up setup client
```

### AppRole secret_id expired
The AppRole `secret_id` has a 10-minute TTL. Re-run setup to generate a new one:
```bash
docker compose stop setup client && docker compose up setup client
```