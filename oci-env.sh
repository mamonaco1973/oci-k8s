#!/bin/bash
# ==============================================================================
# oci-env.sh — Shared OCI environment derivation
# ------------------------------------------------------------------------------
# Sourced by apply.sh and destroy.sh. Not executable on its own.
#
# EXISTS BECAUSE DESTROY NEEDS EXACTLY WHAT APPLY NEEDED. Terraform requires
# every declared variable to have a value on destroy as well as on apply, so a
# teardown script that does not export the same TF_VAR_* set fails on "No value
# for required variable" before it deletes anything. Keeping the derivation in
# one place is the only way to guarantee the two stay in step.
#
# Sets, and exports where Terraform needs it:
#   TENANCY_OCID  USER_OCID  REGION  HOME_REGION  COMPARTMENT_ID
#   NAMESPACE  OCIR_USERNAME  OCIR_HOST  IMAGE_VERSION
#
# Deliberately does NOT create an OCIR auth token — that belongs to apply.sh,
# and a teardown should never mint credentials.
# ==============================================================================

if [ ! -f ~/.oci/config ]; then
  echo "ERROR: ~/.oci/config not found. Run 'oci setup config' first."
  return 1 2>/dev/null || exit 1
fi

_oci_cfg() {
  awk -F'=' -v k="$1" \
    '$0 ~ "^"k"[[:space:]]*=" {gsub(/[[:space:]]/, "", $2); print $2; exit}' \
    ~/.oci/config
}

TENANCY_OCID=$(_oci_cfg tenancy)
USER_OCID=$(_oci_cfg user)
CONFIG_REGION=$(_oci_cfg region)

# Region follows the OCI CLI unless OCI_REGION overrides it. Nothing in this
# project is region-specific — unlike the Gen AI projects, which have to run
# where the models are served.
REGION="${OCI_REGION:-${CONFIG_REGION}}"

if [ -z "${REGION}" ]; then
  echo "ERROR: No region in ~/.oci/config and OCI_REGION is not set."
  return 1 2>/dev/null || exit 1
fi

COMPARTMENT_ID="${OCI_COMPARTMENT_ID:-$TENANCY_OCID}"

# Dynamic groups and policies are rejected outside the tenancy home region with
# a 403 that never mentions regions, so it is resolved rather than assumed.
HOME_REGION=$(oci iam region-subscription list \
  --query "data[?\"is-home-region\"].\"region-name\" | [0]" --raw-output 2>/dev/null)

if [ -z "${HOME_REGION}" ] || [ "${HOME_REGION}" = "null" ]; then
  echo "ERROR: Could not determine the tenancy home region."
  return 1 2>/dev/null || exit 1
fi

# The OCIR path component. Not the tenancy OCID — a separate short string.
NAMESPACE=$(oci os ns get --query 'data' --raw-output 2>/dev/null)

# OCIR login is namespace/username, not an OCID. Federated users come back as
# "oracleidentitycloudservice/email@domain", which is what OCIR wants.
USER_NAME=$(oci iam user get --user-id "${USER_OCID}" \
  --query 'data.name' --raw-output 2>/dev/null)
OCIR_USERNAME="${NAMESPACE}/${USER_NAME}"
OCIR_HOST="${REGION}.ocir.io"

IMAGE_VERSION="${IMAGE_VERSION:-rc1}"

# Every phase declares these four.
export TF_VAR_region="${REGION}"
export TF_VAR_home_region="${HOME_REGION}"
export TF_VAR_tenancy_ocid="${TENANCY_OCID}"
export TF_VAR_compartment_ocid="${COMPARTMENT_ID}"
