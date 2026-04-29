#!/bin/sh
# vault-setup.sh – configure HashiCorp Vault as an OIDC Identity Provider
#                  and prepare the AppRole + KV engine for the client
#
# Steps:
#   1.  Create a named signing key (RS256)
#   2.  Create OIDC scopes: groups, profile, email
#   3.  Create an assignment that allows all entities
#   4.  Create the OIDC client for ArgoCD (captures client_id + client_secret)
#   5.  Create the OIDC provider that exposes the discovery endpoint
#   6.  Enable userpass auth and create a demo user (for browser OIDC login)
#   7.  Create a Vault identity entity + alias for the demo user
#   8.  Create an admin group and add the entity as a member
#   9.  Enable AppRole auth + KV secret engine for the client service
#   10. Write all credentials to /setup-output/vault-oidc.env
set -e

VAULT_ADDR="${VAULT_ADDR:-http://vault:8200}"
VAULT_TOKEN="${VAULT_TOKEN:-root}"
SETUP_OUTPUT="${SETUP_OUTPUT:-/setup-output}"
ARGOCD_REDIRECT_URI="${ARGOCD_REDIRECT_URI:-http://localhost:8080/auth/callback}"

export VAULT_ADDR VAULT_TOKEN

mkdir -p "${SETUP_OUTPUT}"

echo ">>> [vault-setup] Waiting for Vault API..."
for i in $(seq 1 30); do
  STATUS=$(curl -sf "${VAULT_ADDR}/v1/sys/health" 2>/dev/null | jq -r '.initialized' 2>/dev/null || echo "")
  [ "${STATUS}" = "true" ] && break
  echo "    attempt ${i}/30 – sleeping 3s..."
  sleep 3
done

echo ">>> [vault-setup] Configuring Identity OIDC Provider..."

# ── 1. Named signing key ──────────────────────────────────────────────────────
curl -sf -X POST "${VAULT_ADDR}/v1/identity/oidc/key/argocd-key" \
  -H "X-Vault-Token: ${VAULT_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{
    "algorithm": "RS256",
    "rotation_period": "24h",
    "verification_ttl": "24h",
    "allowed_client_ids": ["*"]
  }' > /dev/null
echo "    [✓] signing key 'argocd-key' created"

# ── 2. OIDC scopes ────────────────────────────────────────────────────────────
# groups scope – includes the entity's group names in the ID token
curl -sf -X POST "${VAULT_ADDR}/v1/identity/oidc/scope/groups" \
  -H "X-Vault-Token: ${VAULT_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{
    "description": "Groups scope",
    "template": "{\"groups\": {{identity.entity.groups.names | tojson}}}"
  }' > /dev/null

# profile scope – includes the username
curl -sf -X POST "${VAULT_ADDR}/v1/identity/oidc/scope/profile" \
  -H "X-Vault-Token: ${VAULT_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{
    "description": "Profile scope",
    "template": "{\"username\": {{identity.entity.name | quote}}}"
  }' > /dev/null

# email scope – includes the email metadata field
curl -sf -X POST "${VAULT_ADDR}/v1/identity/oidc/scope/email" \
  -H "X-Vault-Token: ${VAULT_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{
    "description": "Email scope",
    "template": "{\"email\": {{identity.entity.metadata.email | quote}}}"
  }' > /dev/null
echo "    [✓] scopes created (groups, profile, email)"

# ── 3. Assignment (allow all entities) ───────────────────────────────────────
curl -sf -X POST "${VAULT_ADDR}/v1/identity/oidc/assignment/allow-all" \
  -H "X-Vault-Token: ${VAULT_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{
    "entity_ids": ["*"],
    "group_ids": ["*"]
  }' > /dev/null
echo "    [✓] assignment 'allow-all' created"

# ── 4. OIDC client for ArgoCD ─────────────────────────────────────────────────
curl -sf -X POST "${VAULT_ADDR}/v1/identity/oidc/client/argocd" \
  -H "X-Vault-Token: ${VAULT_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "{
    \"redirect_uris\": [\"${ARGOCD_REDIRECT_URI}\"],
    \"assignments\": [\"allow-all\"],
    \"key\": \"argocd-key\",
    \"id_token_ttl\": \"30m\",
    \"access_token_ttl\": \"1h\"
  }" > /dev/null
echo "    [✓] OIDC client 'argocd' created"

# Read back the generated client_id and client_secret
CLIENT_RESP=$(curl -sf "${VAULT_ADDR}/v1/identity/oidc/client/argocd" \
  -H "X-Vault-Token: ${VAULT_TOKEN}")
CLIENT_ID=$(echo "${CLIENT_RESP}" | jq -r '.data.client_id')
CLIENT_SECRET=$(echo "${CLIENT_RESP}" | jq -r '.data.client_secret')

# ── 5. OIDC provider ──────────────────────────────────────────────────────────
curl -sf -X POST "${VAULT_ADDR}/v1/identity/oidc/provider/argocd" \
  -H "X-Vault-Token: ${VAULT_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "{
    \"allowed_client_ids\": [\"${CLIENT_ID}\"],
    \"scopes_supported\": [\"groups\", \"profile\", \"email\"]
  }" > /dev/null

# The discovery URL that ArgoCD will use:
ISSUER="${VAULT_ADDR}/v1/identity/oidc/provider/argocd"
echo "    [✓] OIDC provider 'argocd' created (issuer: ${ISSUER})"

# ── 6. Userpass auth + demo user ──────────────────────────────────────────────
# Enable userpass if not already enabled
curl -sf -X POST "${VAULT_ADDR}/v1/sys/auth/userpass" \
  -H "X-Vault-Token: ${VAULT_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"type": "userpass"}' > /dev/null 2>&1 || true

# Policy that lets the demo user generate OIDC tokens
curl -sf -X POST "${VAULT_ADDR}/v1/sys/policies/acl/argocd-user" \
  -H "X-Vault-Token: ${VAULT_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{
    "policy": "path \"identity/oidc/provider/argocd/authorize\" {\n  capabilities = [\"read\"]\n}\npath \"identity/oidc/token/*\" {\n  capabilities = [\"read\"]\n}\n"
  }' > /dev/null

# Create the demo user (argocd-admin / password)
curl -sf -X POST "${VAULT_ADDR}/v1/auth/userpass/users/argocd-admin" \
  -H "X-Vault-Token: ${VAULT_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"password": "password", "policies": "default,argocd-user"}' > /dev/null
echo "    [✓] userpass user 'argocd-admin' created (password: password)"

# ── 7. Identity entity + alias ────────────────────────────────────────────────
ENTITY_RESP=$(curl -sf -X POST "${VAULT_ADDR}/v1/identity/entity" \
  -H "X-Vault-Token: ${VAULT_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "argocd-admin",
    "metadata": {"email": "admin@example.com"},
    "policies": ["default", "argocd-user"]
  }')
ENTITY_ID=$(echo "${ENTITY_RESP}" | jq -r '.data.id')

# Get the accessor for the userpass mount
ACCESSOR=$(curl -sf "${VAULT_ADDR}/v1/sys/auth" \
  -H "X-Vault-Token: ${VAULT_TOKEN}" | jq -r '."userpass/".accessor')

# Link the userpass login to the entity
curl -sf -X POST "${VAULT_ADDR}/v1/identity/entity-alias" \
  -H "X-Vault-Token: ${VAULT_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "{
    \"name\": \"argocd-admin\",
    \"canonical_id\": \"${ENTITY_ID}\",
    \"mount_accessor\": \"${ACCESSOR}\"
  }" > /dev/null
echo "    [✓] identity entity 'argocd-admin' created (id: ${ENTITY_ID})"

# ── 8. Admin group ────────────────────────────────────────────────────────────
GROUP_RESP=$(curl -sf -X POST "${VAULT_ADDR}/v1/identity/group" \
  -H "X-Vault-Token: ${VAULT_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "{
    \"name\": \"argocd-admins\",
    \"type\": \"internal\",
    \"member_entity_ids\": [\"${ENTITY_ID}\"],
    \"metadata\": {\"description\": \"ArgoCD admin users\"}
  }")
GROUP_ID=$(echo "${GROUP_RESP}" | jq -r '.data.id')
echo "    [✓] group 'argocd-admins' created (id: ${GROUP_ID})"

# ── 9. AppRole auth + KV secret engine (for the client service) ──────────────
echo ">>> [vault-setup] Configuring AppRole auth and KV secret engine..."

# Enable AppRole auth (for machine/client authentication)
curl -sf -X POST "${VAULT_ADDR}/v1/sys/auth/approle" \
  -H "X-Vault-Token: ${VAULT_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"type": "approle"}' > /dev/null 2>&1 || true
echo "    [✓] AppRole auth method enabled"

# Policy: allows the client to READ the ArgoCD API token from Vault KV
# The token is the "dynamic secret" – generated by setup with a short TTL,
# stored here so the client can fetch it on demand.
curl -sf -X POST "${VAULT_ADDR}/v1/sys/policies/acl/argocd-client" \
  -H "X-Vault-Token: ${VAULT_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{
    "policy": "path \"secret/data/argocd/api-token\" {\n  capabilities = [\"read\"]\n}\npath \"secret/metadata/argocd/api-token\" {\n  capabilities = [\"read\"]\n}\n"
  }' > /dev/null
echo "    [✓] policy 'argocd-client' created (read secret/data/argocd/api-token)"

# Create the AppRole role for the client
# token_ttl=1h ensures the Vault token the client gets is short-lived
# secret_id_ttl=10m means the secret_id (one-time credential) expires quickly
curl -sf -X POST "${VAULT_ADDR}/v1/auth/approle/role/argocd-client" \
  -H "X-Vault-Token: ${VAULT_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{
    "token_policies": ["default", "argocd-client"],
    "token_ttl": "1h",
    "token_max_ttl": "2h",
    "secret_id_ttl": "10m",
    "secret_id_num_uses": 10
  }' > /dev/null
echo "    [✓] AppRole role 'argocd-client' created (token_ttl=1h, secret_id_ttl=10m)"

# Retrieve the role_id (stable, non-sensitive identifier)
ROLE_ID=$(curl -sf "${VAULT_ADDR}/v1/auth/approle/role/argocd-client/role-id" \
  -H "X-Vault-Token: ${VAULT_TOKEN}" | jq -r '.data.role_id')

# Generate a secret_id (short-lived credential delivered to the client)
# In production this would be delivered via a trusted orchestrator (e.g., Vault Agent)
SECRET_ID=$(curl -sf -X POST "${VAULT_ADDR}/v1/auth/approle/role/argocd-client/secret-id" \
  -H "X-Vault-Token: ${VAULT_TOKEN}" | jq -r '.data.secret_id')

echo "    [✓] AppRole credentials generated"
echo "        role_id:   ${ROLE_ID}"
echo "        secret_id: ${SECRET_ID:0:8}... (truncated for security)"

# ── 10. Save credentials ──────────────────────────────────────────────────────
cat > "${SETUP_OUTPUT}/vault-oidc.env" <<EOF
VAULT_ADDR=${VAULT_ADDR}
VAULT_OIDC_ISSUER=${ISSUER}
VAULT_OIDC_CLIENT_ID=${CLIENT_ID}
VAULT_OIDC_CLIENT_SECRET=${CLIENT_SECRET}
VAULT_DEMO_USER=argocd-admin
VAULT_DEMO_PASSWORD=password
VAULT_ENTITY_ID=${ENTITY_ID}
VAULT_GROUP_ID=${GROUP_ID}
VAULT_APPROLE_ROLE_ID=${ROLE_ID}
VAULT_APPROLE_SECRET_ID=${SECRET_ID}
EOF
echo "    [✓] credentials written to ${SETUP_OUTPUT}/vault-oidc.env"

echo ">>> [vault-setup] Vault OIDC provider ready."
echo "    Discovery URL: ${ISSUER}/.well-known/openid-configuration"
echo ">>> [vault-setup] Vault AppRole ready for the client service."
