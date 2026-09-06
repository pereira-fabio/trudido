# Trudido sync server

Self-hosted sync for Trudido. Runs as an ordinary Docker Compose stack, shaped
for the same Proxmox LXC / TrueNAS SCALE deployment as peakpace.

The app remains offline-first. This server is a **sync peer, not a source of
truth**: with it switched off or unreachable, Trudido behaves exactly as it
always has, and nothing here is required to use the app.

## Quick start

```bash
git clone <this repo> /opt/trudido
cd /opt/trudido
docker compose up -d --build
```

- **Sync API and Swagger docs** — `http://<server>:8001/docs`
- **Browser app** — `http://<server>:8080`

### Ports

The host ports are configurable, because a NAS running more than one of these
stacks will collide — peakpace's backend also publishes `8000`. Put them in a
`.env` file beside `docker-compose.yml`:

```bash
TRUDIDO_API_PORT=8001
TRUDIDO_WEB_PORT=8080
```

Only the host side moves; the container still listens on `8000`, so
`API_AUTH_TOKEN` and the URL you enter in the app are the only things that
need to agree. To find what already holds a port:

```bash
ss -tlnp | grep :8000        # or: docker ps --format '{{.Names}}\t{{.Ports}}'
```

Then in the phone app: **Settings → Sync**, enter `http://<server>:8001` — the
host port above, not the container's — and the token, then press
*Test connection*.

## The browser app

`http://<server>:8080` serves a browser build of Trudido. nginx proxies `/api`
to the backend from the same origin, so the address to enter under **Sync** is
just the address of the page itself, and no CORS is involved.

It keeps its own copy of the data in the browser (IndexedDB) and syncs with the
server exactly as the phone does, so it works while the tab is open and loses
nothing when it is closed.

**It is not the whole app.** It shares the models, storage and sync client, but
has its own, smaller interface:

| Works | Does not |
| :-- | :-- |
| Tasks: add, edit, complete, bin, filter by folder | Reminders and notifications |
| Notes: create, edit and preview markdown | The rich text editor |
| Search across both | Attachments |
| Folders | Home-screen widgets, device calendar sync |
| Sync setup and status | The vault |

Two of those are deliberate rather than merely missing:

- **Notes written in the phone's rich editor open read-only.** They are stored
  as a Quill delta, and saving markdown over one would discard its formatting
  and its images. The text is shown; editing is refused.
- **The vault stays on the phone.** Its key is generated per device, so these
  notes cannot be decrypted anywhere else. That changes when key derivation
  moves to the vault password.

The reason it is a separate interface rather than the Android app compiled for
web: about a dozen files in that app import `dart:io`, which is fine on a phone
and cannot compile for a browser at all. Only code reachable from the entry
point is compiled, so a separate entry point avoids them entirely -- and means
the browser build cannot break the phone.

## Configuration

Set these in `docker-compose.yml` under the `backend` service.

| Variable | Default | What it does |
| :-- | :-- | :-- |
| `API_AUTH_TOKEN` | *(empty)* | Shared secret sent as `X-Trudido-Token`. **Empty means no authentication** — acceptable on an isolated home network, not on anything reachable from outside it. |
| `DATA_DIR` | `/data` | Everything: records, attachments, index. Point the volume at a share and that is where your data is. |
| `DATABASE_URL` | `sqlite:////data/trudido.db` | Read **only** to import an older SQLite install on first start. Never written to, never deleted. |
| `MAX_BLOB_MB` | `256` | Largest single attachment. |
| `SYNC_PAGE_SIZE` | `500` | Records per pull page. |
| `CORS_ORIGINS` | `*` | Browser origins allowed to call the API. |

### Putting the store on a NAS share

Records are individual JSON files written to a temporary name and renamed into
place. `rename` is atomic on CIFS and NFS as well as locally, so the whole
store is safe on a share — mount it on the host and bind it in:

```yaml
volumes:
  - /mnt/bigboy/trudido:/data
```

```bash
# /etc/fstab on the host
//192.168.178.59/bigboy /mnt/bigboy cifs credentials=/root/.smbcred,uid=1000,gid=1000,vers=3.0,nofail,_netdev 0 0
```

Use the IP rather than a `.local` name: mDNS generally does not resolve inside
containers even where it works on the host.

> **This used to be impossible.** Earlier versions kept records in SQLite,
> whose locking is unreliable over SMB and NFS — the file eventually corrupts.
> That is a SQLite constraint, not a share one, and dropping SQLite removes it.
> An existing SQLite store is imported automatically on first start, revisions
> and all, so no client has to resync; the old file is left in place as a
> fallback.

A `soft` mount fails rather than hangs when the NAS is unreachable, which is
the right choice here: the server answers `503`, the app keeps its cursor, and
the next sync picks up where it left off.

## How sync works

The server stores **opaque documents** keyed by `(collection, id)` and never
parses a payload. Two consequences worth knowing:

- Adding a field, or a whole model, to the app needs no change here.
- Vault notes arrive already encrypted. The server is structurally incapable of
  reading them.

Clients page through a server-assigned monotonic `rev`. A client remembers the
highest rev it has seen, pulls everything after it, then offers its own changes.
There is no session and no locking — a client that dies mid-sync resumes from
its old cursor and re-sends.

**Conflicts are last-write-wins on the client's `updated_at`**, with exact ties
broken on device id so two devices resolving the same collision independently
reach the same answer. A push whose record is older than the stored copy is
rejected and the server's version is returned, for the client to adopt. On the
app side a losing *note* version is written into note history rather than
discarded, so a clobbered edit stays recoverable.

Attachments are content-addressed by SHA-256: the same photo in three notes is
stored and transferred once, and an interrupted upload is fixed by repeating it.
The server recomputes the hash rather than trusting it, so a corrupted transfer
is refused instead of being served back to every device.

### Endpoints

| | |
| :-- | :-- |
| `GET /api/v1/health` | Liveness. No token needed, so container healthchecks need no secret. |
| `GET /api/v1/auth/check` | What the app's *Test connection* button calls. |
| `GET /api/v1/sync/changes?since=&limit=` | Everything after a cursor, oldest first. |
| `POST /api/v1/sync/changes` | Push changes; returns a cursor and any rejections. |
| `GET /api/v1/sync/status` | Cursor and live record counts per collection. |
| `GET /api/v1/blobs/manifest` | Every attachment hash held, to diff against. |
| `HEAD /api/v1/blobs/{sha256}` | Existence check without transferring bytes. |
| `PUT /api/v1/blobs/{sha256}` | Upload an attachment. Idempotent. |
| `GET /api/v1/blobs/{sha256}` | Download an attachment. |

## Seeing what is stored

The API returns opaque documents, which is right for the protocol and useless
for answering "did my notes actually arrive". `inspect_data.py` prints them:

```bash
# From anywhere that can reach the server
python3 server/backend/inspect_data.py --url http://<server>:8001 --token SECRET

# Or on the server itself
docker exec trudido-backend python /app/inspect_data.py --url http://localhost:8000 --token SECRET
```

```
Server   http://192.168.1.10:8001
Revision 47

notes  (12)
-----------
  2026-09-06 12:00  Groceries
  ...

todos  (31)
-----------
  2026-09-06 11:00  Call the plumber about the boiler
```

`--collection notes` narrows it, `--search plumber` filters, `--full` prints
whole payloads, `--deleted` includes the bin. It only reads.

A quick count without the listing:

```bash
curl -H "X-Trudido-Token: SECRET" http://<server>:8001/api/v1/sync/status
```

### Where the bytes actually are

| | |
| :-- | :-- |
| Records | `<DATA_DIR>/records/<collection>/<id>.json` — one file each, readable |
| Attachments | `<DATA_DIR>/blobs/<first two hex>/<sha256>`, with metadata beside each |
| Index | `<DATA_DIR>/index.json` — a **cache**, not a source of truth |

The attachments are content-addressed, so they have hashes for names and no
extensions. That is deliberate: the same photo in three notes is stored once.
`inspect_data.py` prints the original filename alongside each hash.

`index.json` only records which revision each file is at, so a pull does not
have to open every one. Delete it and it is rebuilt by scanning, revisions
intact — the record files alone are always sufficient.

## Development

```bash
cd server/backend
python3 -m venv .venv && . .venv/bin/activate
pip install -r requirements-dev.txt

uvicorn app.main:app --reload --port 8000     # run it
python -m pytest tests/ -q                    # test it
```

The test suite covers cursor paging, last-write-wins including tie-breaking,
tombstones, token enforcement, and attachment integrity.

## Backups

The whole store is a directory of files, so a backup is a copy of it:

```bash
tar czf trudido-$(date +%F).tar.gz -C /mnt/bigboy trudido
```

Or nothing at all, if the store already sits on a share your NAS snapshots.
That is most of the point of keeping it as files.

The app's own export (Settings → Data Management) is still worth having, since
it restores into the app directly without this server.
