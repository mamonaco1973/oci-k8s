# ==============================================================================
# FILE: main.tf — Providers for the cluster phase
# ------------------------------------------------------------------------------
# Four providers here, and the kubernetes and helm ones are configured from
# attributes of a cluster this same apply creates. That works because Terraform
# resolves provider configuration lazily, but it does mean phase 3 cannot be
# planned against an empty state — apply.sh always runs phase 1 first.
#
# As in phase 1, tenancy-level IAM only accepts writes in the home region, so
# the workload identity policy uses the aliased home provider.
# ==============================================================================

terraform {
  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "~> 6.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.30"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.0"
    }
  }
}

provider "oci" {
  region = var.region
}

provider "oci" {
  alias  = "home"
  region = var.home_region
}

# ==============================================================================
# SECTION: Cluster credentials
# ------------------------------------------------------------------------------
# OKE has no equivalent of `aws_eks_cluster_auth`, which handed the AWS build a
# ready-made bearer token. Authentication goes through the OCI CLI instead:
# `oci ce cluster generate-token` returns a short-lived ExecCredential, and
# both providers below invoke it the same way kubectl does.
#
# The CLI must therefore be on PATH wherever terraform runs. check_env.sh
# enforces that before anything is built.
# ==============================================================================

data "oci_containerengine_cluster_kube_config" "k8s" {
  cluster_id = oci_containerengine_cluster.k8s.id
}

locals {
  kubeconfig = yamldecode(data.oci_containerengine_cluster_kube_config.k8s.content)

  cluster_endpoint = local.kubeconfig["clusters"][0]["cluster"]["server"]
  cluster_ca = base64decode(
    local.kubeconfig["clusters"][0]["cluster"]["certificate-authority-data"]
  )
}

provider "kubernetes" {
  host                   = local.cluster_endpoint
  cluster_ca_certificate = local.cluster_ca

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "oci"
    args = [
      "ce", "cluster", "generate-token",
      "--cluster-id", oci_containerengine_cluster.k8s.id,
      "--region", var.region,
    ]
  }
}

provider "helm" {
  kubernetes = {
    host                   = local.cluster_endpoint
    cluster_ca_certificate = local.cluster_ca

    exec = {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "oci"
      args = [
        "ce", "cluster", "generate-token",
        "--cluster-id", oci_containerengine_cluster.k8s.id,
        "--region", var.region,
      ]
    }
  }
}
