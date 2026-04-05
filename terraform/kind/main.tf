resource "kind_cluster" "ci" {
  name           = var.cluster_name
  wait_for_ready = true

  kind_config {
    kind        = "Cluster"
    api_version = "kind.x-k8s.io/v1alpha4"

    networking {
      api_server_address = "0.0.0.0"
    }

    node {
      role = "control-plane"
    }
  }
}
