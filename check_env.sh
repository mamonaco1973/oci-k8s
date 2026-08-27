#!/bin/bash
# ==============================================================================
# check_env.sh — Environment validation
# ------------------------------------------------------------------------------
# Pre-flight for apply.sh. Fails before anything is built rather than twenty
# minutes into a cluster create.
#
# Checks, in order:
#   1. Required CLI tools are in PATH.
#   2. The OCI CLI can authenticate.
#   3. The tenancy home region resolves — tenancy-level IAM needs it.
#   4. The object storage namespace resolves — OCIR image paths need it.
#
# The OCI CLI is checked harder than the AWS build checked its own, because
# Terraform itself shells out to it: the kubernetes and helm providers get
# their bearer token from `oci ce cluster generate-token`, so a missing or
# broken CLI surfaces as a provider authentication failure mid-apply.
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# Required commands
# ------------------------------------------------------------------------------
echo "NOTE: Validating required commands in PATH."

commands=("oci" "terraform" "docker" "kubectl" "jq")

for cmd in "${commands[@]}"; do
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "ERROR: Required command not found: ${cmd}"
    exit 1
  fi
  echo "NOTE: Found required command: ${cmd}"
done

echo "NOTE: All required commands are available."

# ------------------------------------------------------------------------------
# OCI authentication
# ------------------------------------------------------------------------------
if [ ! -f ~/.oci/config ]; then
  echo "ERROR: ~/.oci/config not found. Run 'oci setup config' first."
  exit 1
fi

TENANCY_OCID=$(awk -F'=' '/^tenancy[[:space:]]*=/{gsub(/[[:space:]]/, "", $2); print $2; exit}' ~/.oci/config)
if [ -z "${TENANCY_OCID}" ]; then
  echo "ERROR: Could not read the tenancy OCID from ~/.oci/config."
  exit 1
fi

echo "NOTE: Checking OCI CLI connection."
if ! oci os ns get >/dev/null 2>&1; then
  echo "ERROR: Failed to connect to OCI. Check your ~/.oci/config."
  exit 1
fi
echo "NOTE: OCI CLI authentication successful."

# ------------------------------------------------------------------------------
# Home region
# ------------------------------------------------------------------------------
# Dynamic groups and policies are rejected outside the tenancy home region with
# a 403 whose message never mentions regions, so it is resolved up front and
# passed to Terraform rather than assumed.
# ------------------------------------------------------------------------------
HOME_REGION=$(oci iam region-subscription list \
  --query "data[?\"is-home-region\"].\"region-name\" | [0]" \
  --raw-output 2>/dev/null || true)

if [ -z "${HOME_REGION}" ] || [ "${HOME_REGION}" = "null" ]; then
  echo "ERROR: Could not determine the tenancy home region."
  exit 1
fi
echo "NOTE: Tenancy home region is ${HOME_REGION}."

# ------------------------------------------------------------------------------
# Object storage namespace
# ------------------------------------------------------------------------------
# This is the OCIR path component. The AWS build used the account ID from
# `aws sts get-caller-identity`; the OCI equivalent is not the tenancy OCID but
# a separate short namespace string.
# ------------------------------------------------------------------------------
NAMESPACE=$(oci os ns get --query 'data' --raw-output)
if [ -z "${NAMESPACE}" ]; then
  echo "ERROR: Could not resolve the object storage namespace."
  exit 1
fi
echo "NOTE: Object storage namespace is ${NAMESPACE}."

echo "NOTE: Environment validation passed."
