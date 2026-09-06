"""One-time import of an existing SQLite store into the file store.

Earlier versions kept records in SQLite and only attachments on disk. Anyone
who synced against one of those has real data in that database, so switching
the storage engine cannot simply start from empty.

Runs at startup, does nothing unless there is a database to read and the file
store is empty, and never deletes the database -- it stays as a fallback until
the new store has been seen to work.
"""
import json
import logging
import sqlite3
from pathlib import Path

from app.core.filestore import FileStore, StoredRecord, UnsafeName, as_utc

log = logging.getLogger(__name__)

MARKER = "migrated-from-sqlite.json"


def _database_path(database_url: str) -> Path | None:
    if not database_url.startswith("sqlite"):
        return None
    path = database_url.replace("sqlite:////", "/").replace("sqlite:///", "")
    if not path or path == ":memory:":
        return None
    return Path(path)


def _parse(value) -> "object":
    import datetime as dt

    if isinstance(value, dt.datetime):
        return as_utc(value)
    return as_utc(dt.datetime.fromisoformat(str(value)))


def migrate_if_needed(store: FileStore, database_url: str) -> int:
    """Copy records across. Returns how many were imported."""
    marker = store.root / MARKER
    if marker.exists():
        return 0

    database = _database_path(database_url)
    if database is None or not database.exists():
        return 0

    if store.current_rev() > 0:
        # Already holds data. Importing on top could resurrect records deleted
        # since, so leave it alone and say why.
        log.info("File store already has data; skipping SQLite import.")
        return 0

    log.info("Importing existing records from %s", database)
    imported = 0
    try:
        connection = sqlite3.connect(f"file:{database}?mode=ro", uri=True)
        connection.row_factory = sqlite3.Row
        try:
            rows = connection.execute(
                "SELECT collection, record_id, payload, updated_at, deleted, rev,"
                " device_id FROM records ORDER BY rev ASC"
            ).fetchall()
        finally:
            connection.close()
    except sqlite3.Error as exc:
        log.warning("Could not read the old database, leaving it untouched: %s", exc)
        return 0

    records: list[StoredRecord] = []
    for row in rows:
        try:
            records.append(
                StoredRecord(
                    collection=row["collection"],
                    record_id=row["record_id"],
                    payload=json.loads(row["payload"]) if row["payload"] else None,
                    updated_at=_parse(row["updated_at"]),
                    deleted=bool(row["deleted"]),
                    # Revisions are preserved, so a client's existing cursor
                    # stays meaningful and nobody has to resync from scratch.
                    rev=int(row["rev"]),
                    device_id=row["device_id"],
                )
            )
        except (ValueError, KeyError, UnsafeName) as exc:
            log.warning("Skipping unreadable row during import: %s", exc)

    for record in records:
        try:
            store._write_atomically(
                store._record_path(record.collection, record.record_id),
                record.to_json(),
            )
            imported += 1
        except (OSError, UnsafeName) as exc:
            log.warning(
                "Could not import %s/%s: %s", record.collection, record.record_id, exc
            )

    store.rebuild_index()

    try:
        marker.write_text(
            json.dumps({"source": str(database), "records": imported}),
            encoding="utf-8",
        )
    except OSError as exc:
        log.warning("Could not write migration marker: %s", exc)

    log.info(
        "Imported %d records; the old database is left in place as a fallback.",
        imported,
    )
    return imported
