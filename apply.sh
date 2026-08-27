#!/bin/bash
# ==============================================================================
# apply.sh — Full pipeline deployment
# ------------------------------------------------------------------------------
# Phase 1 (01-ocir):  VCN, subnets, gateways and the OCIR repositories
# Phase 2 (02-docker): Builds four images and pushes them to OCIR
# Phase 3 (03-oke):   OKE cluster, node pools, NoSQL, IAM and the add-ons
# Phase 4:            Renders the manifests and applies them with kubectl
#
# No environment variables are required. Everything is derived from
# ~/.oci/config. An OCIR auth token is created on the first run and cached in
# ~/.oci/ocir_token for reuse.
#
# Optional:
#   OCI_COMPARTMENT_ID  Defaults to the tenancy root when unset
#   OCI_REGION          Defaults to the region in ~/.oci/config
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# Environment validation
# ------------------------------------------------------------------------------
echo "NOTE: Running environment validation."
./check_env.sh

# ------------------------------------------------------------------------------
# Derive OCI identifiers
# ------------------------------------------------------------------------------
TENANCY_OCID=$(awk -F'=' '/^tenancy[[:space:]]*=/{gsub(/[[:space:]]/, "", $2); print $2; exit}' ~/.oci/config)
USER_OCID=$(awk -F'=' '/^user[[:space:]]*=/{gsub(/[[:space:]]/, "", $2); print $2; exit}' ~/.oci/config)

# Region follows the OCI CLI unless OCI_REGION overrides it. Nothing in this
# project is region-specific -- unlike the Gen AI projects, which have to
# run where the models are served.
CONFIG_REGION=$(awk -F'=' '/^region[[:space:]]*=/{gsub(/[[:space:]]/, "", $2); print $2; exit}' ~/.oci/config)
REGION="${OCI_REGION:-${CONFIG_REGION}}"

if [ -z "${REGION}" ]; then
  echo "ERROR: No region in ~/.oci/config and OCI_REGION is not set."
  exit 1
fi
COMPARTMENT_ID="${OCI_COMPARTMENT_ID:-$TENANCY_OCID}"

HOME_REGION=$(oci iam region-subscription list \
  --query "data[?\"is-home-region\"].\"region-name\" | [0]" --raw-output)
NAMESPACE=$(oci os ns get --query 'data' --raw-output)

# OCIR login is namespace/username, not an OCID. Federated users come back as
# "oracleidentitycloudservice/email@domain", which is exactly what OCIR wants.
USER_NAME=$(oci iam user get --user-id "${USER_OCID}" --query 'data.name' --raw-output)
OCIR_USERNAME="${NAMESPACE}/${USER_NAME}"
OCIR_HOST="${REGION}.ocir.io"
IMAGE_VERSION="rc1"

echo "NOTE: Region      - ${REGION}"
echo "NOTE: Home region - ${HOME_REGION}"
echo "NOTE: Namespace   - ${NAMESPACE}"
echo "NOTE: Compartment - ${COMPARTMENT_ID}"

export TF_VAR_region="${REGION}"
export TF_VAR_home_region="${HOME_REGION}"
export TF_VAR_tenancy_ocid="${TENANCY_OCID}"
export TF_VAR_compartment_ocid="${COMPARTMENT_ID}"

# ------------------------------------------------------------------------------
# OCIR auth token — created once, cached in ~/.oci/ocir_token
# ------------------------------------------------------------------------------
# An auth token is readable only at creation time, so it is cached on first
# use. Delete the file to force a new one; OCI allows two per user, so an old
# token may need removing in the Console first.
# ------------------------------------------------------------------------------
TOKEN_FILE="${HOME}/.oci/ocir_token"

if [ -f "${TOKEN_FILE}" ] && [ -s "${TOKEN_FILE}" ]; then
  echo "NOTE: Using cached OCIR token from ${TOKEN_FILE}"
  OCIR_TOKEN=$(cat "${TOKEN_FILE}")
  TOKEN_IS_NEW="false"
else
  echo "NOTE: Creating an OCIR auth token."
  OCIR_TOKEN=$(oci iam auth-token create \
    --user-id "${USER_OCID}" \
    --description "oci-k8s-ocir" \
    --query 'data.token' --raw-output)
  echo "${OCIR_TOKEN}" > "${TOKEN_FILE}"
  chmod 600 "${TOKEN_FILE}"
  TOKEN_IS_NEW="true"
fi

# ------------------------------------------------------------------------------
# Terraform init helper
# ------------------------------------------------------------------------------
init_terraform() {
  if [ ! -d ".terraform" ]; then
    terraform init
  fi
}

# ==============================================================================
# Phase 1 — Network and OCIR repositories
# ==============================================================================
cd 01-ocir
echo "NOTE: Building the VCN and OCIR repositories."
init_terraform
terraform apply -auto-approve

API_SUBNET=$(terraform output -raw api_subnet_ocid)
LB_SUBNET=$(terraform output -raw lb_subnet_ocid)
NODE_SUBNET=$(terraform output -raw node_subnet_ocid)
cd ..

# ==============================================================================
# Phase 2 — Build and push container images
# ==============================================================================
# OCIR repositories are created empty by Terraform but a push still has to
# name the full path. Unlike ECR there is no per-registry login command: the
# auth token is the password for a plain `docker login`.
# ==============================================================================
cd 02-docker
# ------------------------------------------------------------------------------
# OCIR login
# ------------------------------------------------------------------------------
# A NEWLY CREATED AUTH TOKEN IS NOT USABLE IMMEDIATELY. IAM takes one to two
# minutes to propagate it, and until it has, OCIR answers a perfectly correct
# token with "unknown: Unauthorized" -- indistinguishable from a wrong one. A
# single-shot login therefore fails on the first run of a fresh tenancy and
# looks like a credential bug. So poll.
#
# A CACHED token that fails is the opposite problem: it will never start
# working, so say so immediately rather than after five minutes of retries.
# ------------------------------------------------------------------------------
echo "NOTE: Logging in to OCIR at ${OCIR_HOST}."

LOGIN_TIMEOUT=300
LOGIN_INTERVAL=15
elapsed=0

until printf '%s' "${OCIR_TOKEN}" | docker login "${OCIR_HOST}"         --username "${OCIR_USERNAME}" --password-stdin 2>/dev/null; do

  if [ "${TOKEN_IS_NEW}" = "false" ]; then
    echo "ERROR: OCIR rejected the cached token in ${TOKEN_FILE}."
    echo "       It was most likely revoked, or belongs to a different user."
    echo "       Delete it and re-run:  rm ${TOKEN_FILE}"
    echo "       OCI allows two auth tokens per user, so an old one may need"
    echo "       deleting first under Identity > Users > Auth Tokens."
    exit 1
  fi

  if [ "${elapsed}" -ge "${LOGIN_TIMEOUT}" ]; then
    echo "ERROR: OCIR login still failing after ${LOGIN_TIMEOUT}s."
    echo "       Host: ${OCIR_HOST}"
    echo "       User: ${OCIR_USERNAME}"
    exit 1
  fi

  echo "NOTE: OCIR not ready yet (token propagating) - retrying in ${LOGIN_INTERVAL}s (${elapsed}/${LOGIN_TIMEOUT}s)."
  sleep "${LOGIN_INTERVAL}"
  elapsed=$(( elapsed + LOGIN_INTERVAL ))
done

echo "NOTE: OCIR login succeeded."

build_and_push() {
  local dir="$1" repo="$2" tag="$3"
  local image="${OCIR_HOST}/${NAMESPACE}/${repo}:${tag}"

  echo "NOTE: Building ${image}"
  docker build -t "${image}" "${dir}"
  docker push "${image}"
}

build_and_push flask-app flask-app "flask-app-${IMAGE_VERSION}"
build_and_push tetris   games     "tetris-${IMAGE_VERSION}"
build_and_push breakout games     "breakout-${IMAGE_VERSION}"
build_and_push frogger  games     "frogger-${IMAGE_VERSION}"
cd ..

# ==============================================================================
# Phase 3 — OKE cluster
# ==============================================================================
cd 03-oke
echo "NOTE: Building the OKE cluster. This takes roughly 15 minutes."

export TF_VAR_api_subnet_ocid="${API_SUBNET}"
export TF_VAR_lb_subnet_ocid="${LB_SUBNET}"
export TF_VAR_node_subnet_ocid="${NODE_SUBNET}"
export TF_VAR_ocir_namespace="${NAMESPACE}"
export TF_VAR_ocir_username="${OCIR_USERNAME}"
export TF_VAR_ocir_token="${OCIR_TOKEN}"
export TF_VAR_image_version="${IMAGE_VERSION}"

init_terraform
terraform apply -auto-approve

CLUSTER_OCID=$(terraform output -raw cluster_ocid)
NOSQL_TABLE=$(terraform output -raw nosql_table_name)

# ------------------------------------------------------------------------------
# Render the Kubernetes manifests
# ------------------------------------------------------------------------------
# The AWS build substituted a single placeholder, the account ID, with one sed
# expression. OCI image paths need the registry host and the namespace, and the
# Flask pod additionally needs its table, compartment and region, so the same
# idea is just carried across more placeholders.
# ------------------------------------------------------------------------------
render() {
  sed -e "s|\${ocir_host}|${OCIR_HOST}|g" \
      -e "s|\${namespace}|${NAMESPACE}|g" \
      -e "s|\${image_version}|${IMAGE_VERSION}|g" \
      -e "s|\${nosql_table}|${NOSQL_TABLE}|g" \
      -e "s|\${compartment_id}|${COMPARTMENT_ID}|g" \
      -e "s|\${region}|${REGION}|g" \
      "$1" > "$2"
}

render yaml/flask-app.yaml.tmpl ../flask-app.yaml
render yaml/games.yaml.tmpl     ../games.yaml
cd ..

# ==============================================================================
# Phase 4 — Deploy to the cluster
# ==============================================================================
# `oci ce cluster create-kubeconfig` is the counterpart to
# `aws eks update-kubeconfig`, with one difference that matters: it addresses
# the cluster by OCID rather than by name, which is why phase 3 outputs it.
# ==============================================================================
echo "NOTE: Configuring kubectl for the cluster."
oci ce cluster create-kubeconfig \
  --cluster-id "${CLUSTER_OCID}" \
  --region "${REGION}" \
  --token-version 2.0.0 \
  --kube-endpoint PUBLIC_ENDPOINT

echo "NOTE: Deploying the Flask application."
kubectl apply -f flask-app.yaml

echo "NOTE: Deploying the game containers."
kubectl apply -f games.yaml

echo ""
echo "NOTE: Validating the deployment."
./validate.sh

echo "NOTE: Deployment completed successfully."
