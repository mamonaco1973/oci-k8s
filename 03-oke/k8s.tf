# ==============================================================================
# FILE: k8s.tf — In-cluster objects Terraform owns
# ------------------------------------------------------------------------------
# Two things the AWS build did differently:
#
#   1. IMAGE PULL SECRETS. EKS nodes pull from ECR using the node instance
#      role, so nothing had to be created. OCIR always requires a login, even
#      from inside the same tenancy, so every namespace that runs an image
#      needs a docker-registry secret and every pod spec needs to name it.
#
#   2. THE SERVICE ACCOUNT ANNOTATION. IRSA needed one, pointing at a role ARN.
#      Workload identity needs none — the policy in iam.tf names the service
#      account directly, so the account itself is unadorned.
# ==============================================================================

# ==============================================================================
# SECTION: OCIR image pull secrets
# ------------------------------------------------------------------------------
# One per namespace, because a secret is namespaced and the games run in their
# own. Both hold the same credentials: the auth token apply.sh created to push.
# ==============================================================================

locals {
  ocir_host = "${var.region}.ocir.io"

  ocir_dockerconfig = jsonencode({
    auths = {
      (local.ocir_host) = {
        username = var.ocir_username
        password = var.ocir_token
        auth     = base64encode("${var.ocir_username}:${var.ocir_token}")
      }
    }
  })
}

resource "kubernetes_namespace" "games" {
  metadata {
    name = "games"
  }

  # Nodes have to exist before the API server will accept namespaced writes.
  depends_on = [oci_containerengine_node_pool.game_nodes]
}

resource "kubernetes_secret" "ocir_default" {
  metadata {
    name      = "ocir-secret"
    namespace = "default"
  }

  type = "kubernetes.io/dockerconfigjson"

  data = {
    ".dockerconfigjson" = local.ocir_dockerconfig
  }

  depends_on = [oci_containerengine_node_pool.flask_nodes]
}

resource "kubernetes_secret" "ocir_games" {
  metadata {
    name      = "ocir-secret"
    namespace = kubernetes_namespace.games.metadata[0].name
  }

  type = "kubernetes.io/dockerconfigjson"

  data = {
    ".dockerconfigjson" = local.ocir_dockerconfig
  }
}

# ==============================================================================
# SECTION: Service account for NoSQL access
# ------------------------------------------------------------------------------
# Named in the workload identity policy in iam.tf. The name, the namespace and
# the cluster OCID together are the whole of the trust relationship — change
# any one of them here and the policy stops matching, with the pod seeing a
# 404 from NoSQL rather than a permission error.
# ==============================================================================

resource "kubernetes_service_account" "nosql_access" {
  metadata {
    name      = "nosql-access-sa"
    namespace = "default"
  }

  depends_on = [oci_containerengine_node_pool.flask_nodes]
}
