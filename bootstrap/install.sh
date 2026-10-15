#!/usr/bin/env bash
# Creates the kind cluster and installs Argo CD and Argo Rollouts. Safe to re-run.
set -euo pipefail

ARGOCD_VERSION=v3.5.5
ROLLOUTS_VERSION=v1.10.0
CTX=kind-argo-poc
DIR="$(cd "$(dirname "$0")" && pwd)"
k() { kubectl --context "$CTX" "$@"; }

if ! kind get clusters | grep -qx argo-poc; then
  kind create cluster --config "$DIR/kind-config.yaml"
fi

echo "==> Argo CD $ARGOCD_VERSION"
k create namespace argocd --dry-run=client -o yaml | k apply -f -
k apply -n argocd --server-side --force-conflicts \
  -f "https://raw.githubusercontent.com/argoproj/argo-cd/$ARGOCD_VERSION/manifests/install.yaml"
# Poll Git every 30s (GitHub cannot send webhooks to a laptop).
k -n argocd patch configmap argocd-cm --type merge -p '{"data":{"timeout.reconciliation":"30s"}}'
# Expose the UI on https://localhost:8443 via the kind port mapping.
k -n argocd patch svc argocd-server -p '{"spec":{"type":"NodePort","ports":[{"port":443,"nodePort":30443}]}}'
k -n argocd rollout restart statefulset/argocd-application-controller
# Argo Rollouts UI extension (Rollout tab in the Argo CD UI).
k -n argocd patch deployment argocd-server --patch-file "$DIR/argocd-rollout-extension.yaml"

echo "==> Argo Rollouts $ROLLOUTS_VERSION"
k create namespace argo-rollouts --dry-run=client -o yaml | k apply -f -
k apply -n argo-rollouts --server-side --force-conflicts \
  -f "https://github.com/argoproj/argo-rollouts/releases/download/$ROLLOUTS_VERSION/install.yaml"

echo "==> Waiting for components"
k -n argocd rollout status deploy/argocd-server --timeout=300s
k -n argocd rollout status deploy/argocd-repo-server --timeout=300s
k -n argocd rollout status statefulset/argocd-application-controller --timeout=300s
k -n argo-rollouts rollout status deploy/argo-rollouts --timeout=300s

echo
echo "Argo CD UI: https://localhost:8443  (user: admin)"
echo "Password:   kubectl --context $CTX -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
