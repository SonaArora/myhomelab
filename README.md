# myhomelab

A Kubernetes homelab built with the same practices used in production: infrastructure as code, GitOps, automated testing on every change, and zero manual steps after initial setup. The goal is a fully reproducible environment anyone can clone and run - VMs, cluster, and applications included.

---

## Architecture

```
+-----------------------------------------------------------------------+
|  Semaphore  (Ansible UI - one-click provisioning)                     |
|  site.yaml -> create VMs -> K8s cluster -> ArgoCD -> apps             |
+-----------------------------------------------------------------------+
                              |
                              | provisions
                              v
+-----------------------------------------------------------------------+
|  KVM Host  (Linux)                                                    |
|                                                                       |
|  +------------------------------------------------------------------+ |
|  |  Kubernetes Cluster  (Kubespray + Cilium CNI)                    | |
|  |                                                                  | |
|  |  +-----------+    +-----------+    +-----------+                 | |
|  |  |  node 1   |    |  node 2   |    |  node 3   |                 | |
|  |  |  control  |    |  control  |    |  control  |                 | |
|  |  |  + etcd   |    |  + etcd   |    |  + etcd   |                 | |
|  |  +-----------+    +-----------+    +-----------+                 | |
|  |                                                                  | |
|  |  +------------------------------------------------------------+  | |
|  |  |  ArgoCD  (App-of-Apps)                                     |  | |
|  |  |                                                            |  | |
|  |  |  Longhorn (storage)     Prometheus + Grafana               |  | |
|  |  |  CNPG (PostgreSQL)      AlertManager + Kargo               |  | |
|  |  |  Cert-Manager           Metrics Server                     |  | |
|  |  +------------------------------------------------------------+  | |
|  |                                                                  | |
|  |  Tailscale Operator  (ingress + TLS + encrypted node mesh)       | |
|  +------------------------------------------------------------------+ |
+-----------------------------------------------------------------------+
                              |
                        Tailscale VPN
                              |
                    +-----------------------+
                    |  Access from anywhere |
                    |  Grafana, ArgoCD,     |
                    |  kubectl              |
                    +-----------------------+
```

---

## How it all fits together

```
  edit manifest  ->  open MR
                         |
                         |
              ┌──────────────────────────────────────────┐
              │           GitLab CI Pipeline             │
              │                                          │
              │  lint + security scan                    │
              │         |                                │
              │  spin up ephemeral KIND cluster          │
              │         |                                │
              │  deploy ArgoCD + root app (CI overlay)   │
              │         |                                │
              │  wait: all apps Synced + Healthy         │
              │         |                                │
              │      pass / fail                         │
              └──────────────────────────────────────────┘
                         |
                    merge to main
                         |
              ArgoCD detects Git drift
                         |
              applies changes to cluster  (no kubectl apply needed)
```

This loop means you can trust every merged change works, and the production cluster always reflects what is in Git.

---

## Initial cluster setup (one-time)

Before GitOps can take over, the cluster itself needs to exist. Ansible handles this end-to-end, driven by **Semaphore** - a self-hosted web UI for Ansible. One click in Semaphore runs the full sequence:

```
  Semaphore  ->  site.yaml

  1. KVM VMs provisioned via virt-install + cloud-init
       (CentOS Stream 10, SSH keys, Tailscale VPN auto-join)

  2. Kubernetes cluster deployed via Kubespray
       (3-node control plane + etcd, Cilium CNI)

  3. Tailscale Operator + ArgoCD installed via Helm
       (all ingress routed through Tailscale - no public LB)

  4. Root ArgoCD application applied
       (App-of-Apps bootstraps the full stack from Git)
```

After step 4, ArgoCD owns the cluster. All future changes go through Git and CI.

---

## Technology stack

| Layer                | Technology                                               | Why                                                                 |
|----------------------|----------------------------------------------------------|---------------------------------------------------------------------|
| Virtualization       | KVM/QEMU, libvirt, cloud-init                            | Native Linux hypervisor, no licensing cost, full automation support |
| Guest OS             | CentOS Stream 10                                         | RHEL-compatible, stable, well-supported by Kubespray                |
| Kubernetes           | Kubespray + Cilium CNI                                   | Production-grade installer; Cilium for eBPF networking and policy   |
| VPN / Networking     | Tailscale + Tailscale Operator                           | Zero-config encrypted mesh; operator handles ingress and certs      |
| GitOps               | ArgoCD                                                   | Declarative, Git-driven reconciliation - the cluster mirrors Git    |
| Progressive Delivery | Kargo                                                    | Automated promotion across environments on top of ArgoCD            |
| Storage              | Longhorn                                                 | Distributed block storage built for Kubernetes, no NFS needed       |
| Databases            | CloudNative PostgreSQL (CNPG)                            | HA Postgres with automatic failover, backup, and streaming replication |
| Monitoring           | Prometheus + Grafana + AlertManager                      | Industry standard; pre-built dashboards for Kubernetes              |
| TLS                  | Cert-Manager                                             | Automatic certificate lifecycle management                          |
| Config Mgmt          | Ansible + Semaphore                                      | Ansible for automation; Semaphore for one-click UI without a terminal |
| IaC (CI clusters)    | Terraform + KIND provider                                | Ephemeral Kubernetes clusters for CI are declared in Terraform and created/destroyed per pipeline run |
| CI/CD                | GitLab CI                                                | Every manifest change tested on a real ephemeral cluster before merge |
| Code Quality         | ansible-lint, yamllint, markdownlint, pre-commit         | Enforced at commit time and in CI                                   |

---

## GitOps application stack

ArgoCD uses the [App-of-Apps pattern](https://argo-cd.readthedocs.io/en/stable/operator-manual/cluster-bootstrapping/) - a single root application manages everything else. Add a new app by adding a file to Git; ArgoCD picks it up automatically.

```
k8s-manifests/root-app.yml
└── infra-app/ (Kustomize)
    ├── argo-cd.yaml          - ArgoCD itself (self-managed)
    ├── cert-manager.yaml     - Automatic TLS certificates
    ├── longhorn.yaml         - Distributed block storage
    ├── monitoring-stack.yaml - Prometheus + Grafana + AlertManager
    ├── cnpg.yaml             - CloudNative PostgreSQL operator
    ├── kargo.yaml            - Progressive delivery
    └── metric-server.yaml    - Pod and node resource metrics
```

Kustomize overlays handle environment differences cleanly:

| Overlay          | Used for    | Difference from base                        |
|------------------|-------------|---------------------------------------------|
| `base/`          | Production  | Tailscale ingress enabled, full resources   |
| `overlays/ci/`   | CI testing  | Ingress disabled, lighter resource footprint|

---

## CI/CD pipeline in detail

Every commit triggers the GitLab CI pipeline (`.gitlab-ci.yml`):

```
commit / MR
    │
    ├─>  secret-detection   (no hardcoded credentials)
    ├─>  SAST               (static security analysis)
    ├─>  ansible-lint       (playbook best practices)
    ├─>  yaml-lint          (formatting)
    └─>  k8s integration test
              │
              ├─> Terraform creates ephemeral KIND cluster
              ├─> ArgoCD deployed
              ├─> Root app applied (CI overlay - no ingress)
              ├─> Poll: all apps Synced + Healthy?
              │       YES ─> pass, destroy cluster
              │       NO  ─> capture logs, destroy cluster, fail MR
              └─> Result gates the merge
```

**Terraform manages the CI cluster lifecycle.** `terraform/kind/` declares a KIND cluster as infrastructure code using the KIND Terraform provider. Each pipeline run does `terraform apply` to create a fresh cluster and `terraform destroy` to tear it down after the test, ensuring no shared state between runs. The cluster spec (node count, K8s version) is versioned alongside the rest of the project.

The integration test uses `overlays/ci/` so it runs without Tailscale or external dependencies - pure Kubernetes, fully automated. Tailscale is intentionally excluded from CI: to keep CI free of external network dependencies makes it faster, stateless, and runnable on any GitLab runner without pre-provisioned VPN credentials.

---

## Getting started

### Prerequisites

- Linux host with KVM/QEMU and libvirt
- [Semaphore](https://semaphoreui.com/) installed (or Ansible CLI)
- Tailscale account with an OAuth client and an auth key
- Ansible Vault password for secrets decryption

### Clone and configure

```bash
git clone <repo-url>
cd myhomelab
```

Edit `playbooks/vars/cluster.yaml` with your node names and IP addresses. Populate the vault-encrypted secret files (or create your own with `ansible-vault encrypt`):

```
playbooks/vars/tailscale-secrets.yaml  - Tailscale OAuth client + auth keys
playbooks/vars/kargo.yaml              - Kargo admin credentials
```

### Deploy (recommended: Semaphore)

1. Add this repo as a project in Semaphore
2. Configure your vault password and SSH key in Semaphore
3. Create a template pointing to `playbooks/site.yaml`
4. Click **Run** - the full stack provisions itself

### Deploy (CLI)

```bash
# Full stack in one command
ansible-playbook playbooks/site.yaml --vault-password-file vault-pass

# Or phase by phase
ansible-playbook playbooks/create-vm.yaml           # VMs
ansible-playbook playbooks/prerequisite-k8s.yaml    # Pre-flight
ansible-playbook playbooks/cluster.yml               # Kubernetes
ansible-playbook playbooks/install-argocd-tailscale.yaml  # ArgoCD + networking
ansible-playbook playbooks/install-infra-apps.yaml  # Bootstrap apps
ansible-playbook playbooks/create-kargo-secret.yaml # Kargo credentials
```

### Tear down

```bash
ansible-playbook playbooks/delete-vm.yaml
```

### Validate code quality

```bash
tox                      # runs ansible-lint + yamllint
pre-commit run --all-files
```

---

## Repository layout

```
myhomelab/
├── playbooks/                      # Ansible automation
│   ├── site.yaml                   # Master playbook - runs all phases
│   ├── create-vm.yaml
│   ├── prerequisite-k8s.yaml
│   ├── cluster.yml
│   ├── install-argocd-tailscale.yaml
│   ├── install-infra-apps.yaml
│   ├── create-kargo-secret.yaml
│   ├── delete-vm.yaml
│   ├── vars/                       # Config + vault-encrypted secrets
│   └── files/templates/            # cloud-init Jinja2 templates
│
├── k8s-manifests/
│   ├── root-app.yml                # ArgoCD root application
│   └── infra-app/
│       ├── base/                   # Production app definitions
│       └── overlays/ci/            # CI overrides (no ingress)
│
├── monitoring/alerts/              # Custom PrometheusRules
├── terraform/kind/                 # Terraform-managed ephemeral KIND cluster (CI only)
│   ├── main.tf                     # KIND cluster resource
│   ├── providers.tf                # KIND provider config
│   ├── variables.tf                # K8s version, node count
│   └── outputs.tf                  # kubeconfig path
├── scripts/                        # CI test runner scripts
├── .gitlab-ci.yml
└── .pre-commit-config.yaml
```

---

## Secrets

All sensitive values are encrypted with Ansible Vault and safe to commit:

| File                                     | Contains                                    |
|------------------------------------------|---------------------------------------------|
| `playbooks/vars/tailscale-secrets.yaml`  | Tailscale OAuth credentials and auth keys   |
| `playbooks/vars/kargo.yaml`              | Kargo admin password hash + signing key     |

Decrypt locally with a `vault-pass` file (git-ignored). In GitLab CI the vault password is injected as a CI variable.
V