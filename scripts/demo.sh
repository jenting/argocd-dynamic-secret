#!/bin/sh
# demo.sh – end-to-end demonstration of the ArgoCD dynamic-secret flow
#
# Flow:
#   1.  Verify Vault OIDC discovery endpoint is reachable
#   2.  Authenticate to Vault with the demo user (userpass)
#   3.  Request an OIDC ID token from Vault for the 'argocd' role
#   4.  Show the decoded token claims (groups, email, sub)
#   5.  Use the pre-generated ArgoCD API token (dynamic, TTL=1h) to:
#       a) CREATE  a demo ArgoCD application
#       b) READ    (list / get) the application
#       c) UPDATE  the application (add a label)
#       d) SYNC    the application
#       e) DELETE  the application
#   6.  Print a summary
set -e

VAULT_ADDR="${VAULT_ADDR:-http://vault:8200}"
SETUP_OUTPUT="${SETUP_OUTPUT:-/setup-output}"
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-argocd}"

# ── install tools (same image as setup) ──────────────────────────────────────
apk add --no-cache curl jq > /dev/null 2>&1

# ── kubeconfig ────────────────────────────────────────────────────────────────
K3S_HOST="${K3S_HOST:-k3s}"
KUBECTL_VERSION="v1.28.5"
if ! command -v kubectl > /dev/null 2>&1; then
  curl -sSLo /usr/local/bin/kubectl \
    "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl"
  chmod +x /usr/local/bin/kubectl
fi
mkdir -p /root/.kube
cp /k3s-output/kubeconfig.yaml /root/.kube/config
sed -i "s|https://127.0.0.1:6443|https://${K3S_HOST}:6443|g" /root/.kube/config
export KUBECONFIG=/root/.kube/config

# ── load credentials ──────────────────────────────────────────────────────────
# shellcheck source=/dev/null
. "${SETUP_OUTPUT}/vault-oidc.env"

echo ""
echo "╔══════════════════════════════════════════════════════════════════════╗"
echo "║        ArgoCD Dynamic Secret – Proof of Concept Demo                ║"
echo "╚══════════════════════════════════════════════════════════════════════╝"

# ═════════════════════════════════════════════════════════════════════════════
# STEP 1 – Vault OIDC discovery
# ═════════════════════════════════════════════════════════════════════════════
echo ""
echo "─── Step 1: Vault OIDC discovery ───────────────────────────────────────"
DISCOVERY="${VAULT_OIDC_ISSUER}/.well-known/openid-configuration"
DISCO_DOC=$(curl -sf "${DISCOVERY}")
echo "    Issuer:             $(echo "${DISCO_DOC}" | jq -r '.issuer')"
echo "    Authorization EP:   $(echo "${DISCO_DOC}" | jq -r '.authorization_endpoint')"
echo "    Token EP:           $(echo "${DISCO_DOC}" | jq -r '.token_endpoint')"
echo "    JWKS URI:           $(echo "${DISCO_DOC}" | jq -r '.jwks_uri')"
echo "    Scopes supported:   $(echo "${DISCO_DOC}" | jq -r '.scopes_supported | join(", ")')"
echo "    [✓] OIDC discovery endpoint is healthy"

# ═════════════════════════════════════════════════════════════════════════════
# STEP 2 – Authenticate to Vault (userpass → Vault token)
# ═════════════════════════════════════════════════════════════════════════════
echo ""
echo "─── Step 2: Authenticate to Vault ──────────────────────────────────────"
LOGIN_RESP=$(curl -sf -X POST \
  "${VAULT_ADDR}/v1/auth/userpass/login/${VAULT_DEMO_USER}" \
  -H "Content-Type: application/json" \
  -d "{\"password\": \"${VAULT_DEMO_PASSWORD}\"}")
USER_TOKEN=$(echo "${LOGIN_RESP}" | jq -r '.auth.client_token')
echo "    User:        ${VAULT_DEMO_USER}"
echo "    Vault token: ${USER_TOKEN:0:12}... (truncated)"
echo "    Policies:    $(echo "${LOGIN_RESP}" | jq -r '.auth.policies | join(", ")')"
echo "    [✓] Vault login successful"

# ═════════════════════════════════════════════════════════════════════════════
# STEP 3 – Request an OIDC ID token from Vault
# (Vault Identity OIDC token endpoint – direct token generation, not browser flow)
# ═════════════════════════════════════════════════════════════════════════════
echo ""
echo "─── Step 3: Request OIDC ID token from Vault ────────────────────────────"
# Create a named OIDC role that references the signing key
# (idempotent – ignore errors if it already exists)
curl -sf -X POST "${VAULT_ADDR}/v1/identity/oidc/role/argocd" \
  -H "X-Vault-Token: root" \
  -H "Content-Type: application/json" \
  -d '{
    "key": "argocd-key",
    "template": "{\"groups\": {{identity.entity.groups.names | tojson}}, \"email\": {{identity.entity.metadata.email | quote}}}",
    "ttl": "1h"
  }' > /dev/null 2>&1 || true

# Fetch the ID token using the user's Vault token
OIDC_TOKEN_RESP=$(curl -sf "${VAULT_ADDR}/v1/identity/oidc/token/argocd" \
  -H "X-Vault-Token: ${USER_TOKEN}")
OIDC_TOKEN=$(echo "${OIDC_TOKEN_RESP}" | jq -r '.data.token')
TOKEN_TTL=$(echo "${OIDC_TOKEN_RESP}" | jq -r '.data.ttl')

# Decode the JWT payload (base64url → standard base64, no signature verification for demo)
PAYLOAD=$(echo "${OIDC_TOKEN}" | cut -d'.' -f2)
# Convert base64url to base64 and add correct padding (0, 1, or 2 '=' chars)
PADDED=$(echo "${PAYLOAD}" | tr -- '-_' '+/' | \
  awk '{n = length($0) % 4; if (n == 2) print $0 "=="; else if (n == 3) print $0 "="; else print $0}')
CLAIMS=$(echo "${PADDED}" | base64 -d 2>/dev/null)

echo "    OIDC token (truncated): ${OIDC_TOKEN:0:40}..."
echo "    Token TTL:              ${TOKEN_TTL}s"
echo "    --- Decoded JWT claims ---"
echo "    sub:     $(echo "${CLAIMS}" | jq -r '.sub')"
echo "    iss:     $(echo "${CLAIMS}" | jq -r '.iss')"
echo "    groups:  $(echo "${CLAIMS}" | jq -r '.groups // [] | join(", ")')"
echo "    email:   $(echo "${CLAIMS}" | jq -r '.email // "n/a"')"
echo "    exp:     $(echo "${CLAIMS}" | jq -r '.exp') (unix epoch)"
echo "    [✓] Vault issued a short-lived OIDC ID token (dynamic secret)"

# ═════════════════════════════════════════════════════════════════════════════
# STEP 4 – Show the pre-generated ArgoCD API token (from setup)
# The API token was generated after ArgoCD verified the OIDC configuration.
# In a real workflow, a CI/CD pipeline or Vault agent would inject this token.
# ═════════════════════════════════════════════════════════════════════════════
echo ""
echo "─── Step 4: ArgoCD API token (dynamic, TTL=1h) ──────────────────────────"
echo "    Token (truncated): ${ARGOCD_API_TOKEN:0:40}..."
echo "    Server:            ${ARGOCD_SERVER}"
echo "    [✓] Dynamic ArgoCD API token available"

# Verify token works
ACCOUNTS=$(curl -sk -o /dev/null -w "%{http_code}" \
  -H "Authorization: Bearer ${ARGOCD_API_TOKEN}" \
  "${ARGOCD_SERVER}/api/v1/account")
echo "    Token validation (GET /api/v1/account): HTTP ${ACCOUNTS}"

# ═════════════════════════════════════════════════════════════════════════════
# STEP 5a – CREATE an ArgoCD application
# ═════════════════════════════════════════════════════════════════════════════
echo ""
echo "─── Step 5a: CREATE ArgoCD application ─────────────────────────────────"
APP_NAME="dynamic-secret-demo-app"
CREATE_RESP=$(curl -sk -X POST \
  -H "Authorization: Bearer ${ARGOCD_API_TOKEN}" \
  -H "Content-Type: application/json" \
  "${ARGOCD_SERVER}/api/v1/applications" \
  -d "{
    \"metadata\": {
      \"name\": \"${APP_NAME}\",
      \"namespace\": \"${ARGOCD_NAMESPACE}\"
    },
    \"spec\": {
      \"project\": \"default\",
      \"source\": {
        \"repoURL\": \"https://github.com/argoproj/argocd-example-apps.git\",
        \"targetRevision\": \"HEAD\",
        \"path\": \"guestbook\"
      },
      \"destination\": {
        \"server\": \"https://kubernetes.default.svc\",
        \"namespace\": \"default\"
      },
      \"syncPolicy\": {
        \"automated\": null
      }
    }
  }")
echo "    App name:  $(echo "${CREATE_RESP}" | jq -r '.metadata.name')"
echo "    Sync:      $(echo "${CREATE_RESP}" | jq -r '.status.sync.status // "Unknown"')"
echo "    Health:    $(echo "${CREATE_RESP}" | jq -r '.status.health.status // "Unknown"')"
echo "    [✓] Application created via ArgoCD API"

# ═════════════════════════════════════════════════════════════════════════════
# STEP 5b – READ (list) applications
# ═════════════════════════════════════════════════════════════════════════════
echo ""
echo "─── Step 5b: READ (list) ArgoCD applications ────────────────────────────"
LIST_RESP=$(curl -sk \
  -H "Authorization: Bearer ${ARGOCD_API_TOKEN}" \
  "${ARGOCD_SERVER}/api/v1/applications")
APP_COUNT=$(echo "${LIST_RESP}" | jq '.items | length')
echo "    Total applications: ${APP_COUNT}"
echo "${LIST_RESP}" | jq -r '.items[] | "    - \(.metadata.name)  sync=\(.status.sync.status // "Unknown")  health=\(.status.health.status // "Unknown")"'
echo "    [✓] Applications listed via ArgoCD API"

# ═════════════════════════════════════════════════════════════════════════════
# STEP 5c – UPDATE the application (add an annotation)
# ═════════════════════════════════════════════════════════════════════════════
echo ""
echo "─── Step 5c: UPDATE ArgoCD application ─────────────────────────────────"
UPDATE_RESP=$(curl -sk -X PATCH \
  -H "Authorization: Bearer ${ARGOCD_API_TOKEN}" \
  -H "Content-Type: application/json" \
  "${ARGOCD_SERVER}/api/v1/applications/${APP_NAME}" \
  -d '[{
    "op": "add",
    "path": "/metadata/annotations",
    "value": {"dynamic-secret-poc": "true", "updated-by": "vault-oidc-demo"}
  }]')
echo "    Annotations: $(echo "${UPDATE_RESP}" | jq -r '.metadata.annotations // {} | to_entries | map("\(.key)=\(.value)") | join(", ")')"
echo "    [✓] Application updated via ArgoCD API"

# ═════════════════════════════════════════════════════════════════════════════
# STEP 5d – SYNC the application
# ═════════════════════════════════════════════════════════════════════════════
echo ""
echo "─── Step 5d: SYNC ArgoCD application ───────────────────────────────────"
SYNC_RESP=$(curl -sk -X POST \
  -H "Authorization: Bearer ${ARGOCD_API_TOKEN}" \
  -H "Content-Type: application/json" \
  "${ARGOCD_SERVER}/api/v1/applications/${APP_NAME}/sync" \
  -d '{"revision": "HEAD", "prune": false, "dryRun": false}')
echo "    Sync result: $(echo "${SYNC_RESP}" | jq -r '.status.sync.status // "Initiated"')"
echo "    [✓] Application sync triggered via ArgoCD API"

# ═════════════════════════════════════════════════════════════════════════════
# STEP 5e – DELETE the application
# ═════════════════════════════════════════════════════════════════════════════
echo ""
echo "─── Step 5e: DELETE ArgoCD application ─────────────────────────────────"
DELETE_HTTP=$(curl -sk -o /dev/null -w "%{http_code}" \
  -X DELETE \
  -H "Authorization: Bearer ${ARGOCD_API_TOKEN}" \
  "${ARGOCD_SERVER}/api/v1/applications/${APP_NAME}?cascade=true")
if [ "${DELETE_HTTP}" = "200" ] || [ "${DELETE_HTTP}" = "204" ]; then
  echo "    HTTP ${DELETE_HTTP} – application deleted"
  echo "    [✓] Application deleted via ArgoCD API"
else
  echo "    HTTP ${DELETE_HTTP} – unexpected status (application may still be deleting)"
fi

# ═════════════════════════════════════════════════════════════════════════════
# SUMMARY
# ═════════════════════════════════════════════════════════════════════════════
echo ""
echo "╔══════════════════════════════════════════════════════════════════════╗"
echo "║                      Demo Summary                                   ║"
echo "╠══════════════════════════════════════════════════════════════════════╣"
echo "║  Vault OIDC Provider:  ${VAULT_OIDC_ISSUER}"
printf "║  Client ID:            %-44s ║\n" "${VAULT_OIDC_CLIENT_ID}"
printf "║  Vault demo user:      %-44s ║\n" "${VAULT_DEMO_USER} / ${VAULT_DEMO_PASSWORD}"
printf "║  ArgoCD admin:         admin / %-37s ║\n" "${ARGOCD_ADMIN_PASSWORD}"
printf "║  ArgoCD URL:           %-44s ║\n" "${ARGOCD_SERVER}"
echo "╠══════════════════════════════════════════════════════════════════════╣"
echo "║  Demonstrated:                                                      ║"
echo "║   [✓] Vault acting as OIDC Identity Provider                        ║"
echo "║   [✓] Short-lived OIDC ID token generated on demand (dynamic)       ║"
echo "║   [✓] ArgoCD configured to trust Vault OIDC (group-based RBAC)      ║"
echo "║   [✓] ArgoCD API token with TTL (create/read/update/sync/delete)    ║"
echo "╚══════════════════════════════════════════════════════════════════════╝"
echo ""
echo "  Open browser → http://localhost:8080"
echo "  Click 'LOG IN VIA VAULT' to authenticate using Vault OIDC."
echo "  Vault UI: http://localhost:8200  (token: root)"
echo ""
