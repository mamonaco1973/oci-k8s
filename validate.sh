#!/bin/bash

export AWS_DEFAULT_REGION=us-east-2 

# ========================================
# EKS Solution Test Script
# - Verifies if the EKS cluster exists
# - Waits for Ingress ALB hostname
# - Waits for /gtg endpoint to return 200
# - Executes application test against service
# ========================================

# ----------------------------------------
# Step 1: Check if EKS Cluster Exists
# Uses AWS CLI to describe the cluster
# If it fails, cluster is missing — abort
# ----------------------------------------
if aws eks describe-cluster --name flask-eks-cluster > /dev/null 2>&1; then
  echo "NOTE: Testing the EKS Solution."
else
  echo "ERROR: EKS Cluster does not exist."
  exit 1 
fi

# ----------------------------------------
# Step 2: Define Function to Get ALB Hostname
# Extracts DNS hostname from Kubernetes Ingress status
# Assumes ingress object is named 'flask-app-ingress'
# Returns empty if not yet assigned
# ----------------------------------------
get_alb_name() {
  kubectl get ingress flask-app-ingress -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null
}

# ----------------------------------------
# Step 3: Wait Until Ingress ALB Is Ready
# Polls Kubernetes Ingress object every 30 seconds
# Continues looping until ALB hostname is available
# ----------------------------------------
while true; do
  ALB_NAME=$(get_alb_name)

  if [ -n "$ALB_NAME" ]; then
    # Hostname found — break out of loop
    break
  fi

  echo "WARNING: Ingress not ready yet. Waiting 30 seconds..."
  sleep 30
done

# ----------------------------------------
# Step 4: Wait for Application Readiness
# Loops until HTTP 200 is returned from ALB on /gtg
# Confirms app is healthy and responding
# ----------------------------------------
while true; do
  HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "http://$ALB_NAME/flask-app/api/gtg")
  
  if [ "$HTTP_STATUS" -eq 200 ]; then
    # App responded successfully — break out of loop
    break
  fi

  echo "WARNING: Waiting... ALB not ready yet. Retrying in 30 seconds..."
  sleep 30
done

# ----------------------------------------
# Step 5: Navigate to Docker Directory for Testing
# Contains test script for verifying app functionality
# ----------------------------------------
cd "02-docker" || { echo "ERROR: Failed to change directory to 02-docker"; exit 1; }

# ----------------------------------------
# Step 6: Define Base Service URL
# Used as input to the test script
# Includes path prefix used in Ingress routing
# ----------------------------------------
SERVICE_URL="http://$ALB_NAME/flask-app/api"
echo "NOTE: URL for EKS Solution is $SERVICE_URL/gtg?details=true"

# ----------------------------------------
# Step 7: Run Functional Test
# Calls test_candidates.py with the service URL
# Fails and exits if test script returns non-zero
# ----------------------------------------
./test_candidates.py "$SERVICE_URL" || { echo "ERROR: Application test failed. Exiting."; exit 1; }

cd ..  # Return to root after testing
