#!/usr/bin/env bash
set -euo pipefail

ARTIFACTS_DIR="${CI_PROJECT_DIR}/artifacts"
APP_STATUS_LOG="${ARTIFACTS_DIR}/app-status.log"

# ──────────────────────────────────────────────
# Helpers
# ──────────────────────────────────────────────

init_artifacts() {
  mkdir -p "$ARTIFACTS_DIR"
  touch "$APP_STATUS_LOG"
}

log() {
  echo "$*" | tee -a "$APP_STATUS_LOG"
}

capture_app_detail() {
  local app="$1"
  local app_log="${ARTIFACTS_DIR}/sync-failure-${app}.log"
  {
    echo "=== argocd app get $app ==="
    argocd app get "$app" 2>&1 || true
    echo ""
    echo "=== kubectl describe application $app ==="
    kubectl describe application "$app" -n argo-cd 2>&1 || true
    echo ""
  } > "$app_log"
  log "  Sync failure details captured in: sync-failure-${app}.log"
}

# ──────────────────────────────────────────────
# Functions
# ──────────────────────────────────────────────

create_cluster() {
  cd "$TF_DIR"
  terraform init
  terraform apply -auto-approve -var="cluster_name=${CLUSTER_NAME}"
  export KUBECONFIG
  KUBECONFIG=$(terraform output -raw kubeconfig_path)
  sed -i "s/0.0.0.0/docker/g" "$KUBECONFIG"
  kubectl config set-cluster "kind-${CLUSTER_NAME}" --insecure-skip-tls-verify=true
  kubectl cluster-info
}

install_iscsi() {
  docker exec "${CLUSTER_NAME}-control-plane" bash -c \
    "apt-get update && apt-get install -y open-iscsi && systemctl enable iscsid"
}

install_argocd() {
  kubectl create namespace argo-cd
  helm repo add argo-cd https://argoproj.github.io/argo-helm
  helm repo update
  helm install argo-cd argo-cd/argo-cd \
    --namespace argo-cd \
    --wait --timeout 5m
  argocd login --core
}

apply_root_app() {
  kubectl apply -f "$CI_PROJECT_DIR/k8s-manifests/root-app.yml"
}

disable_ingress() {
  local ci_values_dir="$CI_PROJECT_DIR/k8s-manifests/infra-app/ci-values"
  argocd app set argo-cd --values-literal-file "$ci_values_dir/argo-cd.yaml"
  argocd app set monitoring-stack --values-literal-file "$ci_values_dir/monitoring-stack.yaml"
  argocd app set longhorn --values-literal-file "$ci_values_dir/longhorn.yaml"
}

wait_for_root_app() {
  echo "Waiting for root-app to sync..."
  timeout 20 sh -c '
    until kubectl get application root-app -n argo-cd \
      -o jsonpath="{.status.sync.status}" 2>/dev/null \
      | grep -q "Synced"; do
      echo "  status: $(kubectl get application root-app -n argo-cd \
        -o jsonpath="{.status.sync.status}" 2>/dev/null || echo pending)"
      sleep 5
    done
  '
}

verify_child_apps() {
  local EXPECTED="argo-cd cert-manager cnpg metric-server monitoring-stack"
  local UNHEALTHY=0
  local UNHEALTHY_APPS=""

  kubectl config set-context --current --namespace=argo-cd

  log "=== ArgoCD App List ==="
  argocd app list 2>&1 | tee -a "$APP_STATUS_LOG"
  log ""

  log "=== Checking child applications ==="
  for app in $EXPECTED; do
    local SYNC HEALTH
    SYNC=$(kubectl get application "$app" -o jsonpath="{.status.sync.status}" 2>/dev/null || echo "Unknown")
    HEALTH=$(kubectl get application "$app" -o jsonpath="{.status.health.status}" 2>/dev/null || echo "Unknown")

    if [ "$SYNC" = "Synced" ] && [ "$HEALTH" = "Healthy" ]; then
      log "  OK: $app — Sync=$SYNC Health=$HEALTH"
    else
      log "  WARN: $app — Sync=$SYNC Health=$HEALTH. Triggering argocd sync..."
      argocd app sync "$app" >> "$APP_STATUS_LOG" 2>&1 || true

      SYNC=$(kubectl get application "$app" -o jsonpath="{.status.sync.status}" 2>/dev/null || echo "Unknown")
      HEALTH=$(kubectl get application "$app" -o jsonpath="{.status.health.status}" 2>/dev/null || echo "Unknown")

      if [ "$SYNC" = "Synced" ] && [ "$HEALTH" = "Healthy" ]; then
        log "  OK: $app — Synced and Healthy after sync"
      else
        log "  FAIL: $app — Sync=$SYNC Health=$HEALTH after sync"
        capture_app_detail "$app"
        UNHEALTHY=$((UNHEALTHY + 1))
        UNHEALTHY_APPS="$UNHEALTHY_APPS $app"
      fi
    fi
  done

  log ""
  log "=== Final ArgoCD App List ==="
  argocd app list 2>&1 | tee -a "$APP_STATUS_LOG"

  if [ "$UNHEALTHY" -gt 0 ]; then
    echo "FAIL: $UNHEALTHY application(s) not Synced and Healthy:$UNHEALTHY_APPS"
    echo "See artifacts: app-status.log and sync-failures.log"
    exit 1
  fi
  echo "All expected applications Synced and Healthy."
}

destroy_cluster() {
  cd "$TF_DIR"
  terraform destroy -auto-approve -var="cluster_name=${CLUSTER_NAME}" || true
}

# ──────────────────────────────────────────────
# Main
# ──────────────────────────────────────────────

main() {
  init_artifacts
  create_cluster
  install_iscsi
  install_argocd
  apply_root_app
  disable_ingress
  wait_for_root_app
  verify_child_apps
}

# Allow calling a specific function by passing its name as an argument
# e.g. bash script.sh destroy_cluster
if [ "${1:-}" != "" ]; then
  "$1"
else
  main
fi
