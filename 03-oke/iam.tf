# ==============================================================================
# FILE: iam.tf — Cluster identity
# ------------------------------------------------------------------------------
# Replaces roles.tf, which was roughly a hundred and fifty lines of IAM roles,
# assume-role documents, managed policy attachments and an OIDC provider whose
# thumbprint had to be scraped off a TLS certificate. OCI needs none of that
# scaffolding: there is no role to assume and no trust policy to write, only a
# statement naming who is allowed to do what.
#
# Two principals need permissions:
#
#   1. The Flask pod, reaching OCI NoSQL. WORKLOAD identity — the direct
#      equivalent of IRSA. The policy matches a specific service account in a
#      specific namespace on a specific cluster.
#
#   2. The cluster autoscaler, resizing node pools. INSTANCE identity, because
#      it acts on the cluster itself rather than on a tenant workload.
#
# Both live at the tenancy root and use the home-region provider — dynamic
# groups and policies are rejected anywhere else.
# ==============================================================================

# ==============================================================================
# SECTION: Workload identity — Flask pod to NoSQL
# ------------------------------------------------------------------------------
# This is the whole of what IRSA did. No OIDC provider resource, no TLS
# certificate data source, no thumbprint, no assumable-role module.
#
# All four conditions matter. Dropping the service_account clause would let any
# pod in the namespace read the table; dropping cluster_id would extend it to
# every cluster in the compartment.
# ==============================================================================

resource "oci_identity_policy" "nosql_workload" {
  provider       = oci.home
  compartment_id = var.tenancy_ocid
  name           = "flask-oke-nosql-workload"
  description    = "Flask pods on the OKE cluster may read and write Candidates"

  statements = [
    join(" ", [
      "Allow any-user to manage nosql-rows in compartment id",
      "${var.compartment_ocid} where all {",
      "request.principal.type = 'workload',",
      "request.principal.namespace = 'default',",
      "request.principal.service_account = 'nosql-access-sa',",
      "request.principal.cluster_id = '${oci_containerengine_cluster.k8s.id}'",
      "}",
    ]),
    join(" ", [
      "Allow any-user to use nosql-tables in compartment id",
      "${var.compartment_ocid} where all {",
      "request.principal.type = 'workload',",
      "request.principal.namespace = 'default',",
      "request.principal.service_account = 'nosql-access-sa',",
      "request.principal.cluster_id = '${oci_containerengine_cluster.k8s.id}'",
      "}",
    ]),
  ]
}

# ==============================================================================
# SECTION: Instance identity — cluster autoscaler
# ------------------------------------------------------------------------------
# ORDERING MATTERS HERE, and the failure is silent. An instance principal
# caches its dynamic group membership at boot: a node that starts before this
# group exists holds a token that names no groups, and every OCI call it makes
# returns 404 for the lifetime of that node — not 403, so it reads as "the node
# pool does not exist" rather than "you are not allowed". The depends_on on the
# node pools is what keeps that from happening on a fresh apply.
# ==============================================================================

resource "oci_identity_dynamic_group" "worker_nodes" {
  provider       = oci.home
  compartment_id = var.tenancy_ocid
  name           = "flask-oke-worker-nodes"
  description    = "OKE worker node instances for the flask cluster"

  # Matching rules must be written against instance.* attributes. The obvious
  # form, resource.type = 'instance', silently matches nothing.
  matching_rule = "ALL {instance.compartment.id = '${var.compartment_ocid}'}"
}

resource "oci_identity_policy" "autoscaler" {
  provider       = oci.home
  compartment_id = var.tenancy_ocid
  name           = "flask-oke-autoscaler"
  description    = "Cluster autoscaler may resize node pools on the flask cluster"

  statements = [
    "Allow dynamic-group ${oci_identity_dynamic_group.worker_nodes.name} to manage cluster-node-pools in compartment id ${var.compartment_ocid}",
    "Allow dynamic-group ${oci_identity_dynamic_group.worker_nodes.name} to manage instance-family in compartment id ${var.compartment_ocid}",
    "Allow dynamic-group ${oci_identity_dynamic_group.worker_nodes.name} to use subnets in compartment id ${var.compartment_ocid}",
    "Allow dynamic-group ${oci_identity_dynamic_group.worker_nodes.name} to read virtual-network-family in compartment id ${var.compartment_ocid}",
    "Allow dynamic-group ${oci_identity_dynamic_group.worker_nodes.name} to use vnics in compartment id ${var.compartment_ocid}",
    "Allow dynamic-group ${oci_identity_dynamic_group.worker_nodes.name} to inspect compartments in compartment id ${var.compartment_ocid}",
  ]
}
