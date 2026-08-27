# =============================================
# IAM Policy: Allow Access to DynamoDB
# =============================================
resource "aws_iam_policy" "dynamodb_access" {
  name        = "DynamoDBAccessPolicy"                      # Name of the custom IAM policy
  description = "Policy to allow access to DynamoDB"        # Description of the policy’s purpose

  policy = jsonencode({
    Version = "2012-10-17"                                   # Standard version for AWS IAM policies
    Statement = [
      {
        Action = [                                           # List of DynamoDB actions to allow
          "dynamodb:Query",                                  # Allow querying items by keys and indexes
          "dynamodb:PutItem",                                # Allow inserting new items into the table
          "dynamodb:Scan"                                    # Allow scanning the table (potentially expensive)
        ],
        Effect   = "Allow",                                  # Grant the specified actions
        Resource = "${aws_dynamodb_table.candidate-table.arn}"  # Restrict actions to this specific DynamoDB table
      }
    ]
  })
}

# =============================================
# IAM Role: EKS Cluster Role
# =============================================
resource "aws_iam_role" "eks_cluster_role" {
  name = "eks-cluster-role"                                 # Name of the IAM role for the EKS control plane

  assume_role_policy = jsonencode({
    Version = "2012-10-17",                                  # Policy version
    Statement = [
      {
        Effect = "Allow",                                    # Allow role assumption
        Principal = {
          Service = "eks.amazonaws.com"                      # Allow EKS service to assume this role
        },
        Action = "sts:AssumeRole"                            # Required action for service role assumption
      }
    ]
  })
}

# ======================================================
# Attach Managed AWS Policy to EKS Cluster Role
# ======================================================
resource "aws_iam_role_policy_attachment" "eks_cluster_policy" {
  role       = aws_iam_role.eks_cluster_role.name           # IAM role to attach the policy to
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"  # Grants necessary permissions to manage EKS cluster
}

# =============================================
# IAM Role: EKS Node Group Role
# =============================================
resource "aws_iam_role" "eks_node_role" {
  name = "eks-node-group-role"                              # Name of IAM role for EKS worker nodes (EC2 instances)

  assume_role_policy = jsonencode({
    Version = "2012-10-17",                                  # Policy version
    Statement = [
      {
        Effect = "Allow",                                    # Allow role assumption
        Principal = {
          Service = "ec2.amazonaws.com"                      # Allow EC2 instances to assume this role
        },
        Action = "sts:AssumeRole"                            # Required for EC2 instance role assumption
      }
    ]
  })
}

# ========================================================
# Attach AWS Managed Policies to EKS Node Group Role
# ========================================================

resource "aws_iam_role_policy_attachment" "eks_worker_node_policy" {
  role       = aws_iam_role.eks_node_role.name                      # Attach worker node policy
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"  # Grants general EKS node permissions
}

resource "aws_iam_role_policy_attachment" "eks_cni_policy" {
  role       = aws_iam_role.eks_node_role.name                 # Attach CNI (networking) policy
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"  # Grants permissions to manage ENIs and networking
}

resource "aws_iam_role_policy_attachment" "eks_registry_policy" {
  role       = aws_iam_role.eks_node_role.name                               # Attach ECR read-only access policy
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"  # Enables pulling images from ECR
}

resource "aws_iam_role_policy_attachment" "ssm_policy" {
  role       = aws_iam_role.eks_node_role.name                         # Attach SSM policy for EC2 instances
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"  # Enables remote access via Systems Manager
}

# ===========================================================
# IAM Role for Cluster Autoscaler using IRSA (OIDC-based)
# ===========================================================
resource "aws_iam_role" "cluster_autoscaler" {
  name = "EKSClusterAutoscalerRole"                             # Name of IAM role for the autoscaler

  assume_role_policy = jsonencode({
    Version = "2012-10-17",                                     # Policy version
    Statement = [
      {
        Effect = "Allow",                                       # Allow assumption via OIDC
        Principal = {
          Federated = aws_iam_openid_connect_provider.eks_oidc_provider.arn  # OIDC identity provider ARN for EKS
        },
        Action = "sts:AssumeRoleWithWebIdentity",               # Action required for IRSA
        Condition = {
          StringEquals = {
            # Maps the service account in the kube-system namespace to this role
            "${replace(aws_iam_openid_connect_provider.eks_oidc_provider.url, "https://", "")}:sub" = "system:serviceaccount:kube-system:cluster-autoscaler"
          }
        }
      }
    ]
  })
}

# ======================================================
# IAM Policy for Cluster Autoscaler Permissions
# ======================================================
resource "aws_iam_policy" "cluster_autoscaler" {
  name        = "EKSClusterAutoscalerPolicy"                   # Name of the IAM policy
  description = "Allows Cluster Autoscaler to manage node group ASGs"

  policy = jsonencode({
    Version = "2012-10-17",                                    # Policy version
    Statement = [
      {
        Effect = "Allow",                                      # Grant permissions
        Action = [                                             # Actions required by cluster-autoscaler to scale nodes
          "autoscaling:DescribeAutoScalingGroups",
          "autoscaling:DescribeAutoScalingInstances",
          "autoscaling:DescribeLaunchConfigurations",
          "autoscaling:DescribeTags",
          "autoscaling:SetDesiredCapacity",
          "autoscaling:TerminateInstanceInAutoScalingGroup",
          "ec2:DescribeLaunchTemplateVersions",
          "eks:DescribeNodegroup"
        ],
        Resource = "*"                                         # Apply these actions to all resources
      }
    ]
  })
}

# ======================================================
# Attach Cluster Autoscaler Policy to the IAM Role
# ======================================================
resource "aws_iam_role_policy_attachment" "cluster_autoscaler_attach" {
  role       = aws_iam_role.cluster_autoscaler.name           # IAM role to attach the policy to
  policy_arn = aws_iam_policy.cluster_autoscaler.arn          # Attach the custom cluster-autoscaler policy
}
