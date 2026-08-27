#!/bin/bash

export AWS_DEFAULT_REGION=us-east-2 

# ========================================
# Full Cleanup Script
# Tears down EKS infrastructure, Kubernetes
# deployments, ECR repositories, and 
# supporting Terraform state and security groups.
# ========================================

# ----------------------------------------
# Step 1: Delete Kubernetes Deployments
# Suppress output for stress.yaml and games.yaml
# flask-app.yaml may not exist; log a warning if delete fails
# ----------------------------------------
kubectl delete -f stress.yaml > /dev/null 2> /dev/null
kubectl delete -f games.yaml 
kubectl delete -f flask-app.yaml || {
    echo "WARNING: Failed to delete Kubernetes deployment. It may not exist."
}

# ----------------------------------------
# Step 2: Tear Down EKS Terraform Infrastructure
# ----------------------------------------
cd "03-eks" || { echo "ERROR: Failed to change directory to 03-eks. Exiting."; exit 1; }
echo "NOTE: Destroying EKS cluster."

# Initialize Terraform if not already initialized
if [ ! -d ".terraform" ]; then
    terraform init
fi

# Perform Terraform destroy to tear down the EKS cluster
echo "NOTE: Deleting nginx_ingress."
terraform destroy -target=helm_release.nginx_ingress  -auto-approve > /dev/null 2> /dev/null
terraform destroy -auto-approve || { echo "ERROR: Terraform destroy failed. Exiting."; exit 1; }

# Clean up local Terraform state and module cache
rm -rf terraform* .terraform*

cd ..  # Return to root directory

# ----------------------------------------
# Step 3: Delete Orphaned Security Groups Named "k8s*"
# AWS sometimes leaves dangling security groups after EKS deletion
# ----------------------------------------

# Query AWS for security group IDs where the group name starts with "k8s"
group_ids=$(aws ec2 describe-security-groups \
  --query "SecurityGroups[?starts_with(GroupName, 'k8s')].GroupId" \
  --output text)

# If no matching groups found, skip deletion logic
if [ -z "$group_ids" ]; then
  echo "NOTE: No security groups starting with 'k8s' found."
fi

# Loop through each security group ID and attempt deletion
for group_id in $group_ids; do
  echo "NOTE: Deleting security group: $group_id"
  aws ec2 delete-security-group --group-id "$group_id"

  # Check if deletion was successful and log accordingly
  if [ $? -eq 0 ]; then
    echo "NOTE: Successfully deleted $group_id"
  else
    echo "WARNING: Failed to delete $group_id — possibly still in use by another resource"
  fi
done

# ----------------------------------------
# Step 4: Delete ECR Repositories and All Tagged Images
# This removes container image repositories completely
# ----------------------------------------
echo "NOTE: Deleting ECR repository contents."

# Delete Flask app ECR repository with force to also delete all images
ECR_REPOSITORY_NAME="flask-app"
aws ecr delete-repository --repository-name "$ECR_REPOSITORY_NAME" --force || {
    echo "WARNING: Failed to delete ECR repository. It may not exist."
}

# Delete games repository as well (tetris, breakout, frogger, etc.)
aws ecr delete-repository --repository-name "games" --force || {
    echo "WARNING: Failed to delete ECR repository. It may not exist."
}

# ----------------------------------------
# Step 5: Tear Down ECR Terraform Infrastructure
# ----------------------------------------
cd "01-ecr" || { echo "ERROR: Failed to change directory to 01-ecr. Exiting."; exit 1; }

# Destroy ECR Terraform resources (repositories, policies)
terraform destroy -auto-approve || { echo "ERROR: Terraform destroy failed. Exiting."; exit 1; }

# Clean up local Terraform state and modules
rm -rf terraform* .terraform*
cd ..

# ----------------------------------------
# Step 6: All Cleanup Done
# ----------------------------------------
echo "NOTE: Cleanup process completed successfully."
