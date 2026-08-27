# ==============================================================================
# FILE: main.tf — Provider configuration for the OCIR and network phase
# ------------------------------------------------------------------------------
# TWO PROVIDERS, ON PURPOSE. OCI accepts CREATE/UPDATE/DELETE for tenancy-level
# IAM -- dynamic groups and policies -- ONLY in the tenancy home region.
# Applying them against a non-home region fails with 403-NotAllowed even with
# full admin rights, and the error text never mentions regions. Everything
# regional (VCN, subnets, gateways, OCIR repos) uses the default provider.
# apply.sh discovers the home region and exports TF_VAR_home_region.
# ==============================================================================

terraform {
  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "~> 6.0"
    }
  }
}

# Regional resources — the region the cluster actually runs in.
provider "oci" {
  region = var.region
}

# Tenancy-level IAM writes must land in the home region.
provider "oci" {
  alias  = "home"
  region = var.home_region
}
