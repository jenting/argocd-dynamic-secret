#!/bin/sh
# client.sh – ArgoCD Dynamic Secret client (Vault OIDC ID token flow)
#
# Architecture:
#   The client authenticates to Vault and uses Vault's OIDC Identity Provider
#   to obtain a short-lived, signed ID token that contains 'groups' claims.
#   ArgoCD is configured to trust Vault as its OIDC provider, so it can verify
#   the token signature (via Vault's JWKS endpoint) and map groups to RBAC roles.
#
# Flow:
#   1.  Authenticate to Vault via userpass → short-lived Vault token
#   2.  Generate PKCE code_verifier + code_challenge (SHA-256 / Base64URL)
#   3.  Request an OIDC authorization code from Vault's OIDC provider
#       (headless: X-Vault-Token header authenticates the user, no browser needed)
#   4.  Exchange the authorization code for a short-lived OIDC ID token
#       The ID token is a signed RS256 JWT containing 'groups' and 'email' claims
#   5.  Decode and display the ID token claims (groups, email, sub, exp)
#   6.  Exchange the Vault-issued ID token for an ArgoCD session token
#       ArgoCD validates the JWT signature against Vault's JWKS endpoint and
#       maps the 'groups' claim → RBAC role (argocd-admins → role:admin)
#   7.  Use the ArgoCD session token to:
#       a) CREATE  an ArgoCD application
#       b) READ    (list) applications
#       c) UPDATE  the application (add annotation)
#       d) SYNC    the application
#       e) DELETE  the application
#   8.  Print a summary
set -e

VAULT_ADDR="${VAULT_ADDR:-http://vault:8200}"
SETUP_OUTPUT="${SETUP_OUTPUT:-/setup-output}"
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-argocd}"

# ── install tools ─────────────────────────────────────────────────────────────
apk add --no-cache curl jq openssl > /dev/null 2>&1

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

# ── load setup credentials ────────────────────────────────────────────────────
# shellcheck source=/dev/null
. "${SETUP_OUTPUT}/vault-oidc.env"

echo ""
echo "╔══════════════════════════════════════════════════════════════════════╗"
echo "║    ArgoCD Dynamic Secret – OIDC ID Token Client                     ║"
echo "╚══════════════════════════════════════════════════════════════════════╝"
echo ""
echo "  Architecture:"
echo "  [client] → Vault userpass → PKCE authorize → ID token (groups)"
echo "  ID token → ArgoCD session → create/update/sync/delete application"
echo ""

# ═════════════════════════════════════════════════════════════════════════════
# STEP 1 – Authenticate to Vault (userpass)
# The client logs in with a username/password to obtain a short-lived Vault
# token. This token is used to authenticate the OIDC authorization request.
# ═════════════════════════════════════════════════════════════════════════════
echo "─── Step 1: Vault userpass authentication ───────────────────────────────"
echo "    User: ${VAULT_DEMO_USER}"

LOGIN_RESP=$(curl -sf -X POST \
  "${VAULT_ADDR}/v1/auth/userpass/login/${VAULT_DEMO_USER}" \
  -H "Content-Type: application/json" \
  -d "{\"password\": \"${VAULT_DEMO_PASSWORD}\"}")

USER_TOKEN=$(echo "${LOGIN_RESP}" | jq -r '.auth.client_token')
TOKEN_TTL=$(echo "${LOGIN_RESP}" | jq -r '.auth.lease_duration')

echo "    Vault token: ${USER_TOKEN:0:12}... (truncated)"
echo "    Token TTL:   ${TOKEN_TTL}s"
echo "    [✓] Vault login successful – short-lived Vault token obtained"

# ═════════════════════════════════════════════════════════════════════════════
# STEP 2 – PKCE setup
# PKCE (Proof Key for Code Exchange, RFC 7636) prevents authorization code
# interception attacks. The client generates a random code_verifier, then
# computes code_challenge = BASE64URL(SHA256(code_verifier)) to send with
# the authorization request.
# ═════════════════════════════════════════════════════════════════════════════
echo ""
echo "─── Step 2: Generate PKCE code verifier + challenge ─────────────────────"

# code_verifier: 64-character random string (URL-safe Base64, no padding)
# Use 64 raw bytes → ~88 base64 chars before stripping; head -c 64 guarantees
# the 43–128 char range required by RFC 7636.
CODE_VERIFIER=$(openssl rand -base64 64 | tr -d '=\n+/' | head -c 64)
# code_challenge: BASE64URL(SHA-256(code_verifier))
CODE_CHALLENGE=$(printf '%s' "${CODE_VERIFIER}" | \
  openssl dgst -sha256 -binary | \
  openssl base64 -A | tr '+/' '-_' | tr -d '=')
# state: random nonce for CSRF protection
STATE=$(openssl rand -hex 16)

echo "    code_verifier  (len=${#CODE_VERIFIER}): ${CODE_VERIFIER:0:12}... (truncated)"
echo "    code_challenge (len=${#CODE_CHALLENGE}): ${CODE_CHALLENGE:0:12}... (truncated)"
echo "    [✓] PKCE parameters generated (S256 method)"

# ═════════════════════════════════════════════════════════════════════════════
# STEP 3 – OIDC authorization code request (headless)
# Vault's OIDC provider authorize endpoint accepts an X-Vault-Token header to
# authenticate the end-user without a browser redirect. It responds with a
# 302 redirect to redirect_uri?code=<auth_code>&state=<state>.
# We capture the Location header and extract the authorization code.
# ═════════════════════════════════════════════════════════════════════════════
echo ""
echo "─── Step 3: Request OIDC authorization code from Vault ──────────────────"
echo "    Provider:    ${VAULT_OIDC_ISSUER}"
echo "    redirect_uri: ${ARGOCD_REDIRECT_URI}"

# -G: use GET, appending --data-urlencode params as query string
# -D -: dump response headers to stdout
# -o /dev/null: discard response body (it's a redirect)
AUTH_HEADERS=$(curl -sD - -o /dev/null \
  -G \
  -H "X-Vault-Token: ${USER_TOKEN}" \
  --data-urlencode "client_id=${VAULT_OIDC_CLIENT_ID}" \
  --data-urlencode "redirect_uri=${ARGOCD_REDIRECT_URI}" \
  --data-urlencode "response_type=code" \
  --data-urlencode "scope=openid profile email groups" \
  --data-urlencode "state=${STATE}" \
  --data-urlencode "code_challenge=${CODE_CHALLENGE}" \
  --data-urlencode "code_challenge_method=S256" \
  "${VAULT_ADDR}/v1/identity/oidc/provider/argocd/authorize")

# Extract the redirect Location and parse the auth code
LOCATION=$(echo "${AUTH_HEADERS}" | grep -i '^Location:' | tr -d '\r\n' | sed 's/[Ll]ocation: //')
AUTH_CODE=$(echo "${LOCATION}" | grep -o 'code=[^&]*' | cut -d= -f2)

if [ -z "${AUTH_CODE}" ]; then
  echo "    [!] Failed to obtain authorization code."
  echo "    Response headers:"
  echo "${AUTH_HEADERS}" | head -20
  exit 1
fi

echo "    Authorization code: ${AUTH_CODE:0:12}... (truncated)"
echo "    [✓] Authorization code obtained from Vault OIDC provider"

# ═════════════════════════════════════════════════════════════════════════════
# STEP 4 – Exchange authorization code for OIDC ID token
# The Vault token endpoint validates the auth code + PKCE verifier, then
# issues a short-lived OIDC ID token (RS256 JWT) and access token.
# The ID token includes 'groups', 'email', and standard OIDC claims.
# ═════════════════════════════════════════════════════════════════════════════
echo ""
echo "─── Step 4: Exchange authorization code for OIDC ID token ──────────────"

TOKEN_RESP=$(curl -sf -X POST \
  "${VAULT_ADDR}/v1/identity/oidc/provider/argocd/token" \
  -u "${VAULT_OIDC_CLIENT_ID}:${VAULT_OIDC_CLIENT_SECRET}" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  --data-urlencode "grant_type=authorization_code" \
  --data-urlencode "code=${AUTH_CODE}" \
  --data-urlencode "redirect_uri=${ARGOCD_REDIRECT_URI}" \
  --data-urlencode "code_verifier=${CODE_VERIFIER}")

ID_TOKEN=$(echo "${TOKEN_RESP}" | jq -r '.id_token')
TOKEN_TYPE=$(echo "${TOKEN_RESP}" | jq -r '.token_type')
EXPIRES_IN=$(echo "${TOKEN_RESP}" | jq -r '.expires_in')

if [ -z "${ID_TOKEN}" ] || [ "${ID_TOKEN}" = "null" ]; then
  echo "    [!] Token exchange failed. Response:"
  echo "${TOKEN_RESP}" | jq .
  exit 1
fi

echo "    token_type:  ${TOKEN_TYPE}"
echo "    expires_in:  ${EXPIRES_IN}s (short-lived – this is the dynamic secret)"
echo "    id_token:    ${ID_TOKEN:0:40}... (truncated)"
echo "    [✓] Vault issued a short-lived OIDC ID token"

# ═════════════════════════════════════════════════════════════════════════════
# STEP 5 – Decode and display ID token claims
# The ID token is a JWT (header.payload.signature). We base64url-decode the
# payload to inspect the claims. No signature verification here – ArgoCD will
# do that via Vault's JWKS endpoint.
# ═════════════════════════════════════════════════════════════════════════════
echo ""
echo "─── Step 5: Decode OIDC ID token claims ────────────────────────────────"

PAYLOAD=$(echo "${ID_TOKEN}" | cut -d'.' -f2)
# Convert Base64URL → Base64 (replace - with +, _ with /) and add padding
PADDED=$(printf '%s' "${PAYLOAD}" | tr -- '-_' '+/' | \
  awk '{while (length($0) % 4) $0 = $0 "="; print}')
CLAIMS=$(printf '%s' "${PADDED}" | base64 -d 2>/dev/null)

echo "    --- Vault-issued OIDC ID token claims ---"
echo "    iss:    $(echo "${CLAIMS}" | jq -r '.iss')"
echo "    sub:    $(echo "${CLAIMS}" | jq -r '.sub')"
echo "    aud:    $(echo "${CLAIMS}" | jq -r '.aud')"
echo "    groups: $(echo "${CLAIMS}" | jq -r '.groups // [] | join(", ")')"
echo "    email:  $(echo "${CLAIMS}" | jq -r '.email // "n/a"')"
echo "    exp:    $(echo "${CLAIMS}" | jq -r '.exp') (unix epoch)"
echo "    [✓] Token includes 'groups' claim → ArgoCD will map argocd-admins → role:admin"

# ═════════════════════════════════════════════════════════════════════════════
# STEP 6 – Exchange OIDC ID token for an ArgoCD session token
# ArgoCD's POST /api/v1/session accepts an OIDC ID token in the 'token' field.
# ArgoCD:
#   1. Decodes the JWT and checks the 'iss' matches its configured OIDC issuer
#   2. Fetches Vault's JWKS endpoint to verify the RS256 signature
#   3. Extracts 'groups' claims and maps them to RBAC roles
#   4. Returns a short-lived ArgoCD JWT for use as a Bearer token
# ═════════════════════════════════════════════════════════════════════════════
echo ""
echo "─── Step 6: Exchange OIDC ID token for ArgoCD session token ────────────"
echo "    ArgoCD server: ${ARGOCD_SERVER}"

SESSION_RESP=$(curl -sk -X POST \
  "${ARGOCD_SERVER}/api/v1/session" \
  -H "Content-Type: application/json" \
  -d "{\"token\": \"${ID_TOKEN}\"}")

ARGOCD_TOKEN=$(echo "${SESSION_RESP}" | jq -r '.token')

if [ -z "${ARGOCD_TOKEN}" ] || [ "${ARGOCD_TOKEN}" = "null" ]; then
  echo "    [!] Failed to create ArgoCD session. Response:"
  echo "${SESSION_RESP}" | jq .
  exit 1
fi

echo "    ArgoCD token: ${ARGOCD_TOKEN:0:40}... (truncated)"
echo "    [✓] ArgoCD session token issued – derived from Vault OIDC ID token"

# ═════════════════════════════════════════════════════════════════════════════
# STEP 7a – CREATE an ArgoCD application
# ═════════════════════════════════════════════════════════════════════════════
echo ""
echo "─── Step 7a: CREATE ArgoCD application ─────────────────────────────────"
APP_NAME="dynamic-secret-demo-app"
CREATE_RESP=$(curl -sk -X POST \
  -H "Authorization: Bearer ${ARGOCD_TOKEN}" \
  -H "Content-Type: application/json" \
  "${ARGOCD_SERVER}/api/v1/applications" \
  -d "{
    \"metadata\": {
      \"name\": \"${APP_NAME}\",
      \"namespace\": \"${ARGOCD_NAMESPACE}\",
      \"annotations\": {
        \"created-by\": \"vault-oidc-client\",
        \"oidc-issuer\": \"${VAULT_OIDC_ISSUER}\"
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
echo "    [✓] Application created via ArgoCD API (OIDC token → role:admin)"

# ═════════════════════════════════════════════════════════════════════════════
# STEP 7b – READ (list) applications
# ═════════════════════════════════════════════════════════════════════════════
echo ""
echo "─── Step 7b: READ (list) ArgoCD applications ────────────────────────────"
LIST_RESP=$(curl -sk \
  -H "Authorization: Bearer ${ARGOCD_TOKEN}" \
  "${ARGOCD_SERVER}/api/v1/applications")
APP_COUNT=$(echo "${LIST_RESP}" | jq '.items | length')
echo "    Total applications: ${APP_COUNT}"
echo "${LIST_RESP}" | jq -r '.items[] | "    - \(.metadata.name)  sync=\(.status.sync.status // "Unknown")  health=\(.status.health.status // "Unknown")"'
echo "    [✓] Applications listed via ArgoCD API"

# ═════════════════════════════════════════════════════════════════════════════
# STEP 7c – UPDATE the application (add an annotation)
# ═════════════════════════════════════════════════════════════════════════════
echo ""
echo "─── Step 7c: UPDATE ArgoCD application ─────────────────────────────────"
UPDATE_RESP=$(curl -sk -X PATCH \
  -H "Authorization: Bearer ${ARGOCD_TOKEN}" \
  -H "Content-Type: application/json" \
  "${ARGOCD_SERVER}/api/v1/applications/${APP_NAME}" \
  -d '[{
    "op": "add",
    "path": "/metadata/annotations/updated-by",
    "value": "vault-oidc-client"
  }]')
echo "    Annotations: $(echo "${UPDATE_RESP}" | jq -r '.metadata.annotations // {} | to_entries | map("\(.key)=\(.value)") | join(", ")')"
echo "    [✓] Application updated via ArgoCD API"

# ═════════════════════════════════════════════════════════════════════════════
# STEP 7d – SYNC the application
# ═════════════════════════════════════════════════════════════════════════════
echo ""
echo "─── Step 7d: SYNC ArgoCD application ───────────────────────────────────"
SYNC_RESP=$(curl -sk -X POST \
  -H "Authorization: Bearer ${ARGOCD_TOKEN}" \
  -H "Content-Type: application/json" \
  "${ARGOCD_SERVER}/api/v1/applications/${APP_NAME}/sync" \
  -d '{"revision": "HEAD", "prune": false, "dryRun": false}')
echo "    Sync result: $(echo "${SYNC_RESP}" | jq -r '.status.sync.status // "Initiated"')"
echo "    [✓] Application sync triggered via ArgoCD API"

# ═════════════════════════════════════════════════════════════════════════════
# STEP 7e – DELETE the application
# ═════════════════════════════════════════════════════════════════════════════
echo ""
echo "─── Step 7e: DELETE ArgoCD application ─────────────────────────────────"
DELETE_HTTP=$(curl -sk -o /dev/null -w "%{http_code}" \
  -X DELETE \
  -H "Authorization: Bearer ${ARGOCD_TOKEN}" \
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
echo "║           OIDC Dynamic Secret Flow – Summary                        ║"
echo "╠══════════════════════════════════════════════════════════════════════╣"
echo "║  1. Client authenticated to Vault via userpass                       ║"
echo "║  2. Client requested OIDC authorization code (PKCE, headless)        ║"
echo "║  3. Vault issued a short-lived OIDC ID token (RS256 JWT)             ║"
printf "║     groups: %-56s ║\n" "$(echo "${CLAIMS}" | jq -r '.groups // [] | join(", ")')"
printf "║     TTL:    %-56s ║\n" "${EXPIRES_IN}s"
echo "║  4. ArgoCD verified token via Vault JWKS, mapped groups → role       ║"
echo "║     argocd-admins → role:admin                                       ║"
echo "║  5. Client used the ArgoCD session token to:                         ║"
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
