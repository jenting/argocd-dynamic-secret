#!/bin/sh
# argocd-install.sh – install ArgoCD into k3s and expose it via NodePort
#
# Steps:
#   1. Create the 'argocd' namespace
#   2. Apply the upstream ArgoCD install manifest
#   3. Wait for argocd-server deployment to become ready
#   4. Patch argocd-server to run --insecure (plain HTTP for the PoC)
#   5. Create a NodePort service so the ArgoCD UI is reachable on host port 8080
set -e

ARGOCD_VERSION="${ARGOCD_VERSION:-v2.9.3}"
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-argocd}"
ARGOCD_NODEPORT="${ARGOCD_NODEPORT:-30080}"
SETUP_OUTPUT="${SETUP_OUTPUT:-/setup-output}"
MANIFEST_URL="https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml"

echo ">>> [argocd-install] Installing ArgoCD ${ARGOCD_VERSION} in namespace '${ARGOCD_NAMESPACE}'..."

# ── 1. Namespace ──────────────────────────────────────────────────────────────
kubectl create namespace "${ARGOCD_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

# ── 2. ArgoCD manifests ───────────────────────────────────────────────────────
echo "    Downloading and applying install.yaml (this may take a moment)..."
curl -sSLo /tmp/argocd-install.yaml "${MANIFEST_URL}"
kubectl apply -n "${ARGOCD_NAMESPACE}" -f /tmp/argocd-install.yaml

# ── 3. Wait for pods ──────────────────────────────────────────────────────────
echo "    Waiting for ArgoCD server deployment..."
kubectl rollout status deployment/argocd-server \
  -n "${ARGOCD_NAMESPACE}" \
  --timeout=300s

echo "    Waiting for all ArgoCD pods to be Ready..."
kubectl wait pod \
  --namespace="${ARGOCD_NAMESPACE}" \
  --for=condition=Ready \
  --selector=app.kubernetes.io/part-of=argocd \
  --timeout=300s

# ── 4. Run argocd-server in --insecure mode (HTTP) ───────────────────────────
kubectl patch deployment argocd-server \
  -n "${ARGOCD_NAMESPACE}" \
  --type=json \
  -p='[{
    "op": "add",
    "path": "/spec/template/spec/containers/0/args/-",
    "value": "--insecure"
  }]'

kubectl rollout status deployment/argocd-server \
  -n "${ARGOCD_NAMESPACE}" \
  --timeout=120s

# ── 5. NodePort service ───────────────────────────────────────────────────────
# Expose the ArgoCD server HTTP port (8080) as a NodePort so that
# the host can reach it at http://localhost:8080 (docker-compose port mapping).
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: argocd-server-nodeport
  namespace: ${ARGOCD_NAMESPACE}
  labels:
    app.kubernetes.io/name: argocd-server-nodeport
spec:
  type: NodePort
  selector:
    app.kubernetes.io/name: argocd-server
  ports:
    - name: http
      port: 80
      targetPort: 8080
      nodePort: ${ARGOCD_NODEPORT}
EOF

# ── 6. Save ArgoCD server address ─────────────────────────────────────────────
# The setup container reaches ArgoCD via the k3s node IP on the NodePort.
# The k3s container is on the 'poc-network'; its service name is 'k3s'.
ARGOCD_SERVER_INTERNAL="http://k3s:${ARGOCD_NODEPORT}"
echo "ARGOCD_SERVER=${ARGOCD_SERVER_INTERNAL}" >> "${SETUP_OUTPUT}/vault-oidc.env"
echo "ARGOCD_NAMESPACE=${ARGOCD_NAMESPACE}" >> "${SETUP_OUTPUT}/vault-oidc.env"

echo ">>> [argocd-install] ArgoCD installed."
echo "    Internal: ${ARGOCD_SERVER_INTERNAL}"
echo "    Host:     http://localhost:8080"
