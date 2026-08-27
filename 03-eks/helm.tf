##############################################
# Configure the Helm provider for Kubernetes #
##############################################

provider "helm" {
  kubernetes = {
    host = aws_eks_cluster.flask_eks.endpoint
    # The public endpoint URL of the EKS cluster API server. Required for Helm to interact with the cluster.

    cluster_ca_certificate = base64decode(aws_eks_cluster.flask_eks.certificate_authority[0].data)
    # The EKS cluster CA is provided in base64; it must be decoded so Helm can securely communicate with the cluster.

    token = data.aws_eks_cluster_auth.flask_eks.token
    # An authentication token tied to the EKS cluster identity. Required for API access.
    # Pulled from a separate data source that knows how to authenticate to the EKS cluster using your IAM identity.
  }
}

##############################################################
# Retrieve authentication token from AWS for EKS interaction #
##############################################################

data "aws_eks_cluster_auth" "flask_eks" {
  name = aws_eks_cluster.flask_eks.name
  # This data block retrieves temporary credentials (token) to access the EKS cluster securely.
  # It relies on your AWS IAM permissions and the specified EKS cluster name.
}

#############################################################################
# Deploy the AWS Load Balancer Controller (ALB/NLB integration for EKS)     #
# This Helm chart installs the controller used to create AWS ALBs/NLBs     #
# based on Kubernetes ingress and service resources.                        #
#############################################################################

resource "helm_release" "aws_load_balancer_controller" {
  name       = "aws-load-balancer-controller"
  # Unique Helm release name that will appear in the cluster

  repository = "https://aws.github.io/eks-charts"
  # Official AWS-maintained Helm chart repo for EKS-specific tools

  chart      = "aws-load-balancer-controller"
  # Chart name inside the repo – installs the AWS LB Controller

  namespace  = "kube-system"
  # Installed into kube-system namespace – standard for core components

  values = [
    templatefile("${path.module}/yaml/aws-load-balancer.yaml.tmpl", {
      cluster_name = aws_eks_cluster.flask_eks.name
      # The EKS cluster name passed as a template variable – used in the Helm chart's config

      role_arn     = module.load_balancer_controller_irsa.iam_role_arn
      # IAM Role ARN used for the service account – enables IRSA (IAM Roles for Service Accounts)
      # This gives the controller the permissions it needs to create/manage AWS load balancers
    })
  ]
  # The `values` block pulls in customized configuration for the Helm chart
  # using a Terraform template file and injects dynamic values into it
}

################################################################################
# Deploy Cluster Autoscaler with Helm                                          #
# This monitors node usage and adjusts node count based on pending workloads. #
# Works only with Auto Scaling Groups or Managed Node Groups in EKS.          #
################################################################################

resource "helm_release" "cluster_autoscaler" {
  name       = "cluster-autoscaler"
  # Helm release name shown in cluster metadata

  repository = "https://kubernetes.github.io/autoscaler"
  # Official Kubernetes autoscaler chart repo

  chart      = "cluster-autoscaler"
  # Chart name to deploy

  namespace  = "kube-system"
  # Installed in kube-system for cluster-wide visibility and access

  version    = "9.29.1"
  # Explicit chart version to ensure reproducibility and avoid unplanned upgrades

  values = [
    templatefile("${path.module}/yaml/autoscaler.yaml.tmpl", {
      cluster_name = aws_eks_cluster.flask_eks.name
      # Cluster name used in the configuration to target the correct node groups for scaling
    })
  ]
  # Injects custom values (like cluster name) from a template YAML file to configure the autoscaler chart
}

################################################################################
# Deploy NGINX Ingress Controller with Helm                                    #
# Provides an HTTP(S) load balancer and reverse proxy for Kubernetes services.#
# Required for routing external traffic to in-cluster services using Ingress. #
################################################################################

resource "helm_release" "nginx_ingress" {

  depends_on = [helm_release.aws_load_balancer_controller]

  name       = "nginx-ingress"
  # Helm release name shown in cluster metadata

  namespace  = "ingress-nginx"
  # Deployed into its own namespace to isolate ingress controller resources

  repository = "https://kubernetes.github.io/ingress-nginx"
  # Official ingress-nginx Helm chart repository

  chart      = "ingress-nginx"
  # Chart name for deploying the ingress controller

  create_namespace = true
  # Automatically creates the 'ingress-nginx' namespace if it doesn't exist

  values = [file("${path.module}/yaml/nginx-values.yaml")]
  # Load custom Helm chart values from external YAML file for better readability
}

