# label-studio-setup-local

Local Docker Compose counterpart to the sibling `../label-studio-setup` repo (Label
Studio on Cloud Run, GCS-backed via Litestream). Same operational shape — a Makefile
driving container lifecycle, storage wiring, and sync — but targeting a directory on a
local drive instead of a GCS bucket.

## Status

Confirmed working end-to-end on a real Linux box as of 2026-07-29,
including a real image loading in the labeling UI — but getting there required
working around every layer in this repo's stack at least once (see the gotchas
below). `scripts/configure-storage.sh`/`sync-storage.sh` are still unverified against
a live instance — the manual UI path that actually got exercised (Project → Settings
→ Cloud Storage → Add Source/Target Storage, type "Local files") is confirmed correct,
but the equivalent API calls those scripts make were never successfully run this
session, because of the token problem noted below. Don't assume they work; if
`configure-storage`/`sync` 401s or 404s, do the two-field UI form instead rather than
debugging the script blind.

**Resolved 2026-07-29: this image version's API needs `Authorization: Bearer
<access_token>`, not `Authorization: Token <value>`.** The UI's "Create new token"
gives a JWT *refresh* token (`token_type: "refresh"` in the payload) - it doesn't
authenticate anything directly. Exchange it first:
```
POST /api/token/refresh/   body: {"refresh": "<refresh_token>"}   ->   {"access": "<access_token>"}
```
then use `Authorization: Bearer <access_token>` for real calls. The access token is
short-lived (~5 minutes, per its `iat`/`exp`), so anything making more than a handful
of calls needs to catch `401` and re-exchange mid-run rather than getting one access
token up front - see `labelme-import/attach.py` for the pattern (refresh-and-retry
once on 401).

`configure-storage.sh`/`sync-storage.sh` still send `Authorization: Token <value>` and
have NOT been updated to this flow yet - they're still unverified/likely broken
against this image version. Fix them the same way if the UI storage-form workaround
ever becomes insufficient (e.g. scripting `configure-storage` for a new project
non-interactively).

**Confirmed: `LABEL_STUDIO_USER_TOKEN` is NOT honored as a token preset on this image
version.** Verified 2026-07-29 — Account & Settings shows no existing token, just a
"Create new token" button; the value `admin-info` generates and caches in
`.label-studio-api-token` never existed server-side. This isn't a maybe-fallback
anymore, it's the expected path every time: create the token in the UI after first
login, then `echo -n "<token>" > .label-studio-api-token` to overwrite the generated
one before running `configure-storage`/`sync`. Don't waste time debugging 401s from
`make configure-storage`/`sync` before checking this first.

**Confirmed: `/data/local-files/?d=...` 404s for every file until a Local Files
storage connection is registered on the project — file presence and auth are both
irrelevant to this.** Verified 2026-07-29, end to end. Sequence that isolated it:
unauthenticated request → `401` (expected — no credentials at all). Authenticated
browser request (valid session cookie, user logged in) for a file confirmed present
on disk, byte-identical on host and in container → still `404`, for literally every
task, uniformly. That ruled out both "file missing" and "auth failing" — `401` means
no valid credentials; `404` from an authenticated request means the server processed
it and found nothing to serve. Root cause: Label Studio's local-files serving only
resolves paths that fall under a storage connection actually registered on the
project; an unregistered path 404s regardless of `LABEL_STUDIO_LOCAL_FILES_DOCUMENT_ROOT`
being set correctly and the file genuinely sitting there.

Fixed via the UI (not the API, since that's where this got resolved) —
**Project → Settings → Cloud Storage** (yes, that's the actual section name, even
though nothing about Local Files storage is cloud-anything - it's Label Studio's
umbrella settings page for every storage backend, S3/GCS/Azure/local, and never got
renamed when Local Files was added). Add Source Storage, type "Local files", path
`/label-studio/files/tasks`, "treat every object as a source file" (`use_blob_urls`)
on. Same for Target Storage, type "Local files", path `/label-studio/files/annotations`.
This is exactly what `scripts/configure-storage.sh` is supposed to automate via the
API - but that path was never actually exercised successfully in this session, because
of the separate token problem below, so treat the API version as still unverified even
though the underlying UI flow it's supposed to replicate is now confirmed correct.

**Known gotcha: `/label-studio/data` needs real Unix filesystem semantics, not just
write access.** Two distinct issues surfaced in sequence on the target box's
vfat-mounted drive, both against `/label-studio/data` (the `heartexlabs/label-studio` image's
internal state dir - db + upload/media handling), and it's worth keeping them
separate since they look similar but aren't:

1. **Startup: image runs as a fixed, non-root UID/GID** (observed: `1001:0` on the
   version pulled 2026-07-29) and its own `05-check-data-permissions.sh` entrypoint
   check refuses to boot if the dir isn't writable by it. On ext4/xfs/btrfs this is a
   `chown` on the host dir. On vfat there's no per-file ownership to `chown` — the
   whole mount's ownership is fixed at mount time via `uid=`/`gid=`/`umask=`, applied
   uniformly, so there's no way to specifically match one container UID. Fixed by
   mounting with `umask=000` (world read/write).
2. **Later, deeper: file import failed with `[Errno 1] Operation not permitted` on a
   path under `/label-studio/data/media/upload/...`.** `EPERM`, not `EACCES` — the
   write itself succeeded (umask=000 handled that), but Label Studio's Django backend
   then calls `chmod()` on every saved upload (`FILE_UPLOAD_PERMISSIONS`), and vfat
   rejects `chmod` unconditionally on every file, always - FAT-family filesystems have
   no per-file permission bits at all to change, so there's no mount option that fixes
   this. It's not a permissions problem, it's a missing filesystem feature.

Fix for #2: `LS_INTERNAL_DIR` (Makefile + `docker-compose.yml`) lets `/label-studio/data`
be bind-mounted from somewhere other than `$DATA_ROOT`, so it can sit on the host's
native filesystem while `tasks/`/`annotations/` (plain file drops - no chmod needed)
stay on the big vfat drive. Don't try to solve #2 with a umask or uid trick the way #1
was solved - there isn't one; vfat structurally cannot do this.

## Design decisions

- **No custom Dockerfile, no Litestream.** The cloud repo ships both because Cloud Run
  scales to zero and the SQLite file needs to survive that by continuously replicating
  to GCS. A local box's disk is already durable, so this repo runs the stock
  `heartexlabs/label-studio` image directly and just bind-mounts `LS_INTERNAL_DIR`
  (defaults to `$DATA_ROOT/ls-internal`) as the data dir. Don't add Litestream back
  here unless the container itself starts getting torn down and recreated (e.g. if
  this migrates to Cloud Run later — at that point, use `../label-studio-setup` instead
  of reinventing it here).
- **Directory layout mirrors the cloud bucket layout on purpose**
  (`tasks/`, `annotations/`, `ls-internal/`), so `sync-to-cloud.sh` can be a dumb
  `rsync`/`gsutil rsync` rather than a format conversion, and so the two repos stay
  conceptually swappable. Keep this layout in sync if either repo's prefixes change.
  `LS_INTERNAL_DIR` can point `ls-internal/` outside `$DATA_ROOT` (see the vfat gotcha
  above) — when it does, `sync-to-cloud.sh` is unaffected either way, since it never
  touched `ls-internal/` to begin with.
- **Local Files storage, not S3-compatible/MinIO.** Considered running a local MinIO
  container to keep the storage API identical to the cloud repo's GCS calls, but that's
  an extra moving part for no real benefit — Label Studio's native Local Files storage
  type does the same job directly against the bind mount. Revisit only if a use case
  needs S3-compatible access to the same files from outside the container.
- **Makefile interface intentionally matches `../label-studio-setup`** (`admin-info`,
  `configure-storage`, `sync`, `destroy`) so muscle memory transfers between the two
  repos. Keep new targets named consistently with that repo where the concept overlaps.
- **`LS_HOST` exists purely for display.** Docker already publishes `LS_PORT` on all
  host interfaces by default (this is a LAN-accessible setup, not localhost-only), so
  `LS_HOST` doesn't change reachability — it only controls what URL gets printed by
  `admin-info`/`up`, auto-detected via `hostname -I` (Linux-only; harmless no-op
  fallback to `localhost` on macOS/BSD, which is fine since dev/testing of this repo
  happens there while the actual target is the Linux box). Don't read its absence as
  "not exposed" when reasoning about security here.
- **`REGEX_FILTER` on the source storage is generic, not format-specific.** Added to
  let the sync skip non-media files that end up in `tasks/` for whatever reason. Empty
  by default (no filtering, same behavior as before it existed). Resist the urge to
  default it to something format-opinionated (e.g. image extensions only) — this repo
  doesn't know what kind of data any given user is labeling, and `SOURCE_USE_BLOB_URLS`'s
  own doc comment already spans images/audio/video/pdf/text.
- **`scripts/*.sh` build request bodies via `python3 -c ... json.dumps(...)`, not
  string-interpolated heredocs.** `configure-storage.sh` used to build the JSON body as
  a raw heredoc; that breaks the moment any interpolated value contains a backslash or
  quote (a regex like `.*\.(jpg|png)$` isn't valid unescaped inside a JSON string
  literal). Values go in via `sys.argv`, never interpolated into Python source text
  either, to avoid the same class of bug one layer up. Keep this pattern for any new
  script that builds a JSON body from a value that isn't a fixed literal.

## Migration path details (SQLite → cloud)

`sync-to-cloud.sh` only moves `tasks/` and `annotations/` — plain files that never lived
in the database. It deliberately does **not** attempt to ship `ls-internal/`'s raw
`.sqlite3` file into the cloud repo's `ls-internal/` GCS prefix, because Litestream
expects its own generation/WAL-shipping format there, not a flat file copy; dropping the
raw file in would not produce something `litestream restore` can read.

To carry over actual project/task/annotation *metadata* (as opposed to the files
themselves, which sync fine):

- Simplest: recreate the project in the cloud UI and re-run that repo's
  `configure-storage` against the now-populated bucket. Fine if there isn't much
  metadata worth preserving (label configs, task-level state) beyond the files.
- Full fidelity: Django `dumpdata`/`loaddata`, same manual step
  `../label-studio-setup`'s own SQLite → Cloud SQL upgrade path documents:
  ```
  docker compose exec label-studio label-studio dumpdata > dump.json
  ```
  then load that against the target database. Not automated here or there — running
  `loaddata` against a real production database isn't something to script blindly.

## labelme-import/

Deliberate, explicit exception to "keep this repo generic" — user directive
(2026-07-29): the top-level Makefile/compose setup should stay generic (it doesn't
know or care what format your data is in), but LabelMe → Label Studio conversion is a
real recurring need here, so it lives in its own subfolder rather than a sibling repo.
Don't fold its logic back into `scripts/configure-storage.sh` or the Makefile, and
don't let it grow assumptions that leak into the generic setup (e.g. don't make
`REGEX_FILTER`'s default LabelMe-shaped).

`attach.py` is the only script here now (as of 2026-07-29 cleanup) — no API-call-free
"pure converter" alternative anymore, on purpose, see "Why not a simpler bulk import"
below. It talks to the Label Studio API: fetches a project's existing task list
(created by clicking Sync on that project's Local Files storage), matches each task
to a LabelMe file by filename via the API's `storage_filename` field, and attaches
that file's annotation onto the already-existing task rather than creating a new one.

Handles two current dataset shapes (both under LabelMe's schema, so one script covers
both): 2-point `"line"` shapes (path/lane markings) and many-point `"polygon"` shapes
(segmentation outlines). Both become `polygonlabels` regions — Label Studio has no
separate line primitive, and a 2-point polygon *is* a line. Only requires shapes to
have a non-empty `points` list; doesn't special-case `shape_type`.

**Why not a simpler bulk import.** An earlier version of this tool (`convert.py`,
removed 2026-07-29) was a pure converter with no API calls — wrote a plain tasks JSON
file, imported via Data Manager -> Import or a manual curl. Simpler on paper, but it
got scrapped for a real reason worth remembering if anyone's tempted to rebuild it:
storage Sync only recognizes tasks it created itself, tracked internally per storage
connection. A bulk import creates tasks Sync has no record of, so clicking Sync on
that storage connection afterward — for any reason, including just wanting to add new
files later — creates a blank duplicate task for every file, because Sync can't tell
"already has a task, from a bulk import" apart from "never seen this file before."
Not fixable after the fact either: deleting the storage connection to "turn off" Sync
also breaks image serving entirely (confirmed live), and there's no way to disable
just the Sync button while keeping the storage registered. This actually happened to
the line-annotation project on its first real run — required deleting the whole
project and redoing it with `attach.py` instead. Don't bring `convert.py`'s approach
back without solving this first.

**One subdirectory per dataset under `tasks/`/`annotations/` is required, not
optional, once there's more than one project.** Discovered 2026-07-29 after the path
dataset's 232 images were dropped straight into `$DATA_ROOT/tasks/` (flat, no
subdirectory). Label Studio's Local Files storage has no per-project filtering — a
project's Source storage points at one directory and imports everything under it.
With everything flat in the shared `tasks/` root, *every* project's storage would end
up pointing at the same directory and pulling in every other project's images too.
`labelme-import/README.md` documents the subdirectory convention as the default now —
don't go back to flat `tasks/` for a new dataset.

Verified end-to-end on two real datasets: a line-annotation project (232/232 tasks,
zero duplicates, zero misattached) and a polygon-segmentation project (51/51, same
result).

## Conventions

- Follow the same caveats-and-verify tone as `../label-studio-setup`'s README when
  editing docs — this is a from-docs scaffold, not something either repo's author has
  run end-to-end yet.
- Keep `README.md` public-facing (what a GitHub visitor needs to use the repo); keep
  design rationale, unverified assumptions, and migration internals here instead.
