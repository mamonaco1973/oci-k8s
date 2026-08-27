#!/bin/bash
# ==============================================================================
# destroy.sh — Full teardown
# ------------------------------------------------------------------------------
# IDEMPOTENT AND SAFE ON A PARTIAL BUILD. apply.sh can fail at any of its four
# phases, so this script assumes nothing about what exists. Every step checks
# for its target first and skips cleanly when it is absent, and running the
# script twice is harmless.
#
# ORDER STILL MATTERS, and for a different reason than on AWS. The AWS script
# deleted orphaned "k8s*" security groups after the fact, because the ALB
# controller created them outside Terraform. Nothing here creates security
# groups out of band, so that step is gone. What replaces it is a real ordering
# constraint: the OCI load balancer is created by the in-cluster cloud
# controller manager, not by Terraform, so Terraform does not know it exists.
# Destroying the cluster first strands the load balancer, which then blocks the
# subnet -- and therefore the VCN -- from being deleted, with an error that
# names the subnet rather than the balancer. Removing the ingress release while
# the controller is still running lets it delete its own load balancer.
# ==============================================================================

# NOT strict mode. -e is deliberately omitted: teardown has to keep going past
# resources that are already gone, and a partial destroy that stops at the
# first missing object leaves more behind than it removes. Every step that
# genuinely must succeed checks its own exit status.
set -uo pipefail

# ------------------------------------------------------------------------------
# Shared derivation — exports TF_VAR_region, home_region, tenancy_ocid and
# compartment_ocid. Terraform requires every declared variable to have a value
# on DESTROY exactly as on apply, so skipping this fails with "No value for
# required variable" before anything is deleted.
# ------------------------------------------------------------------------------
# shellcheck source=oci-env.sh
source ./oci-env.sh

# ==============================================================================
# SECTION: Guards
# ------------------------------------------------------------------------------
# has_state is the whole basis of the idempotency. A phase that was never
# applied, or has already been destroyed, is skipped rather than handed to
# terraform.
#
# It matters more here than it would on AWS. The kubernetes and helm providers
# in 03-oke are configured from attributes of the cluster that phase creates,
# so against an empty state there is no cluster to configure them from and
# terraform stalls instead of reporting that there is nothing to do. That is
# the hang this guard exists to prevent.
# ==============================================================================

has_state() {
  local dir="$1"
  [ -s "${dir}/terraform.tfstate" ] || return 1
  grep -q '"type"' "${dir}/terraform.tfstate" 2>/dev/null
}

# True only when kubectl can actually reach a cluster. The short timeout keeps
# a stale kubeconfig pointing at a deleted cluster from blocking for minutes.
cluster_reachable() {
  command -v kubectl >/dev/null 2>&1 || return 1
  kubectl cluster-info --request-timeout=10s >/dev/null 2>&1
}

# ==============================================================================
# SECTION: Step 1 — Remove the workloads
# ------------------------------------------------------------------------------
# Skipped entirely when no cluster answers. Without the guard, kubectl blocks
# on an unreachable API server for its full default timeout on every call.
# ==============================================================================

if cluster_reachable; then
  echo "NOTE: Removing Kubernetes workloads."
  for manifest in stress.yaml games.yaml flask-app.yaml; do
    if [ -f "${manifest}" ]; then
      kubectl delete -f "${manifest}" --ignore-not-found \
        --request-timeout=60s >/dev/null 2>&1
    fi
  done
else
  echo "NOTE: No reachable cluster - skipping workload cleanup."
fi

# ==============================================================================
# SECTION: Step 2 — Destroy the cluster phase
# ==============================================================================

# ------------------------------------------------------------------------------
# 03-oke declares six variables the shared file does not cover. Destroy needs
# values for all of them, but not CORRECT ones -- Terraform only has to parse
# the configuration, and every resource it deletes is addressed by the OCID
# already recorded in state. The subnet OCIDs are read back from phase 1, which
# is still intact at this point; the OCIR token falls back to empty when the
# cache is gone, because no image is pulled during a teardown.
# ------------------------------------------------------------------------------
if has_state 01-ocir; then
  export TF_VAR_api_subnet_ocid=$(terraform -chdir=01-ocir output -raw api_subnet_ocid 2>/dev/null)
  export TF_VAR_lb_subnet_ocid=$(terraform -chdir=01-ocir output -raw lb_subnet_ocid 2>/dev/null)
  export TF_VAR_node_subnet_ocid=$(terraform -chdir=01-ocir output -raw node_subnet_ocid 2>/dev/null)
fi

export TF_VAR_api_subnet_ocid="${TF_VAR_api_subnet_ocid:-unused}"
export TF_VAR_lb_subnet_ocid="${TF_VAR_lb_subnet_ocid:-unused}"
export TF_VAR_node_subnet_ocid="${TF_VAR_node_subnet_ocid:-unused}"
export TF_VAR_ocir_namespace="${NAMESPACE}"
export TF_VAR_ocir_username="${OCIR_USERNAME}"
export TF_VAR_ocir_token="$(cat "${HOME}/.oci/ocir_token" 2>/dev/null)"

if has_state 03-oke; then
  cd 03-oke || { echo "ERROR: Cannot enter 03-oke."; exit 1; }

  if [ ! -d ".terraform" ]; then
    terraform init -input=false >/dev/null || {
      echo "ERROR: terraform init failed in 03-oke."
      exit 1
    }
  fi

  # Release the load balancer first, but only when the ingress release is
  # genuinely in state. Targeting a resource that was never created forces
  # terraform to resolve providers it cannot configure.
  if terraform state list 2>/dev/null | grep -q '^helm_release.nginx_ingress$'; then
    echo "NOTE: Removing the ingress controller so its load balancer is released."
    terraform destroy -target=helm_release.nginx_ingress \
      -auto-approve -input=false >/dev/null 2>&1

    echo "NOTE: Waiting for the load balancer to be deleted."
    for _ in $(seq 1 30); do
      REMAINING=$(oci lb load-balancer list \
        --compartment-id "${COMPARTMENT_ID}" \
        --region "${REGION}" \
        --query 'length(data)' --raw-output 2>/dev/null)

      # An empty or failed response means there is nothing left to wait for.
      [ -z "${REMAINING}" ] && REMAINING=0
      [ "${REMAINING}" = "0" ] && break
      sleep 10
    done
  else
    echo "NOTE: No ingress release in state - skipping load balancer wait."
  fi

  echo "NOTE: Destroying the OKE cluster."
  terraform destroy -auto-approve -input=false || {
    echo "ERROR: Terraform destroy failed for 03-oke."
    exit 1
  }

  rm -rf terraform.tfstate* .terraform*
  cd ..
else
  echo "NOTE: 03-oke has no state - nothing to destroy."
  rm -rf 03-oke/.terraform*
fi

# ==============================================================================
# SECTION: Step 3 — Destroy the network and registry phase
# ------------------------------------------------------------------------------
# OCIR repositories delete with their images, so there is no equivalent of the
# AWS build's separate `ecr delete-repository --force` pass.
# ==============================================================================

if has_state 01-ocir; then
  cd 01-ocir || { echo "ERROR: Cannot enter 01-ocir."; exit 1; }

  if [ ! -d ".terraform" ]; then
    terraform init -input=false >/dev/null || {
      echo "ERROR: terraform init failed in 01-ocir."
      exit 1
    }
  fi

  echo "NOTE: Destroying the VCN and OCIR repositories."
  terraform destroy -auto-approve -input=false || {
    echo "ERROR: Terraform destroy failed for 01-ocir."
    exit 1
  }

  rm -rf terraform.tfstate* .terraform*
  cd ..
else
  echo "NOTE: 01-ocir has no state - nothing to destroy."
  rm -rf 01-ocir/.terraform*
fi

# ==============================================================================
# SECTION: Step 4 — Local cleanup
# ==============================================================================
# The rendered manifests only exist after a successful phase 3.

rm -f flask-app.yaml games.yaml

echo "NOTE: Cleanup completed successfully."
