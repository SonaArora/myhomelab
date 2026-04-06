#!/usr/bin/env bash
set -euo pipefail

apk add --no-cache curl bash docker-cli openssl

curl -Lo /usr/local/bin/kind \
  https://kind.sigs.k8s.io/dl/v0.25.0/kind-linux-amd64
chmod +x /usr/local/bin/kind

curl -Lo /usr/local/bin/kubectl \
  https://dl.k8s.io/release/v1.31.4/bin/linux/amd64/kubectl
chmod +x /usr/local/bin/kubectl

curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

curl -sSL -o argocd-linux-amd64 \
  https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64
install -m 555 argocd-linux-amd64 /usr/local/bin/argocd
rm argocd-linux-amd64
