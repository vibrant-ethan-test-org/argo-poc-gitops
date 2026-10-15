#!/usr/bin/env bash
# Creates three kind clusters and wires them together:
#   argo-mgmt  Argo CD (UI, ApplicationSet, Notifications, Rollouts UI extension)
#   argo-test  Argo Rollouts + all test namespaces
#   argo-prod  Argo Rollouts + all prod namespaces
# Registers test and prod with Argo CD, then points Argo CD at this repo.
# Everything after that (projects, apps, notifications) comes from Git. Safe to re-run.
set -euo pipefail

ARGOCD_VERSION=v3.5.5
ROLLOUTS_VERSION=v1.10.0
DIR="$(cd "$(dirname "$0")" && pwd)"
mgmt() { kubectl --context kind-argo-mgmt "$@"; }

for c in mgmt test prod; do
  if ! kind get clusters | grep -qx "argo-$c"; then
    kind create cluster --config "$DIR/kind-$c.yaml"
  fi
done

echo "==> Argo CD $ARGOCD_VERSION on argo-mgmt"
mgmt create namespace argocd --dry-run=client -o yaml | mgmt apply -f -
mgmt apply -n argocd --server-side --force-conflicts \
  -f "https://raw.githubusercontent.com/argoproj/argo-cd/$ARGOCD_VERSION/manifests/install.yaml"
# Poll Git every 30s (GitHub cannot send webhooks to a laptop).
mgmt -n argocd patch configmap argocd-cm --type merge -p '{"data":{"timeout.reconciliation":"30s"}}'
# Expose the UI on https://localhost:8443 via the kind port mapping.
mgmt -n argocd patch svc argocd-server -p '{"spec":{"type":"NodePort","ports":[{"port":443,"nodePort":30443}]}}'
mgmt -n argocd rollout restart statefulset/argocd-application-controller
# Argo Rollouts UI extension (Rollout tab in the Argo CD UI).
mgmt -n argocd patch deployment argocd-server --patch-file "$DIR/argocd-rollout-extension.yaml"

for c in test prod; do
  echo "==> Argo Rollouts $ROLLOUTS_VERSION on argo-$c"
  kubectl --context "kind-argo-$c" create namespace argo-rollouts --dry-run=client -o yaml | kubectl --context "kind-argo-$c" apply -f -
  kubectl --context "kind-argo-$c" apply -n argo-rollouts --server-side --force-conflicts \
    -f "https://github.com/argoproj/argo-rollouts/releases/download/$ROLLOUTS_VERSION/install.yaml"
done

echo "==> Waiting for components"
mgmt -n argocd rollout status deploy/argocd-server --timeout=300s
mgmt -n argocd rollout status deploy/argocd-repo-server --timeout=300s
mgmt -n argocd rollout status statefulset/argocd-application-controller --timeout=300s
for c in test prod; do
  kubectl --context "kind-argo-$c" -n argo-rollouts rollout status deploy/argo-rollouts --timeout=300s
done

# Fixed local login admin / admin instead of a random password per rebuild. Fine only because
# the UI listens on 127.0.0.1 (see kind-mgmt.yaml). Argo CD reads the bcrypt hash from argocd-secret.
echo "==> Argo CD admin password: admin"
hash=$(argocd account bcrypt --password admin)
mgmt -n argocd patch secret argocd-secret --type merge \
  -p "{\"stringData\":{\"admin.password\":\"$hash\",\"admin.passwordMtime\":\"$(date -u +%FT%TZ)\"}}"
mgmt -n argocd delete secret argocd-initial-admin-secret --ignore-not-found

# Register a cluster with Argo CD the way `argocd cluster add` does: a ServiceAccount with
# cluster-admin in the target cluster, and its token in a cluster Secret on argo-mgmt.
# The server address is the node's name on the shared Docker "kind" network, which pods in
# argo-mgmt can reach (localhost ports would not work from inside a cluster).
register_cluster() {
  local name=$1 ctx="kind-argo-$1"
  echo "==> Registering argo-$name with Argo CD as cluster '$name'"
  kubectl --context "$ctx" apply -f - <<YAML
apiVersion: v1
kind: ServiceAccount
metadata: { name: argocd-manager, namespace: kube-system }
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata: { name: argocd-manager }
roleRef: { apiGroup: rbac.authorization.k8s.io, kind: ClusterRole, name: cluster-admin }
subjects: [{ kind: ServiceAccount, name: argocd-manager, namespace: kube-system }]
---
apiVersion: v1
kind: Secret
metadata:
  name: argocd-manager-token
  namespace: kube-system
  annotations: { kubernetes.io/service-account.name: argocd-manager }
type: kubernetes.io/service-account-token
YAML
  local token=""
  for _ in $(seq 1 30); do
    token=$(kubectl --context "$ctx" -n kube-system get secret argocd-manager-token -o jsonpath='{.data.token}' | base64 -d)
    [ -n "$token" ] && break; sleep 1
  done
  local ca; ca=$(kubectl --context "$ctx" -n kube-system get secret argocd-manager-token -o jsonpath='{.data.ca\.crt}')
  mgmt apply -f - <<YAML
apiVersion: v1
kind: Secret
metadata:
  name: cluster-$name
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: cluster
    env: $name
type: Opaque
stringData:
  name: $name
  server: https://argo-$name-control-plane:6443
  config: '{"bearerToken":"$token","tlsClientConfig":{"insecure":false,"caData":"$ca"}}'
YAML
}
register_cluster test
register_cluster prod

TOKEN_FILE="${TOKEN_FILE:-$HOME/.config/argo-poc/token}"
if [ -f "$TOKEN_FILE" ]; then
  echo "==> Notifications token from $TOKEN_FILE"
  tmp=$(mktemp); trap 'rm -f "$tmp"' EXIT
  tr -d '[:space:]' < "$TOKEN_FILE" > "$tmp"
  mgmt -n argocd create secret generic argocd-notifications-secret --from-file=github-token="$tmp" \
    --dry-run=client -o yaml | mgmt apply --server-side --force-conflicts -f -
else
  echo "==> No token at $TOKEN_FILE: GitHub notifications will not work until argocd-notifications-secret is set"
fi

echo "==> Apps: everything else comes from Git"
mgmt apply -f "$DIR/../argocd/root.yaml"

echo
echo "Argo CD UI: https://localhost:8443  (user: admin, password: admin)"
