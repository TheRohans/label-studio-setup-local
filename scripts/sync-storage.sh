#!/bin/bash
# Triggers a re-sync of the project's Source local-files storage, so files
# dropped into tasks/ since the last sync show up as new Label Studio tasks.
# Run manually after a batch of new files (see README "Sync trigger" - no
# filesystem watcher wired up, by design, same tradeoff as the cloud setup).
set -euo pipefail

URL="$1"; TOKEN="$2"; PROJECT_ID="$3"

STORAGE_ID=$(curl -sf -H "Authorization: Token ${TOKEN}" \
  "${URL%/}/api/storages/localfiles?project=${PROJECT_ID}" \
  | python3 -c 'import sys, json; d = json.load(sys.stdin); print(d[0]["id"])')

echo "Syncing source storage id ${STORAGE_ID} ..."
curl -sf -H "Authorization: Token ${TOKEN}" -X POST "${URL%/}/api/storages/localfiles/${STORAGE_ID}/sync"
echo ""
echo "Sync triggered - new files under tasks/ should appear as tasks shortly."
