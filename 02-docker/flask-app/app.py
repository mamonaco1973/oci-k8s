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
    policy, and that policy names the same namespace and cluster OCID.

    THE SIGNER DOES NOT SUPPLY A REGION. A resource principal signer carries
    one, so `NosqlClient(config={}, signer=...)` works on OCI Functions. The
    workload identity signer does not, and the client fails to construct with
    "Must supply either a region or an endpoint" — an error that says nothing
    about workload identity at all. Hence OCI_REGION below.

Storage:
    A NoSQL table with a single shard column, CandidateName, matching the
    DynamoDB table's partition key. Queries are SQL rather than key conditions.
"""

import json
import logging
import os

from flask import Flask, Response, request

from oci.auth.signers import get_oke_workload_identity_resource_principal_signer
from oci.nosql import NosqlClient
from oci.nosql.models import QueryDetails, UpdateRowDetails

logging.basicConfig(level=logging.INFO)
log = logging.getLogger(__name__)

# Reported by /gtg?details=true so a caller can tell which pod answered.
instance_id = os.popen("hostname -I").read().strip()

table_name = os.environ.get("NOSQL_TABLE_NAME", "Candidates")
compartment_id = os.environ["OCI_COMPARTMENT_ID"]
region = os.environ["OCI_REGION"]

# Built on first use, not at import. AN AUTH PROBLEM MUST NOT BE A CRASH LOOP:
# constructing the client at import meant any failure killed gunicorn before it
# bound a port, so the pod never became ready, the probes never ran, and the
# only visible symptom was a 503 from the ingress with the real error buried in
# container logs. Deferring it keeps /gtg answering and turns a storage failure
# into a 500 on the endpoint that actually needs storage.
_nosql = None


def get_nosql():
    """Return the NoSQL client, constructing it on first use.

    Returns:
        A configured oci.nosql.NosqlClient.
    """
    global _nosql
    if _nosql is None:
        signer = get_oke_workload_identity_resource_principal_signer()
        _nosql = NosqlClient(config={"region": region}, signer=signer)
    return _nosql


candidates_app = Flask(__name__)


@candidates_app.route("/", methods=["GET"])
def default():
    """Return 200 for the ingress controller's default backend check."""
    return Response(status=200)


@candidates_app.route("/gtg", methods=["GET"])
def gtg():
    """Report readiness, optionally with the answering pod's address.

    Deliberately does not touch NoSQL. This is the liveness and readiness
    probe, and tying it to a downstream dependency turns a storage outage into
    a rolling restart of every pod.

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
        A JSON array of matching rows, 404 when the name is not present, or
        500 when the lookup itself failed.
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
        rows = get_nosql().query(query_details=details).data.items
    except Exception:
        # An empty result is a 404; a failed query is not. Collapsing the two
        # is what makes a workload identity misconfiguration look like missing
        # data — the exact confusion this project's README warns about.
        log.exception("Query failed for candidate %s", name)
        return "Query failed", 500

    if not rows:
        return "Not Found", 404

    return Response(
        json.dumps(rows),
        status=200,
        mimetype="application/json",
    )


@candidates_app.route("/candidate/<name>", methods=["POST"])
def post_candidate(name):
    """Insert or replace a candidate row.

    Args:
        name: Value of the CandidateName shard column.

    Returns:
        JSON echoing the stored name, or 500 if the write failed.
    """
    try:
        get_nosql().update_row(
            table_name_or_id=table_name,
            update_row_details=UpdateRowDetails(
                compartment_id=compartment_id,
                value={"CandidateName": name},
            ),
        )
    except Exception:
        log.exception("Write failed for candidate %s", name)
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
        A JSON array of all rows, 404 when the table is empty, or 500 when the
        scan failed. The empty case returning 404 rather than an empty array is
        carried over from the AWS version so the test script behaves the same.
    """
    try:
        details = QueryDetails(
            compartment_id=compartment_id,
            statement=f"SELECT * FROM {table_name}",
        )
        rows = get_nosql().query(query_details=details).data.items
    except Exception:
        log.exception("Scan failed")
        return "Query failed", 500

    if not rows:
        return "Not Found", 404

    return Response(
        json.dumps(rows),
        status=200,
        mimetype="application/json",
    )
