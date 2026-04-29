#!/bin/sh
# argocd-configure.sh – patch ArgoCD ConfigMaps with Vault OIDC settings
#
# Steps:
#   1. Read Vault OIDC credentials from /setup-output/vault-oidc.env
#   2. Patch 'argocd-cm' with the OIDC provider config (issuer, clientID, secret, scopes)
#   3. Patch 'argocd-rbac-cm' to map the Vault 'argocd-admins' group to role:admin
#   4. Restart argocd-server so it picks up the new config
#   5. Retrieve the initial admin password and create an API token
#   6. Store the API token in Vault KV (dynamic secret for the client)
#   7. Append credentials to /setup-output/vault-oidc.env
set -e

SETUP_OUTPUT="${SETUP_OUTPUT:-/setup-output}"
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-argocd}"
ARGOCD_URL="${ARGOCD_URL:-http://localhost:8080}"
VAULT_TOKEN="${VAULT_TOKEN:-root}"

# Load Vault OIDC credentials saved by vault-setup.sh
# shellcheck source=/dev/null
. "${SETUP_OUTPUT}/vault-oidc.env"

echo ">>> [argocd-configure] Patching ArgoCD OIDC configuration..."

# ── 1. argocd-cm: OIDC provider + external URL ───────────────────────────────
kubectl patch configmap argocd-cm \
  -n "${ARGOCD_NAMESPACE}" \
  --type merge \
  -p "{
    \"data\": {
      \"url\": \"${ARGOCD_URL}\",
      \"oidc.config\": \"name: Vault\nissuer: ${VAULT_OIDC_ISSUER}\nclientID: ${VAULT_OIDC_CLIENT_ID}\nclientSecret: ${VAULT_OIDC_CLIENT_SECRET}\nrequestedScopes:\n- openid\n- profile\n- email\n- groups\nrequestedIDTokenClaims:\n  groups:\n    essential: true\n\"
    }
  }"
echo "    [✓] argocd-cm patched with Vault OIDC config"

# ── 2. argocd-rbac-cm: map Vault groups to ArgoCD roles ─────────────────────
kubectl patch configmap argocd-rbac-cm \
  -n "${ARGOCD_NAMESPACE}" \
  --type merge \
  -p '{
    "data": {
      "policy.csv": "g, argocd-admins, role:admin\n",
      "policy.default": "role:readonly",
      "scopes": "[groups]"
    }
  }'
echo "    [✓] argocd-rbac-cm patched (argocd-admins → role:admin)"

# ── 3. Restart argocd-server to reload config ────────────────────────────────
kubectl rollout restart deployment/argocd-server -n "${ARGOCD_NAMESPACE}"
kubectl rollout status deployment/argocd-server -n "${ARGOCD_NAMESPACE}" --timeout=120s
echo "    [✓] argocd-server restarted"

# ── 4. Wait for ArgoCD API to be reachable ────────────────────────────────────
echo "    Waiting for ArgoCD API (${ARGOCD_SERVER})..."
for i in $(seq 1 60); do
  HTTP_CODE=$(curl -sk -o /dev/null -w "%{http_code}" "${ARGOCD_SERVER}/healthz" 2>/dev/null || echo "000")
  [ "${HTTP_CODE}" = "200" ] && break
  echo "    attempt ${i}/60 – http=${HTTP_CODE}, sleeping 5s..."
  sleep 5
done

# ── 5. Retrieve initial admin password ───────────────────────────────────────
ARGOCD_ADMIN_PASSWORD=$(kubectl -n "${ARGOCD_NAMESPACE}" \
  get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d)
echo "    [✓] initial admin password retrieved"

# ── 6. Create an ArgoCD API token (service account token) ────────────────────
# Log in to get a session cookie/token
SESSION_RESP=$(curl -sk -X POST "${ARGOCD_SERVER}/api/v1/session" \
  -H "Content-Type: application/json" \
  -d "{\"username\": \"admin\", \"password\": \"${ARGOCD_ADMIN_PASSWORD}\"}")
SESSION_TOKEN=$(echo "${SESSION_RESP}" | jq -r '.token')

# Create a service-account token for the 'admin' account
#   (ArgoCD generates a non-expiring token by default; use expiresIn for time-scoped tokens)
TOKEN_RESP=$(curl -sk -X POST "${ARGOCD_SERVER}/api/v1/account/admin/token" \
  -H "Authorization: Bearer ${SESSION_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"name": "poc-demo-token", "expiresIn": 3600}')
ARGOCD_API_TOKEN=$(echo "${TOKEN_RESP}" | jq -r '.token')
echo "    [✓] ArgoCD API token created (TTL: 1 hour)"

# ── 7. Store ArgoCD API token in Vault KV (this is the "dynamic secret") ─────
# The client service will authenticate to Vault (AppRole) and read this token.
# The token has a 1-hour TTL – it is short-lived by design.
# ISO 8601 UTC timestamp; works on both GNU date and BusyBox date
ISSUED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
curl -sf -X POST "${VAULT_ADDR}/v1/secret/data/argocd/api-token" \
  -H "X-Vault-Token: ${VAULT_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "{
    \"data\": {
      \"token\": \"${ARGOCD_API_TOKEN}\",
      \"server\": \"${ARGOCD_SERVER}\",
      \"issued_at\": \"${ISSUED_AT}\",
      \"expires_in_seconds\": \"3600\"
    }
  }" > /dev/null
echo "    [✓] ArgoCD API token stored in Vault KV at 'secret/argocd/api-token'"
echo "        The client will read this path after AppRole authentication."

# ── 8. Persist credentials ────────────────────────────────────────────────────
cat >> "${SETUP_OUTPUT}/vault-oidc.env" <<EOF
ARGOCD_ADMIN_PASSWORD=${ARGOCD_ADMIN_PASSWORD}
ARGOCD_API_TOKEN=${ARGOCD_API_TOKEN}
ARGOCD_SESSION_TOKEN=${SESSION_TOKEN}
EOF
echo "    [✓] credentials appended to ${SETUP_OUTPUT}/vault-oidc.env"

echo ">>> [argocd-configure] ArgoCD OIDC configuration complete."
echo "    Login URL:     ${ARGOCD_URL}"
echo "    OIDC issuer:   ${VAULT_OIDC_ISSUER}"
echo "    Vault KV path: secret/argocd/api-token  (ArgoCD API token for client)"
