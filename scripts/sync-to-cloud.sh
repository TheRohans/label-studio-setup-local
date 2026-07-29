#!/bin/bash
# Pushes the local tasks/ and annotations/ directories up to a cloud bucket,
# in the same gs://<bucket>/tasks/ + /annotations/ layout the Cloud Run
# setup in ../label-studio-setup expects. This does NOT touch the SQLite db
# (ls-internal/) - see README "Continuing in the cloud" for why, and for the
# metadata migration path.
set -euo pipefail

DATA_ROOT="$1"; BUCKET_URL="$2"

case "$BUCKET_URL" in
  gs://*)
    command -v gsutil >/dev/null || { echo "gsutil not found - install the Google Cloud SDK." >&2; exit 1; }
    gsutil -m rsync -r "${DATA_ROOT}/tasks" "${BUCKET_URL%/}/tasks"
    gsutil -m rsync -r "${DATA_ROOT}/annotations" "${BUCKET_URL%/}/annotations"
    ;;
  s3://*)
    command -v aws >/dev/null || { echo "aws CLI not found - install the AWS CLI." >&2; exit 1; }
    aws s3 sync "${DATA_ROOT}/tasks" "${BUCKET_URL%/}/tasks"
    aws s3 sync "${DATA_ROOT}/annotations" "${BUCKET_URL%/}/annotations"
    ;;
  *)
    echo "BUCKET_URL must start with gs:// or s3://" >&2
    exit 1
    ;;
esac

echo "Synced ${DATA_ROOT}/tasks and ${DATA_ROOT}/annotations to ${BUCKET_URL}"
