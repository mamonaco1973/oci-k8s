# ==============================================================================
# FILE: variables.tf — Inputs for the cluster phase
# ------------------------------------------------------------------------------
# apply.sh exports every one of these as TF_VAR_*. The subnet OCIDs come from
# `terraform output` on phase 1; the OCIR values come from ~/.oci/config and
# the cached auth token.
# ==============================================================================

variable "region" {
  description = "Region the cluster runs in"
  type        = string
  # Only used if a phase is applied by hand; apply.sh always exports
  # TF_VAR_region from the OCI CLI configuration.
  default = "us-ashburn-1"
}

variable "home_region" {
  description = "Tenancy home region — the only region that accepts IAM writes"
  type        = string
}

variable "tenancy_ocid" {
  description = "Tenancy OCID — the workload identity policy is created here"
  type        = string
}

variable "compartment_ocid" {
  description = "Compartment holding the cluster and the NoSQL table"
  type        = string
}

variable "api_subnet_ocid" {
  description = "Public subnet for the Kubernetes API endpoint"
  type        = string
}

variable "lb_subnet_ocid" {
  description = "Public subnet for service load balancers"
  type        = string
}

variable "node_subnet_ocid" {
  description = "Private subnet for worker nodes"
  type        = string
}

variable "kubernetes_version" {
  description = "OKE Kubernetes version including the leading v; empty selects the newest the region offers"
  type        = string

  # Empty on purpose. A pinned version rots as soon as OKE moves on, and the
  # failure is a 409 about worker node images rather than anything that names
  # the version. See the version resolution in oke.tf.
  default = ""
}

variable "node_shape" {
  description = "Worker node shape — Flex shapes bill per OCPU and per GB"
  type        = string
  default     = "VM.Standard.E5.Flex"
}

variable "node_ocpus" {
  description = "OCPUs per worker node"
  type        = number
  default     = 2
}

variable "node_memory_gbs" {
  description = "Memory per worker node, in GB"
  type        = number
  default     = 16
}

variable "image_version" {
  description = "Container image tag suffix, matching the AWS build"
  type        = string
  default     = "rc1"
}

variable "ocir_namespace" {
  description = "Tenancy object storage namespace — the OCIR path component"
  type        = string
}

variable "ocir_username" {
  description = "OCIR login, in the form <namespace>/<username>"
  type        = string
  sensitive   = true
}

variable "ocir_token" {
  description = "OCIR auth token used to build the image pull secret"
  type        = string
  sensitive   = true
}
