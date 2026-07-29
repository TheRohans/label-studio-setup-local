#!/usr/bin/env python3
"""Attach LabelMe-sourced annotations onto Label Studio tasks that already
exist (e.g. created by clicking Sync) - matching by filename via each
task's storage_filename - rather than creating new tasks itself.

Why this exists: Label Studio's storage Sync only recognizes tasks it
created itself. Bulk-importing tasks any other way (e.g. a plain JSON
import via the UI or API) creates tasks Sync has no record of, so
re-syncing the same storage later creates blank duplicates for files that
already have annotated tasks - permanently, with no way to undo it short of
recreating the project. This script avoids that entirely by attaching
annotations onto tasks Sync already created, so every task's origin stays
tied to Sync's own tracking and future Sync clicks on that storage
connection stay safe.

Handles Label Studio's JWT auth: a token from the UI's "Create new token"
is a long-lived *refresh* token, not usable directly against the API - this
exchanges it for a short-lived *access* token via /api/token/refresh/
before making calls, and re-exchanges automatically if a call 401s mid-run
(access tokens expire in ~5 minutes).

Idempotent: tasks that already have at least one annotation (checked fresh
from the API on every run, not a local manifest) are skipped, so re-running
after adding more labeled files to the source directory only touches
new/unlabeled ones.

Usage:
  python3 attach.py <url> <refresh_token> <project_id> <labelme_dir> \
      --from-name <name> --to-name <name>
"""
import argparse
import json
import os
import sys
import urllib.error
import urllib.request
from pathlib import Path


def get_access_token(url: str, refresh_token: str) -> str:
    req = urllib.request.Request(
        f"{url.rstrip('/')}/api/token/refresh/",
        data=json.dumps({"refresh": refresh_token}).encode(),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req) as resp:
        return json.loads(resp.read())["access"]


def api_call(url: str, path: str, access_token: str, method: str = "GET", body: dict | None = None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(
        f"{url.rstrip('/')}{path}",
        data=data,
        headers={"Authorization": f"Bearer {access_token}", "Content-Type": "application/json"},
        method=method,
    )
    with urllib.request.urlopen(req) as resp:
        return json.loads(resp.read())


def fetch_tasks(url: str, access_token: str, project_id: str) -> list:
    return api_call(url, f"/api/tasks/?project={project_id}&page_size=100000", access_token)["tasks"]


def convert_shape(shape: dict, width: float, height: float, from_name: str, to_name: str) -> dict:
    points = [[px / width * 100, py / height * 100] for px, py in shape["points"]]
    return {
        "type": "polygonlabels",
        "from_name": from_name,
        "to_name": to_name,
        "original_width": int(width),
        "original_height": int(height),
        "value": {"points": points, "polygonlabels": [shape["label"]]},
    }


def build_result(labelme_json: dict, from_name: str, to_name: str) -> list:
    width = labelme_json["imageWidth"]
    height = labelme_json["imageHeight"]
    return [
        convert_shape(shape, width, height, from_name, to_name)
        for shape in labelme_json["shapes"]
        if shape.get("points")
    ]


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("url")
    parser.add_argument("refresh_token")
    parser.add_argument("project_id")
    parser.add_argument("labelme_dir", help="directory containing LabelMe *.json + image pairs")
    parser.add_argument("--from-name", default="label")
    parser.add_argument("--to-name", default="image")
    args = parser.parse_args()

    access_token = get_access_token(args.url, args.refresh_token)

    print("Fetching existing tasks...")
    tasks = fetch_tasks(args.url, access_token, args.project_id)
    print(f"Found {len(tasks)} tasks in project {args.project_id}.")

    by_filename = {}
    for task in tasks:
        name = os.path.basename(task.get("storage_filename") or "")
        if name:
            by_filename[name] = task

    labelme_dir = Path(args.labelme_dir)
    json_files = sorted(labelme_dir.glob("*.json"))
    if not json_files:
        print(f"No .json files found in {labelme_dir}", file=sys.stderr)
        sys.exit(1)

    attached = 0
    skipped_labeled = 0
    skipped_missing = 0

    for i, p in enumerate(json_files):
        data = json.loads(p.read_text())
        if not isinstance(data, dict) or "imagePath" not in data or "shapes" not in data:
            print(f"skipping {p.name}: doesn't look like a LabelMe file", file=sys.stderr)
            skipped_missing += 1
            continue
        image_name = data["imagePath"]
        task = by_filename.get(image_name)
        if task is None:
            print(f"skipping {p.name}: no task found for image {image_name}", file=sys.stderr)
            skipped_missing += 1
            continue
        if task["total_annotations"] > 0:
            skipped_labeled += 1
            continue

        body = {"result": build_result(data, args.from_name, args.to_name)}

        for attempt in (1, 2):
            try:
                api_call(args.url, f"/api/tasks/{task['id']}/annotations/", access_token, method="POST", body=body)
                attached += 1
                break
            except urllib.error.HTTPError as e:
                if e.code == 401 and attempt == 1:
                    print("Access token expired, refreshing...")
                    access_token = get_access_token(args.url, args.refresh_token)
                    continue
                print(f"Failed to attach annotation for {p.name} (task {task['id']}): {e.code} {e.read().decode()}", file=sys.stderr)
                break

        if (i + 1) % 25 == 0:
            print(f"...{i + 1}/{len(json_files)}")

    print(f"Attached {attached} annotation(s). Skipped {skipped_labeled} already-labeled, {skipped_missing} with no matching task.")


if __name__ == "__main__":
    main()
