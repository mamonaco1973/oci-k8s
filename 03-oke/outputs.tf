# ==============================================================================
# FILE: outputs.tf — Values the scripts need after the cluster is up
# ------------------------------------------------------------------------------
# cluster_ocid is the one apply.sh and validate.sh cannot derive on their own:
# `oci ce cluster create-kubeconfig` addresses the cluster by OCID, not by name
# the way `aws eks update-kubeconfig` did.
# ==============================================================================

output "cluster_ocid" {
  description = "OCID of the OKE cluster — used to generate the kubeconfig"
  value       = oci_containerengine_cluster.k8s.id
}

output "cluster_name" {
  description = "Display name of the OKE cluster"
  value       = oci_containerengine_cluster.k8s.name
}

output "nosql_table_name" {
  description = "NoSQL table backing the candidates API"
  value       = oci_nosql_table.candidates.name
}

output "flask_node_pool_ocid" {
  description = "Node pool the cluster autoscaler is allowed to resize"
  value       = oci_containerengine_node_pool.flask_nodes.id
}
