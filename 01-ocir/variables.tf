# ==============================================================================
# FILE: variables.tf — Inputs for the OCIR and network phase
# ------------------------------------------------------------------------------
# All four are exported by apply.sh as TF_VAR_* after being derived from
# ~/.oci/config, so nothing here needs a terraform.tfvars file.
# ==============================================================================

variable "region" {
  description = "Region the cluster and registry live in"
  type        = string
  default     = "us-chicago-1"
}

variable "home_region" {
  description = "Tenancy home region — the only region that accepts IAM writes"
  type        = string
}

variable "tenancy_ocid" {
  description = "Tenancy OCID — dynamic groups and policies are created here"
  type        = string
}

variable "compartment_ocid" {
  description = "Compartment holding the VCN, OCIR repositories and cluster"
  type        = string
}
