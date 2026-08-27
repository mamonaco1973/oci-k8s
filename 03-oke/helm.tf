# ==============================================================================
# FILE: helm.tf — Cluster add-ons
# ------------------------------------------------------------------------------
# TWO CHARTS, NOT THREE. The AWS build installed the AWS Load Balancer
# Controller so that Kubernetes could create an ALB at all — a chart, a service
# account, an IRSA role and a two-hundred-line IAM policy, all of it plumbing
# for something OKE already does.
#
# OKE ships the OCI cloud controller manager inside the cluster. A Service of
# type LoadBalancer provisions an OCI load balancer with no controller to
# install and no policy to write, which is why that entire file is gone.
#
# metrics-server is here because the Flask HPA scales on CPU and OKE, unlike
# EKS, does not install it as an add-on.
# ==============================================================================

# ==============================================================================
# SECTION: metrics-server — supplies CPU metrics to the HPA
# ==============================================================================

resource "helm_release" "metrics_server" {
  name       = "metrics-server"
  repository = "https://kubernetes-sigs.github.io/metrics-server/"
  chart      = "metrics-server"
  namespace  = "kube-system"
  version    = "3.12.2"

  # Worker kubelets present a certificate signed for their internal name,
  # which metrics-server cannot verify against the cluster CA. Every OKE
  # install needs this; without it the HPA reports <unknown> forever.
  set = [{
    name  = "args[0]"
    value = "--kubelet-insecure-tls"
  }]

  depends_on = [oci_containerengine_node_pool.flask_nodes]
}

# ==============================================================================
# SECTION: Cluster autoscaler — grows the flask pool under load
# ------------------------------------------------------------------------------
# Authenticates with the worker node instance principal, which is what the
# dynamic group and policy in iam.tf grant. The node pool OCID is passed as a
# bounded range: the chart takes min:max:ocid and will not scale outside it.
#
# Only the flask pool is registered. The game pool is deliberately absent so
# the autoscaler never touches it.
# ==============================================================================

resource "helm_release" "cluster_autoscaler" {
  name       = "cluster-autoscaler"
  repository = "https://kubernetes.github.io/autoscaler"
  chart      = "cluster-autoscaler"
  namespace  = "kube-system"
  version    = "9.37.0"

  values = [
    templatefile("${path.module}/yaml/autoscaler.yaml.tmpl", {
      node_pool_id = oci_containerengine_node_pool.flask_nodes.id
      region       = var.region
    })
  ]

  depends_on = [oci_containerengine_node_pool.flask_nodes]
}

# ==============================================================================
# SECTION: NGINX ingress — the one public entry point
# ------------------------------------------------------------------------------
# Its Service is type LoadBalancer, so the cloud controller manager creates an
# OCI load balancer in the subnet named by service_lb_subnet_ids on the
# cluster. Everything reaches the applications through this one address.
# ==============================================================================

resource "helm_release" "nginx_ingress" {
  name             = "nginx-ingress"
  repository       = "https://kubernetes.github.io/ingress-nginx"
  chart            = "ingress-nginx"
  namespace        = "ingress-nginx"
  create_namespace = true

  values = [file("${path.module}/yaml/nginx-values.yaml")]

  depends_on = [oci_containerengine_node_pool.flask_nodes]
}
