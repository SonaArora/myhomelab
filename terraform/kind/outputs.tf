output "kubeconfig" {
  description = "Kubeconfig for the KIND cluster"
  value       = kind_cluster.ci.kubeconfig
  sensitive   = true
}

output "kubeconfig_path" {
  description = "Path to the kubeconfig file on disk"
  value       = kind_cluster.ci.kubeconfig_path
}

output "cluster_name" {
  description = "Name of the KIND cluster"
  value       = kind_cluster.ci.name
}
