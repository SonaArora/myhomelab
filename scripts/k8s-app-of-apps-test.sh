#!/usr/bin/env bash
set -euo pipefail

ARTIFACTS_DIR="${CI_PROJECT_DIR}/artifacts"
APP_STATUS_LOG="${ARTIFACTS_DIR}/app-status.log"

# ──────────────────────────────────────────────
# Helpers
# ──────────────────────────────────────────────

argo_login() {
  log "Logging into ArgoCD..."
  kubectl config set-context --current --namespace=argo-cd
  argocd login --core
}

init_artifacts() {
  mkdir -p "$ARTIFACTS_DIR"
  touch "$APP_STATUS_LOG"
}

_RED='\033[0;31m'
_YELLOW='\033[0;33m'
_GREEN='\033[0;32m'
_CYAN='\033[0;36m'
_NC='\033[0m'

_ts() { date '+%Y-%m-%d %H:%M:%S'; }
log()  { printf "${_CYAN}[INFO]${_NC}  [%s] %s\n"  "$(_ts)" "$*" | tee -a "$APP_STATUS_LOG"; }
warn() { printf "${_YELLOW}[WARN]${_NC}  [%s] %s\n" "$(_ts)" "$*" | tee -a "$APP_STATUS_LOG"; }
error(){ printf "${_RED}[ERROR]${_NC} [%s] %s\n" "$(_ts)" "$*" | tee -a "$APP_STATUS_LOG"; }
ok()   { printf "${_GREEN}[OK]${_NC}    [%s] %s\n"  "$(_ts)" "$*" | tee -a "$APP_STATUS_LOG"; }

# Wrapper for argocd commands (not login): logs the command with timestamp, tees output to a logfile.
# Usage: argocd_run <logfile> <argocd args...>
argocd_run() {
  local logfile="$1"; shift
  log "Running: argocd $*"
  argocd "$@" 2>&1 | tee -a "$logfile"
  return "${PIPESTATUS[0]}"
}

capture_app_detail() {
  local app="$1"
  local app_log="${ARTIFACTS_DIR}/sync-failure-${app}.log"
  {
    argo_login
    echo "=== argocd app get $app ==="
    argocd_run "$app_log" app get "$app" || true
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
  log "Creating kind cluster: ${CLUSTER_NAME}"
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
  log "Installing iSCSI initiator in kind control-plane for Longhorn..."
  docker exec "${CLUSTER_NAME}-control-plane" bash -c \
    "apt-get update && apt-get install -y open-iscsi && systemctl enable iscsid"
}

install_argocd() {
  log "Installing ArgoCD in the cluster..."
  kubectl create namespace argo-cd
  helm repo add argo-cd https://argoproj.github.io/argo-helm
  helm repo update
  helm install argo-cd argo-cd/argo-cd \
    --namespace argo-cd \
    --wait --timeout 5m
  argo_login
}

apply_root_app() {
  log "Applying root ArgoCD application (branch: ${CI_COMMIT_REF_NAME})..."
  sed "s/targetRevision: HEAD/targetRevision: ${CI_COMMIT_REF_NAME}/" \
    "$CI_PROJECT_DIR/k8s-manifests/root-app.yml" | kubectl apply -f -
}

disable_ingress() {
  log "Disabling ingress in CI environment..."
  argo_login
  local ci_values_dir="$CI_PROJECT_DIR/k8s-manifests/infra-app/ci-values"
  argocd_run "$APP_STATUS_LOG" app set argo-cd --values-literal-file "$ci_values_dir/argo-cd.yaml"
  argocd_run "$APP_STATUS_LOG" app set monitoring-stack --values-literal-file "$ci_values_dir/monitoring-stack.yaml"
  argocd_run "$APP_STATUS_LOG" app set longhorn --values-literal-file "$ci_values_dir/longhorn.yaml"
}

wait_for_root_app() {
  log "Waiting for root-app to sync..."
  timeout 20 sh -c '
    until kubectl get application root-app -n argo-cd \
      -o jsonpath="{.status.sync.status}" 2>/dev/null \
      | grep -q "Synced"; do
      echo "  status: $(kubectl get application root-app -n argo-cd \
        -o jsonpath="{.status.sync.status}" 2>/dev/null || echo pending)"
      sleep 5
    done
  '
  log "Waiting 60s for child apps to start syncing..."
  sleep 60
}

verify_child_apps() {
  local EXPECTED="argo-cd cert-manager cnpg metric-server monitoring-stack"
  local UNHEALTHY=0
  local UNHEALTHY_APPS=""

  argo_login

  log "Verifying child applications..."
  log "=== ArgoCD App List ==="
  argocd_run "$APP_STATUS_LOG" app list
  log ""

  log "=== Checking child applications ==="
  for app in $EXPECTED; do
    local SYNC HEALTH
    SYNC=$(kubectl get application "$app" -o jsonpath="{.status.sync.status}" 2>/dev/null || echo "Unknown")
    HEALTH=$(kubectl get application "$app" -o jsonpath="{.status.health.status}" 2>/dev/null || echo "Unknown")

    if [ "$SYNC" = "Synced" ] && [ "$HEALTH" = "Healthy" ]; then
      ok "$app — Sync=$SYNC Health=$HEALTH"
    else
      local app_log="${ARTIFACTS_DIR}/sync-${app}.log"
      warn "$app — Sync=$SYNC Health=$HEALTH. Triggering argocd sync..."
      argocd_run "$app_log" app wait "$app" --operation --timeout 120 || true
      if ! argocd_run "$app_log" app sync "$app"; then
        warn "$app — sync failed, terminating operation and retrying..."
        argocd_run "$app_log" app terminate-op "$app" || true
        argocd_run "$app_log" app sync "$app" || true
      fi

      SYNC=$(kubectl get application "$app" -o jsonpath="{.status.sync.status}" 2>/dev/null || echo "Unknown")
      HEALTH=$(kubectl get application "$app" -o jsonpath="{.status.health.status}" 2>/dev/null || echo "Unknown")

      if [ "$SYNC" = "Synced" ] && [ "$HEALTH" = "Healthy" ]; then
        ok "$app — Synced and Healthy after sync"
      else
        error "$app — Sync=$SYNC Health=$HEALTH after sync"
        capture_app_detail "$app"
        UNHEALTHY=$((UNHEALTHY + 1))
        UNHEALTHY_APPS="$UNHEALTHY_APPS $app"
      fi
    fi
  done

  log ""
  log "=== Final ArgoCD App List ==="
  argocd_run "$APP_STATUS_LOG" app list

  if [ "$UNHEALTHY" -gt 0 ]; then
    error "FAIL: $UNHEALTHY application(s) not Synced and Healthy:$UNHEALTHY_APPS"
    error "See artifacts: app-status.log and sync-failures.log"
    exit 1
  fi
  ok "All expected applications Synced and Healthy."
}

destroy_cluster() {
  log "Destroying kind cluster: ${CLUSTER_NAME}"
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
  wait_for_root_app
  disable_ingress
  verify_child_apps
}

# Allow calling a specific function by passing its name as an argument
# e.g. bash script.sh destroy_cluster
if [ "${1:-}" != "" ]; then
  "$1"
else
  main
fi
