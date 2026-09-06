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

## Configuration

Set these in `docker-compose.yml` under the `backend` service.

| Variable | Default | What it does |
| :-- | :-- | :-- |
| `API_AUTH_TOKEN` | *(empty)* | Shared secret sent as `X-Trudido-Token`. **Empty means no authentication** — acceptable on an isolated home network, not on anything reachable from outside it. |
| `DATABASE_URL` | `sqlite:////db/trudido.db` | Record store. Keep it on the named volume, not the NAS share — see below. |
| `BLOB_DIR` | `/data/blobs` | Note attachments. Safe on a network share. |
| `MAX_BLOB_MB` | `256` | Largest single attachment. |
| `SYNC_PAGE_SIZE` | `500` | Records per pull page. |
| `CORS_ORIGINS` | `*` | Browser origins allowed to call the API. |

> **Why the database is not on the NAS share.** SQLite's locking is unreliable
> over SMB and NFS and will eventually corrupt the file. The database lives on
> a local Docker volume; attachments, which are ordinary immutable files, sit
> on the share where your existing snapshots cover them.

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
| Records | SQLite at `/db/trudido.db` inside the container, on the `trudido_db` volume |
| Attachments | `/data/blobs/<first two hex>/<sha256>` — ordinary files, on the NAS share |

The attachments are content-addressed, so they have hashes for names and no
extensions. That is deliberate: the same photo in three notes is stored once.
`inspect_data.py` prints the original filename alongside each hash.

The database is not meant to be browsed by hand, and doing so while the server
is running risks lock contention. Use the script.

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

The whole store is one SQLite file plus a directory of immutable blobs:

```bash
docker exec trudido-backend sqlite3 /db/trudido.db ".backup '/data/backup.db'"
```

This is a *convenience* copy. The app's own export (Settings → Data) remains
the authoritative backup, because it is readable without this server.
