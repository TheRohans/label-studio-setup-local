# label-studio-setup-local

Run [Label Studio](https://labelstud.io) locally with Docker Compose, backed entirely
by a directory on your own drive — SQLite for the database, local files for storage.
No cloud account, no bucket, no Kubernetes.

The data directory is laid out the same way as the sibling `label-studio-setup` repo
(a Cloud Run + GCS variant), so a local setup started here can be moved to the cloud
later without restructuring anything.

- `$DATA_ROOT/tasks/` — drop raw files here (images, audio, text, whatever you're
  labeling).
- `$DATA_ROOT/annotations/` — finished annotations land here automatically as JSON.
- `$DATA_ROOT/ls-internal/` — Label Studio's SQLite database and internal state
  (overridable, see below).

**Running more than one project?** Give each one its own subdirectory —
`$DATA_ROOT/tasks/<project-name>/` and `$DATA_ROOT/annotations/<project-name>/` —
and point that project's Source/Target storage at its own subdirectory, not the
shared `tasks/`/`annotations/` root. Local Files storage has no per-project
filtering; a storage connection imports everything under whatever directory it
points at, so multiple projects sharing the bare root would each pull in every
other project's files.

## Prerequisites

- Docker, with the Compose v2 plugin (`docker compose version` should work).
- A drive with enough free space, mounted somewhere on the filesystem (e.g.
  `/mnt/bigdrive`). This repo doesn't partition, format, or mount anything for you —
  do that yourself first.
- **If that drive is vfat/exFAT/NTFS** (common for pre-formatted external drives):
  those filesystems don't support per-file Unix permissions at all, and Label Studio's
  upload handling needs to `chmod` files it saves — that fails there with "Operation
  not permitted" no matter how the drive is mounted, since it's a filesystem
  limitation, not a permission setting. Point `LS_INTERNAL_DIR` (see below) at a
  directory on the host's own native filesystem instead; `tasks/`/`annotations/` are
  fine on the big drive either way, since those are just plain file drops.

## Quickstart

```
make DATA_ROOT=/mnt/bigdrive/label-studio all
```

This creates `tasks/`, `annotations/`, `ls-internal/` under `DATA_ROOT` and starts the
container.

1. `make admin-info` — prints the URL to open, plus the admin email/password. The URL
   uses this machine's auto-detected LAN IP, so it works from other computers on the
   network too, not just this one (override with `LS_HOST=` if it guesses the wrong
   interface — see "Accessing it from another computer" below).
2. Log in with that email/password, then click **Create new token** under Account &
   Settings and copy it into `.label-studio-api-token` (`echo -n "<token>" >
   .label-studio-api-token`). The token `admin-info` prints/caches on first run is a
   placeholder — Label Studio doesn't actually honor presetting it, so this manual step
   is required every time, not just as a fallback.
3. Create a Label Studio **project** with a labeling config for your data (image
   classification, bounding boxes, NER, etc.) — a one-time step in the UI.
4. Copy the project's numeric ID from the URL (`.../projects/<id>/...`).
5. `make DATA_ROOT=... LS_PROJECT_ID=<id> configure-storage` — wires up `tasks/` as
   import storage and `annotations/` as export storage for that project.

`DATA_ROOT` has no default and is required on every invocation — export it once to
stop repeating it: `export DATA_ROOT=/mnt/bigdrive/label-studio`.

If `DATA_ROOT` is on a vfat/exFAT/NTFS drive (see Prerequisites above), also set
`LS_INTERNAL_DIR` to somewhere on the host's native filesystem:
```
make DATA_ROOT=/mnt/bigdrive/label-studio LS_INTERNAL_DIR=/var/lib/label-studio-internal all
```

## Accessing it from another computer

Docker publishes the port on all of this machine's network interfaces by default, so
it's already reachable from other computers on your LAN — nothing to configure there.
`make admin-info` / `make up` print a URL using an auto-detected LAN IP for
convenience; if the box has multiple network interfaces and it picks the wrong one,
override it: `make LS_HOST=192.168.1.50 up`.

If nothing loads from another machine, check the host's firewall — e.g. on Ubuntu,
`sudo ufw allow 6767/tcp` (swap the port if you override `LS_PORT`).

## Day to day

Drop new files into `$DATA_ROOT/tasks/`, then:

```
make LS_PROJECT_ID=<id> sync
```

to pick them up as tasks. Finished annotations appear in `$DATA_ROOT/annotations/`
automatically as you label — no sync needed on that side.

## Commands

| Command | Description |
| --- | --- |
| `make all` | Create data dirs and start the container |
| `make up` / `make down` | Start / stop Label Studio |
| `make logs` | Tail container logs |
| `make admin-info` | Print the admin login and API token |
| `make configure-storage LS_PROJECT_ID=<id>` | Wire up import/export storage for a project |
| `make sync LS_PROJECT_ID=<id>` | Re-sync import storage after adding files |
| `make sync-to-cloud BUCKET_URL=gs://...` | Push `tasks/` and `annotations/` to a cloud bucket |
| `make destroy` | Stop and remove the container (data is left in place) |

## Moving to the cloud later

Two options, depending on how far you want to go:

- **Lift and shift.** Copy `$DATA_ROOT` onto a cloud VM's disk, clone this repo there,
  and run the same `make DATA_ROOT=... up`. Nothing else changes.
- **Move to the `label-studio-setup` repo** (Cloud Run + GCS). Run
  `make BUCKET_URL=gs://<bucket> sync-to-cloud` to push `tasks/` and `annotations/`
  into that repo's bucket layout, then follow its own storage setup. Project/task
  metadata in the SQLite db isn't part of that sync — see `CLAUDE.md` for the details
  on migrating it.

## Security

Reachable by anyone on your LAN by default (see above) — Label Studio's own login is
the only auth boundary, and `LABEL_STUDIO_DISABLE_SIGNUP_WITHOUT_LINK=true` is set so
the UI can't be used to self-register new accounts. If you want it reachable only from
this machine, edit the port line in `docker-compose.yml` to
`"127.0.0.1:${LS_PORT:-6767}:8080"`.
