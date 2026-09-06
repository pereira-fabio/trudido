"""The file store itself: layout, index rebuilding, and name safety.

The protocol tests already prove behaviour is unchanged. These cover what is
new -- that the data on disk is what it claims to be, that the index really is
a disposable cache, and that a record id cannot escape the store directory.
"""
import datetime as dt
import json
import sqlite3
from pathlib import Path

import pytest

UTC = dt.timezone.utc


def iso(seconds: int = 0) -> str:
    return (dt.datetime(2026, 1, 1, tzinfo=UTC) + dt.timedelta(seconds=seconds)).isoformat()


def push(client, records, device="device-a"):
    r = client.post("/api/v1/sync/changes", json={"device_id": device, "records": records})
    assert r.status_code == 200, r.text
    return r.json()


def rec(rid, collection="todos", text="a task", at=0):
    return {
        "collection": collection,
        "id": rid,
        "payload": {"id": rid, "text": text},
        "updated_at": iso(at),
        "deleted": False,
    }


def store_root(client) -> Path:
    return Path(client.get("/api/v1/sync/status").json()["storage"])


# --------------------------------------------------------------- layout

def test_records_are_readable_json_files_on_disk(client):
    """The point of the exercise: data you can open without the server."""
    push(client, [rec("t1", text="Buy oat milk"), rec("n1", collection="notes")])

    root = store_root(client)
    path = root / "records" / "todos" / "t1.json"
    assert path.exists(), f"expected a file at {path}"

    with open(path, encoding="utf-8") as handle:
        stored = json.load(handle)
    assert stored["payload"]["text"] == "Buy oat milk"
    assert stored["collection"] == "todos"
    assert stored["rev"] >= 1

    assert (root / "records" / "notes" / "n1.json").exists()


def test_a_record_is_one_file_however_often_it_changes(client):
    for i in range(5):
        push(client, [rec("t1", text=f"version {i}", at=i * 60)])

    files = list((store_root(client) / "records" / "todos").glob("*.json"))
    assert len(files) == 1

    with open(files[0], encoding="utf-8") as handle:
        assert json.load(handle)["payload"]["text"] == "version 4"


def test_no_stray_temporary_files_are_left_behind(client):
    push(client, [rec(f"t{i}") for i in range(5)])
    root = store_root(client)
    assert list(root.rglob("*.tmp")) == []
    assert list(root.rglob("*.part")) == []


# ------------------------------------------------------- index as cache

def test_index_is_rebuilt_from_records_when_deleted(make_client, tmp_path):
    """The index must be disposable: the record files are the source of truth."""
    with make_client() as client:
        push(client, [rec("t1"), rec("t2"), rec("n1", collection="notes")])
        before = client.get("/api/v1/sync/changes?since=0").json()
        root = store_root(client)

    index = root / "index.json"
    assert index.exists()
    index.unlink()

    # A fresh app over the same directory has to reconstruct it.
    with make_client() as client:
        after = client.get("/api/v1/sync/changes?since=0").json()

    assert [r["id"] for r in after["records"]] == [r["id"] for r in before["records"]]
    assert after["cursor"] == before["cursor"], "cursors must survive a rebuild"


def test_a_corrupt_index_does_not_lose_records(make_client):
    with make_client() as client:
        push(client, [rec("t1"), rec("t2")])
        root = store_root(client)

    (root / "index.json").write_text("{ this is not json", encoding="utf-8")

    with make_client() as client:
        records = client.get("/api/v1/sync/changes?since=0").json()["records"]
    assert {r["id"] for r in records} == {"t1", "t2"}


def test_revisions_survive_a_rebuild_so_clients_need_not_resync(make_client):
    with make_client() as client:
        push(client, [rec("t1")])
        push(client, [rec("t2")])
        cursor = client.get("/api/v1/sync/changes?since=0").json()["cursor"]
        root = store_root(client)

    (root / "index.json").unlink()

    with make_client() as client:
        # A client sitting at the old cursor should see nothing new, not
        # everything again.
        page = client.get(f"/api/v1/sync/changes?since={cursor}").json()
    assert page["records"] == []


# ---------------------------------------------------------- name safety

@pytest.mark.parametrize(
    "bad_id",
    ["../escape", "..", ".", "with/slash", "back\\slash", "", "a" * 200],
)
def test_record_ids_cannot_escape_the_store(client, bad_id):
    response = client.post(
        "/api/v1/sync/changes",
        json={
            "device_id": "d",
            "records": [{
                "collection": "todos", "id": bad_id, "payload": {},
                "updated_at": iso(), "deleted": False,
            }],
        },
    )
    assert response.status_code in (400, 422), (
        f"id {bad_id!r} was not rejected: {response.status_code}"
    )


def test_collection_names_cannot_escape_the_store(client):
    response = client.post(
        "/api/v1/sync/changes",
        json={
            "device_id": "d",
            "records": [{
                "collection": "../../etc", "id": "x", "payload": {},
                "updated_at": iso(), "deleted": False,
            }],
        },
    )
    assert response.status_code in (400, 422)


# ------------------------------------------------------------ blobs

def test_blob_metadata_sits_beside_the_blob(client):
    import hashlib, io

    data = b"an attachment"
    digest = hashlib.sha256(data).hexdigest()
    client.put(
        f"/api/v1/blobs/{digest}",
        files={"file": ("photo.jpg", io.BytesIO(data), "image/jpeg")},
    )

    blob = store_root(client) / "blobs" / digest[:2] / digest
    assert blob.exists()
    assert blob.read_bytes() == data

    with open(blob.with_suffix(".json"), encoding="utf-8") as handle:
        meta = json.load(handle)
    assert meta["filename"] == "photo.jpg"
    assert meta["size"] == len(data)


# -------------------------------------------------- SQLite migration

def test_existing_sqlite_data_is_imported_once(make_client, tmp_path):
    """Anyone already syncing has real data in the old database; switching the
    storage engine must not start from empty."""
    database = tmp_path / "old.db"
    connection = sqlite3.connect(database)
    connection.execute(
        "CREATE TABLE records (pk INTEGER PRIMARY KEY, collection TEXT,"
        " record_id TEXT, payload TEXT, updated_at TEXT, deleted INTEGER,"
        " rev INTEGER, device_id TEXT, user_id TEXT, server_updated_at TEXT)"
    )
    connection.executemany(
        "INSERT INTO records (collection, record_id, payload, updated_at,"
        " deleted, rev, device_id) VALUES (?,?,?,?,?,?,?)",
        [
            ("todos", "old1", json.dumps({"text": "from sqlite"}), iso(0), 0, 1, "phone"),
            ("notes", "old2", json.dumps({"title": "also from sqlite"}), iso(60), 0, 2, "phone"),
        ],
    )
    connection.commit()
    connection.close()

    with make_client(database_url=f"sqlite:///{database}") as client:
        records = client.get("/api/v1/sync/changes?since=0").json()["records"]
        assert {r["id"] for r in records} == {"old1", "old2"}
        # Revisions are preserved, so existing client cursors stay valid.
        assert {r["rev"] for r in records} == {1, 2}
        assert (store_root(client) / "migrated-from-sqlite.json").exists()
        # And the old database is left alone as a fallback.
        assert database.exists()
