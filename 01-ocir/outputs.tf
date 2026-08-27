# ==============================================================================
# FILE: outputs.tf — Handoff to phase 3
# ------------------------------------------------------------------------------
# The AWS build re-discovered its network in 03-eks with tag-filtered data
# blocks. OCI has no equivalent tag filter for subnets, so the OCIDs are passed
# forward explicitly instead — apply.sh reads them with `terraform output` and
# exports them as TF_VAR_* before running phase 3.
# ==============================================================================

output "vcn_ocid" {
  description = "OCID of the cluster VCN"
  value       = oci_core_vcn.k8s_vcn.id
}

output "api_subnet_ocid" {
  description = "OCID of the public subnet holding the Kubernetes API endpoint"
  value       = oci_core_subnet.k8s_api_subnet.id
}

output "lb_subnet_ocid" {
  description = "OCID of the public subnet holding service load balancers"
  value       = oci_core_subnet.k8s_lb_subnet.id
}

output "node_subnet_ocid" {
  description = "OCID of the private subnet holding worker nodes"
  value       = oci_core_subnet.k8s_node_subnet.id
}
