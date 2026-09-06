"""Records as plain files on disk.

This exists because the natural place for the data is a NAS share, and SQLite
cannot live on one. Its locking is unreliable over SMB and NFS and the file
eventually corrupts -- which is why the database used to sit on a separate
local volume while only the attachments went to the share.

That constraint is SQLite's, not the share's. A record written to its own file,
temp-then-rename, is atomic on CIFS and NFS alike, so everything can live in one
directory the user picks:

    <root>/
      records/<collection>/<id>.json
      blobs/<ab>/<sha256>
      index.json

`index.json` maps each record to its revision so "changes since rev" does not
have to open every file. It is a cache, not a second source of truth: delete it
and it is rebuilt by scanning, so the record files alone are always sufficient.
"""
import datetime as dt
import json
import logging
import os
import re
import threading
from dataclasses import dataclass, field
from pathlib import Path
from typing import Iterable

log = logging.getLogger(__name__)

# Collection and id both become path segments, so they have to be incapable of
# escaping the root. Anything outside this is rejected rather than sanitised:
# quietly rewriting an id would store a record under a name the client does not
# know, and it would look like data loss on the next pull.
_SAFE_SEGMENT = re.compile(r"^[A-Za-z0-9_][A-Za-z0-9_.\-]{0,127}$")


class UnsafeName(ValueError):
    """A collection or record id that cannot be used as a filename."""


def _check(segment: str, what: str) -> str:
    if not _SAFE_SEGMENT.match(segment) or segment in {".", ".."}:
        raise UnsafeName(f"Unsafe {what}: {segment!r}")
    return segment


def utcnow() -> dt.datetime:
    return dt.datetime.now(dt.timezone.utc)


def as_utc(value: dt.datetime) -> dt.datetime:
    if value.tzinfo is None:
        return value.replace(tzinfo=dt.timezone.utc)
    return value.astimezone(dt.timezone.utc)


@dataclass
class StoredRecord:
    collection: str
    record_id: str
    payload: dict | None
    updated_at: dt.datetime
    deleted: bool
    rev: int
    device_id: str | None = None

    def to_json(self) -> dict:
        return {
            "collection": self.collection,
            "id": self.record_id,
            "payload": self.payload,
            "updated_at": self.updated_at.isoformat(),
            "deleted": self.deleted,
            "rev": self.rev,
            "device_id": self.device_id,
        }

    @staticmethod
    def from_json(raw: dict) -> "StoredRecord":
        return StoredRecord(
            collection=raw["collection"],
            record_id=raw["id"],
            payload=raw.get("payload"),
            updated_at=as_utc(dt.datetime.fromisoformat(raw["updated_at"])),
            deleted=bool(raw.get("deleted", False)),
            rev=int(raw["rev"]),
            device_id=raw.get("device_id"),
        )


@dataclass
class _Entry:
    """What the index holds. Enough to answer a pull without opening files."""

    rev: int
    updated_at: dt.datetime
    deleted: bool
    collection: str = ""
    record_id: str = ""


@dataclass
class FileStore:
    root: Path
    _index: dict[tuple[str, str], _Entry] = field(default_factory=dict)
    _next_rev: int = 1
    _lock: threading.RLock = field(default_factory=threading.RLock)

    # ------------------------------------------------------------ layout

    @property
    def records_dir(self) -> Path:
        return self.root / "records"

    @property
    def blobs_dir(self) -> Path:
        return self.root / "blobs"

    @property
    def index_path(self) -> Path:
        return self.root / "index.json"

    def _record_path(self, collection: str, record_id: str) -> Path:
        return (
            self.records_dir
            / _check(collection, "collection")
            / f"{_check(record_id, 'record id')}.json"
        )

    # ------------------------------------------------------------ writing

    @staticmethod
    def _write_atomically(path: Path, data: dict) -> None:
        """Write beside the target and rename over it.

        rename is atomic on CIFS and NFS as well as locally, so a reader never
        sees half a record and an interrupted write leaves the previous version
        intact rather than a truncated file.
        """
        path.parent.mkdir(parents=True, exist_ok=True)
        temporary = path.with_suffix(path.suffix + ".tmp")
        with open(temporary, "w", encoding="utf-8") as handle:
            json.dump(data, handle, ensure_ascii=False)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)

    def _save_index(self) -> None:
        """Best effort. The index is derivable, so failing to write it must not
        fail the request that just stored a record successfully."""
        try:
            self._write_atomically(
                self.index_path,
                {
                    "next_rev": self._next_rev,
                    "entries": [
                        {
                            "collection": collection,
                            "id": record_id,
                            "rev": entry.rev,
                            "updated_at": entry.updated_at.isoformat(),
                            "deleted": entry.deleted,
                        }
                        for (collection, record_id), entry in self._index.items()
                    ],
                },
            )
        except OSError as exc:
            log.warning("Could not write index (will rebuild on restart): %s", exc)

    # ------------------------------------------------------------ loading

    def open(self) -> None:
        """Prepare the directories and load the index, rebuilding if needed."""
        self.records_dir.mkdir(parents=True, exist_ok=True)
        self.blobs_dir.mkdir(parents=True, exist_ok=True)
        with self._lock:
            if not self._load_index():
                self.rebuild_index()

    def _load_index(self) -> bool:
        if not self.index_path.exists():
            return False
        try:
            with open(self.index_path, encoding="utf-8") as handle:
                raw = json.load(handle)
            self._index = {
                (item["collection"], item["id"]): _Entry(
                    rev=int(item["rev"]),
                    updated_at=as_utc(dt.datetime.fromisoformat(item["updated_at"])),
                    deleted=bool(item.get("deleted", False)),
                    collection=item["collection"],
                    record_id=item["id"],
                )
                for item in raw.get("entries", [])
            }
            self._next_rev = int(raw.get("next_rev", 1))
            return True
        except (OSError, ValueError, KeyError) as exc:
            log.warning("Index unreadable, rebuilding from records: %s", exc)
            return False

    def rebuild_index(self) -> None:
        """Reconstruct the index by reading every record.

        The record files carry their own rev, so this is lossless: cursors stay
        valid across a rebuild and clients do not have to resync.
        """
        index: dict[tuple[str, str], _Entry] = {}
        highest = 0
        if self.records_dir.exists():
            for path in self.records_dir.glob("*/*.json"):
                try:
                    with open(path, encoding="utf-8") as handle:
                        record = StoredRecord.from_json(json.load(handle))
                except (OSError, ValueError, KeyError) as exc:
                    log.warning("Skipping unreadable record %s: %s", path, exc)
                    continue
                index[(record.collection, record.record_id)] = _Entry(
                    rev=record.rev,
                    updated_at=record.updated_at,
                    deleted=record.deleted,
                    collection=record.collection,
                    record_id=record.record_id,
                )
                highest = max(highest, record.rev)
        self._index = index
        self._next_rev = highest + 1
        self._save_index()
        log.info("Rebuilt index: %d records, next rev %d", len(index), self._next_rev)

    # ------------------------------------------------------------ reading

    def current_rev(self) -> int:
        with self._lock:
            return self._next_rev - 1

    def get(self, collection: str, record_id: str) -> StoredRecord | None:
        try:
            path = self._record_path(collection, record_id)
        except UnsafeName:
            return None
        if not path.exists():
            return None
        try:
            with open(path, encoding="utf-8") as handle:
                return StoredRecord.from_json(json.load(handle))
        except (OSError, ValueError, KeyError) as exc:
            log.warning("Unreadable record %s: %s", path, exc)
            return None

    def get_many(
        self, keys: Iterable[tuple[str, str]]
    ) -> dict[tuple[str, str], StoredRecord]:
        found = {}
        for collection, record_id in keys:
            record = self.get(collection, record_id)
            if record is not None:
                found[(collection, record_id)] = record
        return found

    def changes_since(self, since: int, limit: int) -> tuple[list[StoredRecord], bool]:
        """Records with rev greater than `since`, oldest first.

        The index answers which ones qualify, so only the page actually being
        returned is read from disk.
        """
        with self._lock:
            pending = sorted(
                (entry for entry in self._index.values() if entry.rev > since),
                key=lambda entry: entry.rev,
            )
        has_more = len(pending) > limit
        records = []
        for entry in pending[:limit]:
            record = self.get(entry.collection, entry.record_id)
            if record is not None:
                records.append(record)
        return records, has_more

    def counts_by_collection(self) -> dict[str, int]:
        with self._lock:
            counts: dict[str, int] = {}
            for (collection, _), entry in self._index.items():
                if not entry.deleted:
                    counts[collection] = counts.get(collection, 0) + 1
            return counts

    # ------------------------------------------------------------ writing

    def put_many(self, records: list[StoredRecord], device_id: str | None) -> int:
        """Assign revisions and store. Returns the new head revision.

        Revisions come from one contiguous block so a single push lands as a
        range and a puller sees the batch whole.
        """
        if not records:
            return self.current_rev()

        with self._lock:
            base = self._next_rev
            self._next_rev += len(records)

            for offset, record in enumerate(records):
                record.rev = base + offset
                record.device_id = device_id
                # Written before the index, so a crash between the two leaves a
                # record the rebuild will find rather than an index entry
                # pointing at nothing.
                self._write_atomically(
                    self._record_path(record.collection, record.record_id),
                    record.to_json(),
                )
                self._index[(record.collection, record.record_id)] = _Entry(
                    rev=record.rev,
                    updated_at=record.updated_at,
                    deleted=record.deleted,
                    collection=record.collection,
                    record_id=record.record_id,
                )

            self._save_index()
            return self._next_rev - 1


_store: FileStore | None = None


def get_store() -> FileStore:
    if _store is None:
        raise RuntimeError("File store not initialised; call configure_store() first.")
    return _store


def configure_store(root: str | Path) -> FileStore:
    global _store
    _store = FileStore(root=Path(root))
    _store.open()
    return _store
