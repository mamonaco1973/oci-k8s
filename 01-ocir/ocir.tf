# ==============================================================================
# FILE: ocir.tf — Container repositories
# ------------------------------------------------------------------------------
# Two repositories, matching the AWS build: one for the Flask API, one holding
# all three games as separate tags.
#
# OCIR differs from ECR in one way that matters here: repositories live in the
# TENANCY OBJECT STORAGE NAMESPACE, not under an account ID. The image path is
#
#   <region-key>.ocir.io/<namespace>/<repo>:<tag>
#
# so apply.sh has to look the namespace up before it can tag anything. The AWS
# script derived the equivalent from `aws sts get-caller-identity`.
# ==============================================================================

resource "oci_artifacts_container_repository" "flask_app" {
  compartment_id = var.compartment_ocid
  display_name   = "flask-app"

  # Private. The cluster pulls with an image pull secret built from the same
  # auth token apply.sh uses to push — see the secret in 03-oke/oke.tf.
  is_public = false

  # Tags are overwritten on every build, matching ECR's MUTABLE setting.
  is_immutable = false
}

resource "oci_artifacts_container_repository" "games" {
  compartment_id = var.compartment_ocid
  display_name   = "games"
  is_public      = false
  is_immutable   = false
}
