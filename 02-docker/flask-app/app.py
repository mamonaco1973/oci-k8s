"""Candidates API — Flask service backed by OCI NoSQL Database.

Port of the AWS version, which used boto3 against DynamoDB. Two things changed
and nothing else did: the storage client, and how it authenticates.

Authentication:
    OKE workload identity. The signer reads a projected service account token
    from the pod filesystem and exchanges it for a workload principal, which is
    the OCI equivalent of IRSA on EKS. There is no key, no config file and no
    environment credential anywhere in the image.

    It only works if all of the following line up: the cluster is an
    ENHANCED_CLUSTER, the pod runs as the service account named in the IAM
    policy, and that policy names the same namespace and cluster OCID. A
    mismatch in any one of them surfaces as a 404 from NoSQL rather than a
    permission error, because the caller resolves to no groups at all.

Storage:
    A NoSQL table with a single shard column, CandidateName, matching the
    DynamoDB table's partition key. Queries are SQL rather than key conditions.
"""

import json
import os

from flask import Flask, Response, request

from oci.auth.signers import get_oke_workload_identity_resource_principal_signer
from oci.nosql import NosqlClient
from oci.nosql.models import QueryDetails, UpdateRowDetails

# Reported by /gtg?details=true so a caller can tell which pod answered. The
# AWS version shelled out to `hostname -I`; inside a pod the IP is the useful
# identifier and it is already in the environment on most images, but the shell
# call is kept because it works regardless of the base image.
instance_id = os.popen("hostname -I").read().strip()

table_name = os.environ.get("NOSQL_TABLE_NAME", "Candidates")
compartment_id = os.environ["OCI_COMPARTMENT_ID"]

# The signer refreshes its own token, so it is built once at import time and
# reused for the life of the process.
_signer = get_oke_workload_identity_resource_principal_signer()

# NosqlClient wants a config dict even when a signer supplies the credentials;
# an empty one is the documented way to say "everything comes from the signer".
nosql = NosqlClient(config={}, signer=_signer)

candidates_app = Flask(__name__)


@candidates_app.route("/", methods=["GET"])
def default():
    """Return 200 for the ingress controller's default backend check."""
    return Response(status=200)


@candidates_app.route("/gtg", methods=["GET"])
def gtg():
    """Report readiness, optionally with the answering pod's address.

    Returns:
        An empty 200, or a JSON body with the pod address when the request
        carries a "details" query parameter.
    """
    if "details" in request.args:
        return Response(
            json.dumps({"connected": "true", "hostname": instance_id}),
            status=200,
            mimetype="application/json",
        )
    return Response(status=200)


@candidates_app.route("/candidate/<name>", methods=["GET"])
def get_candidate(name):
    """Look up one candidate by name.

    Args:
        name: Value of the CandidateName shard column.

    Returns:
        A JSON array of matching rows, or 404 when the name is not present.
    """
    try:
        # Bound variable, not string interpolation — the value arrives
        # straight off the URL path and reaches the query engine as data.
        details = QueryDetails(
            compartment_id=compartment_id,
            statement=(
                f"DECLARE $name STRING; "
                f"SELECT * FROM {table_name} WHERE CandidateName = $name"
            ),
            variables={"$name": name},
        )
        rows = nosql.query(query_details=details).data.items

        if not rows:
            return "Not Found", 404

        return Response(
            json.dumps(rows),
            status=200,
            mimetype="application/json",
        )
    except Exception:
        return "Not Found", 404


@candidates_app.route("/candidate/<name>", methods=["POST"])
def post_candidate(name):
    """Insert or replace a candidate row.

    Args:
        name: Value of the CandidateName shard column.

    Returns:
        JSON echoing the stored name, or 500 if the write failed.
    """
    try:
        nosql.update_row(
            table_name_or_id=table_name,
            update_row_details=UpdateRowDetails(
                compartment_id=compartment_id,
                value={"CandidateName": name},
            ),
        )
    except Exception:
        return "Unable to update", 500

    return Response(
        json.dumps({"CandidateName": name}),
        status=200,
        mimetype="application/json",
    )


@candidates_app.route("/candidates", methods=["GET"])
def get_candidates():
    """List every candidate.

    Returns:
        A JSON array of all rows, or 404 when the table is empty. The empty
        case returning 404 rather than an empty array is carried over from the
        AWS version so the test script behaves identically.
    """
    try:
        details = QueryDetails(
            compartment_id=compartment_id,
            statement=f"SELECT * FROM {table_name}",
        )
        rows = nosql.query(query_details=details).data.items

        if not rows:
            return "Not Found", 404

        return Response(
            json.dumps(rows),
            status=200,
            mimetype="application/json",
        )
    except Exception:
        return "Not Found", 404
