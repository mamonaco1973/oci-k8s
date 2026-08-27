#!/bin/bash
# ==============================================================================
# start_flask_app.sh — container entrypoint
# ------------------------------------------------------------------------------
# The AWS version exported TC_DYNAMO_TABLE here. Table name, compartment and
# region now arrive as environment variables from the deployment manifest, so
# there is nothing to set — the app reads them directly and fails loudly at
# import if the compartment is missing.
# ==============================================================================
set -euo pipefail

cd /flask
exec /usr/local/bin/gunicorn -b 0.0.0.0:8000 app:candidates_app
