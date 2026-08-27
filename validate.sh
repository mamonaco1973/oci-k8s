#!/bin/bash
# ==============================================================================
# validate.sh — Post-deploy verification
# ------------------------------------------------------------------------------
# Confirms the cluster exists, waits for the load balancer to be assigned and
# for the application to answer, then runs the functional test.
#
# ONE PORTING TRAP LIVES HERE. The AWS version read the ingress address from
#
#   .status.loadBalancer.ingress[0].hostname
#
# because an ALB is published as a DNS name. An OCI load balancer is published
# as an IP ADDRESS, so that field is empty forever and the original loop would
# wait indefinitely without ever saying why. The field below is .ip.
# ==============================================================================

set -euo pipefail

CONFIG_REGION=$(awk -F'=' '/^region[[:space:]]*=/{gsub(/[[:space:]]/, "", $2); print $2; exit}' ~/.oci/config)
REGION="${OCI_REGION:-${CONFIG_REGION}}"
CLUSTER_NAME="flask-oke-cluster"

# ------------------------------------------------------------------------------
# Step 1 — Confirm the cluster exists and is ACTIVE
# ------------------------------------------------------------------------------
TENANCY_OCID=$(awk -F'=' '/^tenancy[[:space:]]*=/{gsub(/[[:space:]]/, "", $2); print $2; exit}' ~/.oci/config)
COMPARTMENT_ID="${OCI_COMPARTMENT_ID:-$TENANCY_OCID}"

CLUSTER_STATE=$(oci ce cluster list \
  --compartment-id "${COMPARTMENT_ID}" \
  --name "${CLUSTER_NAME}" \
  --region "${REGION}" \
  --query "data[?\"lifecycle-state\"=='ACTIVE'] | [0].\"lifecycle-state\"" \
  --raw-output 2>/dev/null || true)

if [ "${CLUSTER_STATE}" != "ACTIVE" ]; then
  echo "ERROR: OKE cluster ${CLUSTER_NAME} is not ACTIVE."
  exit 1
fi
echo "NOTE: Testing the OKE solution."

# ------------------------------------------------------------------------------
# Step 2 — Wait for the load balancer address
# ------------------------------------------------------------------------------
# An OCI load balancer takes a few minutes to provision after the ingress
# controller's Service is created, so this polls rather than assuming.
# ------------------------------------------------------------------------------
get_lb_ip() {
  kubectl get ingress flask-app-ingress \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null
}

while true; do
  LB_IP=$(get_lb_ip)
  if [ -n "${LB_IP}" ]; then
    break
  fi
  echo "WARNING: Ingress not ready yet. Waiting 30 seconds."
  sleep 30
done

echo "NOTE: Load balancer address is ${LB_IP}"

# ------------------------------------------------------------------------------
# Step 3 — Wait for the application to answer
# ------------------------------------------------------------------------------
while true; do
  HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
    "http://${LB_IP}/flask-app/api/gtg")

  if [ "${HTTP_STATUS}" = "200" ]; then
    break
  fi

  echo "WARNING: Application not ready yet (HTTP ${HTTP_STATUS}). Retrying in 30 seconds."
  sleep 30
done

# ------------------------------------------------------------------------------
# Step 4 — Functional test
# ------------------------------------------------------------------------------
cd 02-docker || { echo "ERROR: Failed to change directory to 02-docker"; exit 1; }

SERVICE_URL="http://${LB_IP}/flask-app/api"

echo ""
echo "NOTE: Flask API   - ${SERVICE_URL}/gtg?details=true"
echo "NOTE: Tetris      - http://${LB_IP}/games/tetris/"
echo "NOTE: Breakout    - http://${LB_IP}/games/breakout/"
echo "NOTE: Frogger     - http://${LB_IP}/games/frogger/"
echo ""

./test_candidates.py "${SERVICE_URL}" || {
  echo "ERROR: Application test failed."
  exit 1
}

cd ..
