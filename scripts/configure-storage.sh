#!/bin/bash
# Wires up Label Studio's Source (import) and Target (export) Local Files
# storage against directories on the bind-mounted drive, so files dropped in
# tasks/ become tasks and finished annotations get written back to
# annotations/ - no UI drag-and-drop needed.
#
# REGEX_FILTER (optional) restricts the source side to files matching a
# pattern, so any non-media sidecar files that end up in tasks/ (from
# whatever produced/labeled the data before it landed here) don't get swept
# in as bogus tasks of their own.
#
# NOTE: Label Studio's REST API has shifted slightly across versions. If a
# curl call here 404s or the JSON shape doesn't match, do the equivalent
# click-through once under Project > Settings > Cloud Storage in the UI -
# `make sync` will keep working against whatever storage connection exists.
set -euo pipefail

URL="$1"; TOKEN="$2"; PROJECT_ID="$3"; TASKS_PATH="$4"; ANN_PATH="$5"; USE_BLOB_URLS="$6"; REGEX_FILTER="${7:-}"

auth=(-H "Authorization: Token ${TOKEN}" -H "Content-Type: application/json")

# Build request bodies with python's json.dumps rather than string-interpolated
# heredocs - REGEX_FILTER is a regex, so it routinely contains backslashes
# that aren't valid unescaped inside a raw JSON string literal.
source_body=$(python3 -c '
import json, sys
project_id, path, use_blob_urls, regex_filter = sys.argv[1:5]
body = {
    "project": int(project_id),
    "path": path,
    "use_blob_urls": use_blob_urls.lower() == "true",
    "title": "local-tasks",
}
if regex_filter:
    body["regex_filter"] = regex_filter
print(json.dumps(body))
' "$PROJECT_ID" "$TASKS_PATH" "$USE_BLOB_URLS" "$REGEX_FILTER")

target_body=$(python3 -c '
import json, sys
project_id, path = sys.argv[1:3]
print(json.dumps({"project": int(project_id), "path": path, "title": "local-annotations"}))
' "$PROJECT_ID" "$ANN_PATH")

echo "Creating source local-files storage (${TASKS_PATH}, filter: ${REGEX_FILTER:-none}) ..."
curl -sf "${auth[@]}" -X POST "${URL%/}/api/storages/localfiles" -d "$source_body"
echo ""

echo "Creating target local-files storage (${ANN_PATH}) ..."
curl -sf "${auth[@]}" -X POST "${URL%/}/api/storages/export/localfiles" -d "$target_body"
echo ""

echo "Storage wired up. Drop files into \$DATA_ROOT/tasks then run 'make sync'."
