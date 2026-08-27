# Create an Amazon EKS Cluster
# This resource provisions an EKS cluster with a specified IAM role and VPC configuration.

resource "aws_eks_cluster" "flask_eks" {
  name     = "flask-eks-cluster"                # Define the name of the EKS cluster
  role_arn = aws_iam_role.eks_cluster_role.arn  # Attach the IAM role for EKS management

  vpc_config {
    subnet_ids = [data.aws_subnet.k8s-subnet-1.id, 
                  data.aws_subnet.k8s-subnet-2.id]  # Specify the subnets where the EKS cluster will be deployed
  }

  depends_on = [aws_iam_role_policy_attachment.eks_cluster_policy]         # Ensure IAM policies are attached before creating the cluster
}

# Define a Launch Template for EKS Worker Nodes
# This template configures metadata options for security purposes

resource "aws_launch_template" "eks_worker_nodes" {
  name = "eks-worker-nodes"    # Assign a name to the launch template

  metadata_options {
    http_endpoint = "enabled"  # Enable the instance metadata service (IMDS)
    http_tokens   = "optional" # Allow IMDSv2 but do not enforce it 
  }  

  # Define tags for instances launched from this template
  tag_specifications {
    resource_type = "instance"

    tags = {
      Name = "eks-worker-node-flask-api"
    }
  }
}

# Create an EKS Node Group
# This provisions worker nodes in the EKS cluster and assigns the necessary IAM role

resource "aws_eks_node_group" "flask_nodes" {
  cluster_name    = aws_eks_cluster.flask_eks.name                           # Associate the node group with the specified EKS cluster
  node_group_name = "flask-nodes"                                            # Define the name of the node group
  node_role_arn   = aws_iam_role.eks_node_role.arn                           # Attach the IAM role for worker nodes
  subnet_ids      = [data.aws_subnet.k8s-private-subnet-1.id,
                     data.aws_subnet.k8s-private-subnet-2.id]                # Deploy worker nodes in specified subnets

  instance_types  = ["t3.medium"]                                            # Choose the instance type for worker nodes

  # Use the previously defined launch template for worker node configuration
  launch_template {
    id      = aws_launch_template.eks_worker_nodes.id              # Reference the launch template ID
    version = aws_launch_template.eks_worker_nodes.latest_version  # Always use the latest launch template version
  }

  scaling_config {
    desired_size = 1  # Set the desired number of worker nodes (scale accordingly)
    max_size     = 4  # Maximum number of worker nodes allowed (increase for scaling needs)
    min_size     = 1  # Minimum number of worker nodes (ensure redundancy if needed)
  }

  depends_on = [
    aws_iam_role_policy_attachment.eks_worker_node_policy,  # Ensure the node IAM role has required permissions
    aws_iam_role_policy_attachment.eks_cni_policy,          # Attach policy for EKS networking (CNI)
    aws_iam_role_policy_attachment.eks_registry_policy,     # Allow worker nodes to pull images from ECR
    aws_iam_role_policy_attachment.ssm_policy               # Enable access to AWS Systems Manager for logging and monitoring
  ]

  tags = {
    "k8s.io/cluster-autoscaler/enabled"                    = "true"
    "k8s.io/cluster-autoscaler/flask-eks-cluster"          = "owned"
  }

  labels = {
    nodegroup = "flask-nodes"
  }
}

# Define a Launch Template for EKS Game Nodes
# This template configures metadata options for security purposes

resource "aws_launch_template" "eks_game_nodes" {
  name = "eks-game-nodes"    # Assign a name to the launch template

  metadata_options {
    http_endpoint = "enabled"  # Enable the instance metadata service (IMDS)
    http_tokens   = "optional" # Allow IMDSv2 but do not enforce it 
  }  

  # Define tags for instances launched from this template
  tag_specifications {
    resource_type = "instance"

    tags = {
      Name = "eks-game-node"
    }
  }
}

# Create an EKS Node Group
# This provisions worker nodes in the EKS cluster and assigns the necessary IAM role

resource "aws_eks_node_group" "game_nodes" {
  cluster_name    = aws_eks_cluster.flask_eks.name                           # Associate the node group with the specified EKS cluster
  node_group_name = "game-nodes"                                             # Define the name of the node group
  node_role_arn   = aws_iam_role.eks_node_role.arn                           # Attach the IAM role for worker nodes
  subnet_ids      = [data.aws_subnet.k8s-private-subnet-1.id,
                     data.aws_subnet.k8s-private-subnet-2.id]                # Deploy worker nodes in specified subnets

  instance_types  = ["t3.medium"]                                            # Choose the instance type for worker nodes

  # Use the previously defined launch template for worker node configuration
  launch_template {
    id      = aws_launch_template.eks_game_nodes.id              # Reference the launch template ID
    version = aws_launch_template.eks_game_nodes.latest_version  # Always use the latest launch template version
  }

  scaling_config {
    desired_size = 1  # Set the desired number of worker nodes (scale accordingly)
    max_size     = 1  # Maximum number of worker nodes allowed (increase for scaling needs)
    min_size     = 1  # Minimum number of worker nodes (ensure redundancy if needed)
  }

  depends_on = [
    aws_iam_role_policy_attachment.eks_worker_node_policy,  # Ensure the node IAM role has required permissions
    aws_iam_role_policy_attachment.eks_cni_policy,          # Attach policy for EKS networking (CNI)
    aws_iam_role_policy_attachment.eks_registry_policy,     # Allow worker nodes to pull images from ECR
    aws_iam_role_policy_attachment.ssm_policy               # Enable access to AWS Systems Manager for logging and monitoring
  ]

  tags = {
    "k8s.io/cluster-autoscaler/enabled"                    = "true"
    "k8s.io/cluster-autoscaler/flask-eks-cluster"          = "owned"
  }

  labels = {
    nodegroup = "game-nodes"
  }
}
# ==============================================================================
# IAM Role for DynamoDB Access (IRSA for EKS)
# ==============================================================================

module "dynamodb_access_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-assumable-role-with-oidc"
  version = "5.39.0"

  create_role  = true
  role_name    = "dynamodb-access-role"
  provider_url = replace(aws_eks_cluster.flask_eks.identity[0].oidc[0].issuer, "https://", "")
  role_policy_arns = [
    aws_iam_policy.dynamodb_access.arn
  ]
  oidc_fully_qualified_subjects = [
    "system:serviceaccount:default:dynamodb-access-sa"
  ]
}

# Retrieve the TLS Certificate for EKS OIDC Provider
# This ensures secure authentication for OIDC-based IAM roles

data "tls_certificate" "eks_oidc" {
  url = aws_eks_cluster.flask_eks.identity[0].oidc[0].issuer  # Fetch the OIDC provider URL from the EKS cluster
}

# Create an OIDC Identity Provider for EKS
# This allows Kubernetes workloads to assume IAM roles using OpenID Connect

resource "aws_iam_openid_connect_provider" "eks_oidc_provider" {
  url = aws_eks_cluster.flask_eks.identity[0].oidc[0].issuer  # Set the OIDC provider URL for IAM authentication

  client_id_list = [
    "sts.amazonaws.com"  # Allow the AWS Security Token Service (STS) to assume roles on behalf of Kubernetes workloads
  ]

  thumbprint_list = [data.tls_certificate.eks_oidc.certificates[0].sha1_fingerprint]  # Use the retrieved TLS certificate fingerprint for secure communication
}

# =============================================
# Kubernetes Provider Configuration
# =============================================
provider "kubernetes" {
  host                   = aws_eks_cluster.flask_eks.endpoint                                     # Use EKS cluster API endpoint
  cluster_ca_certificate = base64decode(aws_eks_cluster.flask_eks.certificate_authority[0].data)  # Decode CA certificate
  token                  = data.aws_eks_cluster_auth.flask_eks.token                              # Use token authentication for EKS API
}

# =======================================================
# Create a Kubernetes Service Account for DynamoDB Access
# =======================================================
resource "kubernetes_service_account" "dynamodb_access_sa" {
  metadata {
    name      = "dynamodb-access-sa"  # Name of the Kubernetes service account
    namespace = "default"             # Namespace where the service account will be created
    annotations = {
      "eks.amazonaws.com/role-arn" = module.dynamodb_access_irsa.iam_role_arn  # Attach IAM role via IRSA
    }
  }
}

resource "kubernetes_service_account" "cluster_autoscaler" {
  metadata {
    name      = "cluster-autoscaler"
    namespace = "kube-system"
    annotations = {
      "eks.amazonaws.com/role-arn" = aws_iam_role.cluster_autoscaler.arn
    }
  }
}

