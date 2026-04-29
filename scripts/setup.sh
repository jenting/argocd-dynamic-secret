#!/bin/sh
# setup.sh – master orchestration script
# Runs inside the 'setup' container (alpine:3.19).
# 1. Installs required CLI tools (kubectl, jq, curl)
# 2. Fixes the kubeconfig so it points to the k3s service name
# 3. Runs vault-setup.sh  → configures Vault as OIDC provider
# 4. Runs argocd-install.sh → installs ArgoCD in k3s
# 5. Runs argocd-configure.sh → patches ArgoCD with Vault OIDC settings
set -e

SETUP_OUTPUT="${SETUP_OUTPUT:-/setup-output}"
K3S_HOST="${K3S_HOST:-k3s}"
KUBECTL_VERSION="v1.28.5"

# ── install tools ─────────────────────────────────────────────────────────────
echo ">>> Installing tools..."
apk add --no-cache curl jq openssl bash > /dev/null 2>&1

# kubectl
if ! command -v kubectl > /dev/null 2>&1; then
  echo ">>> Downloading kubectl ${KUBECTL_VERSION}..."
  curl -sSLo /usr/local/bin/kubectl \
    "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl"
  chmod +x /usr/local/bin/kubectl
fi

# ── kubeconfig ────────────────────────────────────────────────────────────────
echo ">>> Configuring kubeconfig (server → ${K3S_HOST})..."
mkdir -p /root/.kube
cp /k3s-output/kubeconfig.yaml /root/.kube/config
# Replace the loopback address written by k3s with the container hostname
sed -i "s|https://127.0.0.1:6443|https://${K3S_HOST}:6443|g" /root/.kube/config
export KUBECONFIG=/root/.kube/config

# ── wait for kube-apiserver ───────────────────────────────────────────────────
echo ">>> Waiting for kube-apiserver to be reachable..."
for i in $(seq 1 60); do
  kubectl cluster-info > /dev/null 2>&1 && break
  echo "    attempt ${i}/60 – sleeping 5s..."
  sleep 5
done
kubectl cluster-info

# ── run sub-scripts ───────────────────────────────────────────────────────────
sh /scripts/vault-setup.sh
sh /scripts/argocd-install.sh
sh /scripts/argocd-configure.sh

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║  Setup complete!  Run 'docker compose logs client -f'    ║"
echo "║  to watch the end-to-end dynamic-secret demo.            ║"
echo "╚══════════════════════════════════════════════════════════╝"
