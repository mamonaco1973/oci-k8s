# ==============================================================================
# FILE: nosql.tf — Candidates table
# ------------------------------------------------------------------------------
# Direct replacement for the DynamoDB table. The AWS original used a single
# partition key, CandidateName, and no sort key; OCI NoSQL expresses the same
# thing as a primary key with one shard column and nothing after it.
#
# Read and write units are the OCI analogue of DynamoDB's PAY_PER_REQUEST —
# there is no on-demand mode, so the limits are declared rather than inferred.
# ==============================================================================

resource "oci_nosql_table" "candidates" {
  compartment_id = var.compartment_ocid
  name           = "Candidates"

  ddl_statement = join(" ", [
    "CREATE TABLE IF NOT EXISTS Candidates (",
    "  CandidateName STRING,",
    "  PRIMARY KEY(SHARD(CandidateName))",
    ")"
  ])

  # NOT a free-tier table. is_auto_reclaimable=true requests the always-free
  # tier, which is not offered in every region — Ashburn rejects it outright
  # with "Free tables are not available at this region", and the message does
  # not mention the flag that caused it.
  is_auto_reclaimable = false

  table_limits {
    max_read_units     = 50
    max_write_units    = 50
    max_storage_in_gbs = 1
  }
}
