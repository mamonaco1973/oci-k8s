# ==============================================================================
# FILE: oke.tf — The OKE cluster and its two node pools
# ------------------------------------------------------------------------------
# Structure carried over from the AWS build: one cluster, two separately
# labelled pools, so the Flask API and the games land on different nodes and
# the autoscaler can grow one without touching the other.
# ==============================================================================

# ==============================================================================
# SECTION: Node image lookup
# ------------------------------------------------------------------------------
# The AWS build searched for a Canonical Ubuntu AMI by name pattern. OKE does
# not work that way — worker images are published per Kubernetes version and
# must be selected from the node pool options list, because an image built for
# a different version will join the cluster and then fail to run kubelet.
# ==============================================================================

data "oci_containerengine_node_pool_option" "oke" {
  node_pool_option_id = "all"
  compartment_id      = var.compartment_ocid
}

data "oci_identity_availability_domains" "ads" {
  compartment_id = var.tenancy_ocid
}

locals {
  # Strip the leading v — image names carry the bare version number.
  k8s_version_bare = replace(var.kubernetes_version, "v", "")

  # Oracle Linux 8 platform image matching this exact Kubernetes version.
  node_image_id = [
    for src in data.oci_containerengine_node_pool_option.oke.sources :
    src.image_id
    if length(regexall(
      "Oracle-Linux-8.*OKE-${local.k8s_version_bare}",
      src.source_name
    )) > 0
  ][0]

  # Subnets are regional, so every availability domain is reachable from the
  # one node subnet. Spreading placement across all of them is free redundancy.
  placement_ads = data.oci_identity_availability_domains.ads.availability_domains
}

# ==============================================================================
# SECTION: Cluster
# ------------------------------------------------------------------------------
# ENHANCED_CLUSTER is not a size or a support tier — it is the gate on workload
# identity. A BASIC_CLUSTER cannot issue workload principal tokens at all, so
# the Flask pod would have no way to reach NoSQL without a static key. This is
# the OCI equivalent of enabling the OIDC provider on an EKS cluster.
#
# Pod networking is FLANNEL_OVERLAY rather than VCN-native: pod addresses come
# from an overlay range instead of the VCN, which is what lets the node subnet
# stay a /25 inside a /24 VCN.
# ==============================================================================

resource "oci_containerengine_cluster" "k8s" {
  compartment_id     = var.compartment_ocid
  name               = "flask-oke-cluster"
  vcn_id             = data.oci_core_subnet.node.vcn_id
  kubernetes_version = var.kubernetes_version
  type               = "ENHANCED_CLUSTER"

  endpoint_config {
    subnet_id            = var.api_subnet_ocid
    is_public_ip_enabled = true
  }

  cluster_pod_network_options {
    cni_type = "FLANNEL_OVERLAY"
  }

  options {
    # Where the cloud controller manager puts load balancers it creates for
    # Services of type LoadBalancer. nginx-ingress relies on this.
    service_lb_subnet_ids = [var.lb_subnet_ocid]

    add_ons {
      is_kubernetes_dashboard_enabled = false
      is_tiller_enabled               = false
    }
  }
}

# The cluster needs its VCN OCID, which phase 1 does not pass forward directly.
# Reading it back off the node subnet avoids a fifth TF_VAR.
data "oci_core_subnet" "node" {
  subnet_id = var.node_subnet_ocid
}

# ==============================================================================
# SECTION: Node pool — flask-nodes
# ------------------------------------------------------------------------------
# Runs the Flask API. Starts at one node; the cluster autoscaler grows it to
# four under load, which is what stress.yaml demonstrates.
# ==============================================================================

resource "oci_containerengine_node_pool" "flask_nodes" {
  cluster_id         = oci_containerengine_cluster.k8s.id
  compartment_id     = var.compartment_ocid
  name               = "flask-nodes"
  kubernetes_version = var.kubernetes_version
  node_shape         = var.node_shape

  node_shape_config {
    ocpus         = var.node_ocpus
    memory_in_gbs = var.node_memory_gbs
  }

  node_source_details {
    source_type             = "IMAGE"
    image_id                = local.node_image_id
    boot_volume_size_in_gbs = 50
  }

  # The label the flask-app deployment selects on. OKE applies these at join
  # time, so a pod with this nodeSelector stays Pending until a node carries it.
  initial_node_labels {
    key   = "nodegroup"
    value = "flask-nodes"
  }

  node_config_details {
    size = 1

    dynamic "placement_configs" {
      for_each = local.placement_ads
      content {
        availability_domain = placement_configs.value.name
        subnet_id           = var.node_subnet_ocid
      }
    }
  }

  # See iam.tf: an instance principal caches its dynamic group membership at
  # boot, so the group and policy must exist before any node starts.
  depends_on = [
    oci_identity_dynamic_group.worker_nodes,
    oci_identity_policy.autoscaler,
  ]

  # The autoscaler owns the node count once it is running. Without this, every
  # subsequent apply would drag the pool back to the size declared above.
  lifecycle {
    ignore_changes = [node_config_details[0].size]
  }
}

# ==============================================================================
# SECTION: Node pool — game-nodes
# ------------------------------------------------------------------------------
# Fixed at one node. The games are static pages; there is nothing to scale.
# ==============================================================================

resource "oci_containerengine_node_pool" "game_nodes" {
  cluster_id         = oci_containerengine_cluster.k8s.id
  compartment_id     = var.compartment_ocid
  name               = "game-nodes"
  kubernetes_version = var.kubernetes_version
  node_shape         = var.node_shape

  node_shape_config {
    ocpus         = var.node_ocpus
    memory_in_gbs = var.node_memory_gbs
  }

  node_source_details {
    source_type             = "IMAGE"
    image_id                = local.node_image_id
    boot_volume_size_in_gbs = 50
  }

  initial_node_labels {
    key   = "nodegroup"
    value = "game-nodes"
  }

  node_config_details {
    size = 1

    dynamic "placement_configs" {
      for_each = local.placement_ads
      content {
        availability_domain = placement_configs.value.name
        subnet_id           = var.node_subnet_ocid
      }
    }
  }

  # See iam.tf: an instance principal caches its dynamic group membership at
  # boot, so the group and policy must exist before any node starts.
  depends_on = [
    oci_identity_dynamic_group.worker_nodes,
    oci_identity_policy.autoscaler,
  ]
}
