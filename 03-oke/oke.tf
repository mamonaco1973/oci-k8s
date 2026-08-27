# ==============================================================================
# FILE: oke.tf — The OKE cluster and its two node pools
# ------------------------------------------------------------------------------
# Structure carried over from the AWS build: one cluster, two separately
# labelled pools, so the Flask API and the games land on different nodes and
# the autoscaler can grow one without touching the other.
# ==============================================================================

# ==============================================================================
# SECTION: Kubernetes version and node image
# ------------------------------------------------------------------------------
# The AWS build searched for a Canonical Ubuntu AMI by name pattern. OKE does
# not work that way — worker images are published per Kubernetes version, and a
# node pool whose image version does not exactly equal the pool's declared
# version is rejected outright with a 409.
#
# THREE TRAPS LIVE HERE.
#
# 1. THE VERSION MUST BE ONE THE REGION OFFERS. Pinning a plausible-looking
#    version means the config rots the moment OKE moves on. By default the
#    newest version the region advertises is used, so there is nothing to keep
#    up to date. Set var.kubernetes_version to pin it deliberately.
#
# 2. THE IMAGE MATCH MUST BE ANCHORED. Image names read
#    "...-OKE-<version>-<build>", so an unanchored match on 1.33.1 also matches
#    1.33.10 — a real version, a real image, and a node pool that fails with
#    "Kubernetes version does not match Kubernetes version of OKE worker node
#    image". The trailing hyphen in the pattern is what prevents it.
#
# 3. THE ARCHITECTURE MUST MATCH THE SHAPE. The same data source returns x86_64
#    and aarch64 images, distinguished only by "aarch64" appearing in the name.
#    An ARM image on an AMD shape passes plan and is rejected by the API with
#    "Node shape and image are not compatible" — which names the shape, not the
#    image, and sends you off to check the shape. The architecture is derived
#    from var.node_shape below so the two cannot disagree.
# ==============================================================================

data "oci_containerengine_cluster_option" "oke" {
  cluster_option_id = "all"
  compartment_id    = var.compartment_ocid
}

data "oci_containerengine_node_pool_option" "oke" {
  node_pool_option_id = "all"
  compartment_id      = var.compartment_ocid
}

data "oci_identity_availability_domains" "ads" {
  compartment_id = var.tenancy_ocid
}

locals {
  # Versions come back ascending, so the last entry is the newest.
  available_versions = data.oci_containerengine_cluster_option.oke.kubernetes_versions

  k8s_version = (
    var.kubernetes_version != ""
    ? var.kubernetes_version
    : element(local.available_versions, length(local.available_versions) - 1)
  )

  # Strip the leading v — image names carry the bare version number.
  k8s_version_bare = replace(local.k8s_version, "v", "")

  # Ampere shapes are aarch64; everything else here is x86_64. Derived from the
  # shape name so the image follows whatever var.node_shape is set to, rather
  # than the two having to be kept in step by hand.
  is_arm_shape = length(regexall("\\.A[0-9]+\\.", var.node_shape)) > 0

  node_image_candidates = sort([
    for src in data.oci_containerengine_node_pool_option.oke.sources :
    src.source_name
    if(
      # Exactly this Kubernetes version. The trailing hyphen is the anchor
      # described above; without it, 1.33.1 also matches 1.33.10.
      length(regexall("OKE-${local.k8s_version_bare}-", src.source_name)) > 0

      # Plain Oracle Linux 8, not a GPU build.
      && length(regexall("Oracle-Linux-8", src.source_name)) > 0
      && length(regexall("GPU", src.source_name)) == 0

      # Matching architecture. Both are returned by the same data source, and
      # picking the wrong one is accepted at plan time and rejected by the API
      # with "Node shape and image are not compatible" — a message that names
      # the shape rather than the image.
      && (
        local.is_arm_shape
        ? length(regexall("aarch64", src.source_name)) > 0
        : length(regexall("aarch64", src.source_name)) == 0
      )
    )
  ])

  # Names embed a build date, so sorted ascending the last entry is the newest.
  node_image_name = (
    length(local.node_image_candidates) > 0
    ? element(local.node_image_candidates, length(local.node_image_candidates) - 1)
    : null
  )

  node_image_id = (
    local.node_image_name == null
    ? null
    : [
      for src in data.oci_containerengine_node_pool_option.oke.sources :
      src.image_id if src.source_name == local.node_image_name
    ][0]
  )

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
  kubernetes_version = local.k8s_version
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
  kubernetes_version = local.k8s_version
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

    # Fail with a sentence rather than an opaque 409 from the node pool API
    # when no image matches the resolved version.
    precondition {
      condition     = local.node_image_id != null
      error_message = "No Oracle Linux 8 ${local.is_arm_shape ? "aarch64" : "x86_64"} OKE image found for Kubernetes ${local.k8s_version} in this region. Available versions: ${join(", ", local.available_versions)}."
    }
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
  kubernetes_version = local.k8s_version
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

  lifecycle {
    # Fail with a sentence rather than an opaque 409 from the node pool API
    # when no image matches the resolved version.
    precondition {
      condition     = local.node_image_id != null
      error_message = "No Oracle Linux 8 ${local.is_arm_shape ? "aarch64" : "x86_64"} OKE image found for Kubernetes ${local.k8s_version} in this region. Available versions: ${join(", ", local.available_versions)}."
    }
  }
}
