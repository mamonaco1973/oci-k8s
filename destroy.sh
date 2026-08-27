#!/bin/bash
# ==============================================================================
# destroy.sh — Full teardown
# ------------------------------------------------------------------------------
# ORDER MATTERS, AND FOR A DIFFERENT REASON THAN ON AWS.
#
# The AWS script deleted orphaned "k8s*" security groups after the fact,
# because the ALB controller created them outside Terraform and EKS left them
# behind. Nothing here creates security groups out of band, so that step is
# gone. What replaces it is a real ordering constraint: the OCI load balancer
# is created by the in-cluster cloud controller manager, not by Terraform, so
# Terraform does not know it exists. Destroying the cluster first strands the
# load balancer, which then blocks the subnet — and therefore the VCN — from
# being deleted, with an error that names the subnet rather than the balancer.
#
# Removing the ingress release first lets the controller delete its own load
# balancer while it is still running to do so.
# ==============================================================================

# NOT strict mode. -e is deliberately omitted: teardown has to keep going
# past resources that are already gone, and a partial destroy that stops at
# the first missing object leaves more behind than it removes. Every step
# that genuinely must succeed checks its own exit status.
set -uo pipefail

REGION="${OCI_REGION:-us-chicago-1}"

# ------------------------------------------------------------------------------
# Step 1 — Remove the workloads
# ------------------------------------------------------------------------------
kubectl delete -f stress.yaml     >/dev/null 2>&1
kubectl delete -f games.yaml      >/dev/null 2>&1
kubectl delete -f flask-app.yaml  >/dev/null 2>&1 || {
  echo "WARNING: Failed to delete the Flask deployment. It may not exist."
}

# ------------------------------------------------------------------------------
# Step 2 — Release the load balancer before the cluster goes away
# ------------------------------------------------------------------------------
cd 03-oke || { echo "ERROR: Failed to change directory to 03-oke."; exit 1; }

if [ ! -d ".terraform" ]; then
  terraform init
fi

echo "NOTE: Removing the ingress controller so its load balancer is released."
terraform destroy -target=helm_release.nginx_ingress -auto-approve >/dev/null 2>&1

# The delete is asynchronous — the Service goes away before the balancer does.
echo "NOTE: Waiting for the load balancer to be deleted."
for _ in $(seq 1 30); do
  REMAINING=$(oci lb load-balancer list \
    --compartment-id "${OCI_COMPARTMENT_ID:-$(awk -F'=' '/^tenancy[[:space:]]*=/{gsub(/[[:space:]]/,"",$2); print $2; exit}' ~/.oci/config)}" \
    --region "${REGION}" \
    --query 'length(data[?"lifecycle-state"==`ACTIVE`])' --raw-output 2>/dev/null || echo 0)
  if [ "${REMAINING}" = "0" ]; then
    break
  fi
  sleep 10
done

# ------------------------------------------------------------------------------
# Step 3 — Destroy the cluster phase
# ------------------------------------------------------------------------------
echo "NOTE: Destroying the OKE cluster."
terraform destroy -auto-approve || {
  echo "ERROR: Terraform destroy failed for 03-oke."
  exit 1
}

rm -rf terraform.tfstate* .terraform*
cd ..

# ------------------------------------------------------------------------------
# Step 4 — Destroy the network and registry phase
# ------------------------------------------------------------------------------
# OCIR repositories delete with their images, so there is no equivalent of the
# AWS build's separate `ecr delete-repository --force` pass.
# ------------------------------------------------------------------------------
cd 01-ocir || { echo "ERROR: Failed to change directory to 01-ocir."; exit 1; }

if [ ! -d ".terraform" ]; then
  terraform init
fi

echo "NOTE: Destroying the VCN and OCIR repositories."
terraform destroy -auto-approve || {
  echo "ERROR: Terraform destroy failed for 01-ocir."
  exit 1
}

rm -rf terraform.tfstate* .terraform*
cd ..

# ------------------------------------------------------------------------------
# Step 5 — Local cleanup
# ------------------------------------------------------------------------------
rm -f flask-app.yaml games.yaml

echo "NOTE: Cleanup completed successfully."
