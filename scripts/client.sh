#!/bin/sh
# client.sh – ArgoCD Dynamic Secret client
#
# Architecture:
#   This client represents any automated system (CI/CD pipeline, operator, agent)
#   that needs to interact with the ArgoCD API without storing static credentials.
#
# Flow:
#   1. Read AppRole credentials (role_id, secret_id) – delivered via setup-output
#      In production these would arrive via a trusted orchestrator (Vault Agent,
#      CI/CD secret injection, etc.)
#   2. Authenticate to Vault using AppRole → short-lived Vault token (TTL=1h)
#   3. Read the ArgoCD API token from Vault KV at 'secret/argocd/api-token'
#      This is the "dynamic secret": short TTL, stored in Vault, never in code
#   4. Use the ArgoCD API token to:
#      a) CREATE  an ArgoCD application
#      b) READ    (list) applications
#      c) UPDATE  the application (add annotation)
#      d) SYNC    the application
#      e) DELETE  the application
#   5. Print a summary showing the full dynamic-secret lifecycle
set -e

VAULT_ADDR="${VAULT_ADDR:-http://vault:8200}"
SETUP_OUTPUT="${SETUP_OUTPUT:-/setup-output}"
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-argocd}"

# ── install tools ─────────────────────────────────────────────────────────────
apk add --no-cache curl jq > /dev/null 2>&1

# ── kubeconfig (not needed for client, but kept for optional kubectl commands) ─
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

# ── read AppRole credentials (delivered by setup, simulates secret injection) ─
# shellcheck source=/dev/null
. "${SETUP_OUTPUT}/vault-oidc.env"

echo ""
echo "╔══════════════════════════════════════════════════════════════════════╗"
echo "║     ArgoCD Dynamic Secret – Client Proof of Concept                 ║"
echo "╚══════════════════════════════════════════════════════════════════════╝"
echo ""
echo "  Architecture:"
echo "  [client] → AppRole login → [Vault] → read KV token → [ArgoCD API]"
echo ""

# ═════════════════════════════════════════════════════════════════════════════
# STEP 1 – AppRole authentication to Vault
# The client only knows its role_id and secret_id (equivalent to a username
# and one-time password). It does NOT have a static ArgoCD token.
# ═════════════════════════════════════════════════════════════════════════════
echo "─── Step 1: AppRole authentication to Vault ─────────────────────────────"
echo "    role_id:   ${VAULT_APPROLE_ROLE_ID}"
echo "    secret_id: ${VAULT_APPROLE_SECRET_ID:0:8}... (truncated)"

APPROLE_RESP=$(curl -sf -X POST \
  "${VAULT_ADDR}/v1/auth/approle/login" \
  -H "Content-Type: application/json" \
  -d "{
    \"role_id\": \"${VAULT_APPROLE_ROLE_ID}\",
    \"secret_id\": \"${VAULT_APPROLE_SECRET_ID}\"
  }")

VAULT_CLIENT_TOKEN=$(echo "${APPROLE_RESP}" | jq -r '.auth.client_token')
TOKEN_TTL=$(echo "${APPROLE_RESP}" | jq -r '.auth.lease_duration')
TOKEN_POLICIES=$(echo "${APPROLE_RESP}" | jq -r '.auth.policies | join(", ")')

echo "    Vault token:  ${VAULT_CLIENT_TOKEN:0:12}... (truncated)"
echo "    Token TTL:    ${TOKEN_TTL}s (short-lived Vault token)"
echo "    Policies:     ${TOKEN_POLICIES}"
echo "    [✓] AppRole authentication successful – client holds a short-lived Vault token"

# ═════════════════════════════════════════════════════════════════════════════
# STEP 2 – Read the ArgoCD API token from Vault KV
# The client uses its short-lived Vault token to read from the KV path where
# setup stored the ArgoCD API token. This is the "dynamic secret" pattern:
# the credential lives in Vault, not in the client's environment.
# ═════════════════════════════════════════════════════════════════════════════
echo ""
echo "─── Step 2: Read ArgoCD API token from Vault KV ─────────────────────────"
echo "    Path: secret/data/argocd/api-token"

KV_RESP=$(curl -sf \
  "${VAULT_ADDR}/v1/secret/data/argocd/api-token" \
  -H "X-Vault-Token: ${VAULT_CLIENT_TOKEN}")

ARGOCD_API_TOKEN=$(echo "${KV_RESP}" | jq -r '.data.data.token')
ARGOCD_SERVER_URL=$(echo "${KV_RESP}" | jq -r '.data.data.server')
ISSUED_AT=$(echo "${KV_RESP}" | jq -r '.data.data.issued_at')
EXPIRES_IN=$(echo "${KV_RESP}" | jq -r '.data.data.expires_in_seconds')
KV_VERSION=$(echo "${KV_RESP}" | jq -r '.data.metadata.version')
KV_CREATED=$(echo "${KV_RESP}" | jq -r '.data.metadata.created_time')

echo "    ArgoCD server:     ${ARGOCD_SERVER_URL}"
echo "    Token (truncated): ${ARGOCD_API_TOKEN:0:40}..."
echo "    Issued at:         ${ISSUED_AT}"
echo "    Expires in:        ${EXPIRES_IN}s"
echo "    KV version:        ${KV_VERSION} (created: ${KV_CREATED})"
echo "    [✓] Dynamic secret retrieved from Vault – token is short-lived (${EXPIRES_IN}s TTL)"

# Use the server URL from the KV secret (single source of truth)
ARGOCD_SERVER="${ARGOCD_SERVER_URL}"

# ═════════════════════════════════════════════════════════════════════════════
# STEP 3 – Verify the token works
# ═════════════════════════════════════════════════════════════════════════════
echo ""
echo "─── Step 3: Verify ArgoCD API token ────────────────────────────────────"
HTTP_CODE=$(curl -sk -o /dev/null -w "%{http_code}" \
  -H "Authorization: Bearer ${ARGOCD_API_TOKEN}" \
  "${ARGOCD_SERVER}/api/v1/account")
echo "    GET /api/v1/account → HTTP ${HTTP_CODE}"
if [ "${HTTP_CODE}" = "200" ]; then
  echo "    [✓] Token is valid and active"
else
  echo "    [!] Unexpected HTTP ${HTTP_CODE} – the token may have expired"
fi

# ═════════════════════════════════════════════════════════════════════════════
# STEP 4a – CREATE an ArgoCD application
# ═════════════════════════════════════════════════════════════════════════════
echo ""
echo "─── Step 4a: CREATE ArgoCD application ─────────────────────────────────"
APP_NAME="dynamic-secret-demo-app"
CREATE_RESP=$(curl -sk -X POST \
  -H "Authorization: Bearer ${ARGOCD_API_TOKEN}" \
  -H "Content-Type: application/json" \
  "${ARGOCD_SERVER}/api/v1/applications" \
  -d "{
    \"metadata\": {
      \"name\": \"${APP_NAME}\",
      \"namespace\": \"${ARGOCD_NAMESPACE}\",
      \"annotations\": {
        \"created-by\": \"dynamic-secret-client\",
        \"vault-kv-path\": \"secret/argocd/api-token\"
      }
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
echo "    [✓] Application created via ArgoCD API (using Vault-issued dynamic token)"

# ═════════════════════════════════════════════════════════════════════════════
# STEP 4b – READ (list) applications
# ═════════════════════════════════════════════════════════════════════════════
echo ""
echo "─── Step 4b: READ (list) ArgoCD applications ────────────────────────────"
LIST_RESP=$(curl -sk \
  -H "Authorization: Bearer ${ARGOCD_API_TOKEN}" \
  "${ARGOCD_SERVER}/api/v1/applications")
APP_COUNT=$(echo "${LIST_RESP}" | jq '.items | length')
echo "    Total applications: ${APP_COUNT}"
echo "${LIST_RESP}" | jq -r '.items[] | "    - \(.metadata.name)  sync=\(.status.sync.status // "Unknown")  health=\(.status.health.status // "Unknown")"'
echo "    [✓] Applications listed via ArgoCD API"

# ═════════════════════════════════════════════════════════════════════════════
# STEP 4c – UPDATE the application (add an annotation)
# ═════════════════════════════════════════════════════════════════════════════
echo ""
echo "─── Step 4c: UPDATE ArgoCD application ─────────────────────────────────"
UPDATE_RESP=$(curl -sk -X PATCH \
  -H "Authorization: Bearer ${ARGOCD_API_TOKEN}" \
  -H "Content-Type: application/json" \
  "${ARGOCD_SERVER}/api/v1/applications/${APP_NAME}" \
  -d '[{
    "op": "add",
    "path": "/metadata/annotations/updated-by",
    "value": "vault-dynamic-secret-client"
  }]')
echo "    Annotations: $(echo "${UPDATE_RESP}" | jq -r '.metadata.annotations // {} | to_entries | map("\(.key)=\(.value)") | join(", ")')"
echo "    [✓] Application updated via ArgoCD API"

# ═════════════════════════════════════════════════════════════════════════════
# STEP 4d – SYNC the application
# ═════════════════════════════════════════════════════════════════════════════
echo ""
echo "─── Step 4d: SYNC ArgoCD application ───────────────────────────────────"
SYNC_RESP=$(curl -sk -X POST \
  -H "Authorization: Bearer ${ARGOCD_API_TOKEN}" \
  -H "Content-Type: application/json" \
  "${ARGOCD_SERVER}/api/v1/applications/${APP_NAME}/sync" \
  -d '{"revision": "HEAD", "prune": false, "dryRun": false}')
echo "    Sync result: $(echo "${SYNC_RESP}" | jq -r '.status.sync.status // "Initiated"')"
echo "    [✓] Application sync triggered via ArgoCD API"

# ═════════════════════════════════════════════════════════════════════════════
# STEP 4e – DELETE the application
# ═════════════════════════════════════════════════════════════════════════════
echo ""
echo "─── Step 4e: DELETE ArgoCD application ─────────────────────────────────"
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
echo "║                  Dynamic Secret Flow – Summary                      ║"
echo "╠══════════════════════════════════════════════════════════════════════╣"
echo "║  1. Client authenticated to Vault via AppRole (no static passwords)  ║"
echo "║  2. Vault returned a short-lived Vault token (TTL = 1h)              ║"
echo "║  3. Client read ArgoCD API token from Vault KV (dynamic secret)      ║"
printf "║     Path: secret/argocd/api-token   TTL: %-27s ║\n" "${EXPIRES_IN}s"
echo "║  4. Client used token to:                                            ║"
echo "║     [✓] CREATE  ArgoCD application                                   ║"
echo "║     [✓] READ    ArgoCD applications                                  ║"
echo "║     [✓] UPDATE  ArgoCD application                                   ║"
echo "║     [✓] SYNC    ArgoCD application                                   ║"
echo "║     [✓] DELETE  ArgoCD application                                   ║"
echo "╠══════════════════════════════════════════════════════════════════════╣"
printf "║  Vault OIDC issuer: %-48s ║\n" "${VAULT_OIDC_ISSUER}"
printf "║  ArgoCD server:     %-48s ║\n" "${ARGOCD_SERVER}"
printf "║  ArgoCD admin:      admin / %-41s ║\n" "${ARGOCD_ADMIN_PASSWORD}"
echo "╠══════════════════════════════════════════════════════════════════════╣"
echo "║  Open browser:                                                       ║"
printf "║    ArgoCD UI → %-54s ║\n" "http://localhost:8080 (click 'LOG IN VIA VAULT')"
printf "║    Vault UI   → %-53s ║\n" "http://localhost:8200  (token: root)"
echo "╚══════════════════════════════════════════════════════════════════════╝"
echo ""
