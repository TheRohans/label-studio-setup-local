# labelme-import

Gets LabelMe-labeled datasets (JSON + image pairs) into Label Studio. Standalone from
the rest of this repo on purpose — the Makefile/`docker-compose.yml` set up a generic
Label Studio instance and know nothing about LabelMe; this is a data-prep step for
feeding already-labeled LabelMe datasets into it.

`attach.py` talks to the Label Studio API. It attaches annotations onto tasks that
*already exist* (created by clicking **Sync** on the project's Local Files storage),
rather than creating new tasks itself — see "Why not a simpler bulk import" below for
why that distinction matters and isn't optional.

## Why this works for different LabelMe shape types

Every LabelMe shape with a `points` list becomes a Label Studio `polygonlabels`
region — a `"polygon"` shape (many points, a real outline) and a `"line"` shape
(always exactly 2 points) both convert the same way, since Label Studio has no
separate line primitive and a 2-point polygon *is* a line. Point-only shapes
(`shape_type: "point"`) aren't handled — they don't have a `points` list to build a
region from.

## One subdirectory per dataset — don't skip this

Each Label Studio project's Local Files Source storage points at a single directory
and imports *everything* under it as tasks. If every dataset's images land straight
in `$DATA_ROOT/tasks/`, every project ends up seeing every other project's images too
— there's no per-project filtering, only per-directory. Give every dataset its own
subdirectory instead:

```
$DATA_ROOT/tasks/dataset-a/       <- e.g. left/right line images
$DATA_ROOT/tasks/dataset-b/       <- e.g. segmentation polygons
$DATA_ROOT/annotations/dataset-a/
$DATA_ROOT/annotations/dataset-b/
```

and register each project's storage against its own subdirectory
(`/label-studio/files/tasks/dataset-a`, `/label-studio/files/tasks/dataset-b`, etc.),
never the bare `/label-studio/files/tasks` root.

## Workflow

1. Copy the images (not the LabelMe `.json` files) into their own subdirectory under
   `$DATA_ROOT/tasks/<dataset-name>/` — see above.
2. In the project's Settings → Cloud Storage (Label Studio's umbrella name for this
   settings page — nothing about Local Files storage is actually cloud-based), add a
   Source storage of type "Local files" pointing at
   `/label-studio/files/tasks/<dataset-name>`, and a Target storage of type
   "Local files" pointing at `/label-studio/files/annotations/<dataset-name>`. This
   registration step is required before local-files serving works at all — Label
   Studio 404s on any path not tied to a registered storage connection, file-on-disk
   or not.
3. Click **Sync** on the Source storage. This creates one blank, unlabeled task per
   image, properly tracked by that storage connection.
4. Get a refresh token: log into Label Studio, Account & Settings → **Create new
   token**.
5. Run:
   ```
   python3 attach.py <url> <refresh_token> <project_id> <labelme_dir> \
       --from-name <name> --to-name <name>
   ```
   It fetches the project's task list, matches each task to a LabelMe file by
   filename (via the task's `storage_filename`), and attaches that file's annotation
   onto the already-existing task. Tasks that already have an annotation are skipped
   automatically, so it's safe to re-run.

### Label Studio's JWT auth, briefly

The token from "Create new token" is a long-lived *refresh* token — it doesn't
authenticate API calls by itself. `attach.py` exchanges it for a short-lived *access*
token via `POST /api/token/refresh/` and re-exchanges automatically if a call `401`s
mid-run (access tokens expire in ~5 minutes). You shouldn't need to think about this;
it's handled internally.

### Example: path dataset (left/right lines)

Labeling config:
```xml
<View>
  <Image name="image" value="$image"/>
  <PolygonLabels name="line" toName="image">
    <Label value="left" background="#1f77b4"/>
    <Label value="right" background="#d62728"/>
  </PolygonLabels>
</View>
```
```
python3 attach.py http://<host>:<port> <refresh_token> <project_id> \
    /path/to/labelme/paths --from-name line --to-name image
```

### Example: segmentation dataset (multiple object classes)

Labeling config:
```xml
<View>
  <Image name="image" value="$image"/>
  <PolygonLabels name="label" toName="image">
    <Label value="class-a" background="#2ca02c"/>
    <Label value="class-b" background="#9467bd"/>
    <Label value="class-c" background="#ff7f0e"/>
  </PolygonLabels>
</View>
```
```
python3 attach.py http://<host>:<port> <refresh_token> <project_id> \
    "/path/to/labelme/dataset" --from-name label --to-name image
```

## Adding more data later

Since every task came from Sync, adding more data is just repeating steps 1, 3, and 5
above against the same directory and storage connection:

1. Drop the new images into the *same* `$DATA_ROOT/tasks/<dataset-name>/` directory
   (safe — `rsync` skips files that already match).
2. Click **Sync** again on the same storage. It only creates tasks for files it
   hasn't seen before; files from earlier batches are already linked and get skipped.
3. Run `attach.py` again, pointed at a directory containing the new batch's LabelMe
   files (their matching tasks now exist thanks to step 2). Already-labeled tasks are
   skipped automatically, so it's fine to point it at the whole cumulative LabelMe
   source directory too if that's easier than maintaining a separate staging folder.

## Why not a simpler bulk import

An earlier version of this tool (`convert.py`) wrote a plain Label Studio tasks JSON
file for bulk import via Data Manager -> Import — no API calls, no Sync dependency,
simpler on paper. It got scrapped: storage Sync only recognizes tasks *it* created,
tracked internally per storage connection. A bulk import creates tasks Sync has no
record of, so clicking Sync on that storage connection afterward — for any reason,
including just wanting to add new files later — creates a blank duplicate task for
every file, because Sync can't tell "already has a task, from a bulk import" apart
from "never seen this file before." This isn't fixable after the fact: deleting the
storage connection to "turn off" Sync also breaks image serving entirely (confirmed
live), and there's no way to disable just the Sync button while keeping the storage
registered. Once a directory's been bulk-imported, that storage connection's Sync
button is permanently dangerous to click, forever - which happened on this project's
first real run, and required deleting the whole project and redoing it with
`attach.py` instead. `attach.py` avoids the problem entirely by never creating a
task Sync doesn't already know about.
