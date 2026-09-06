"""The client's sync algorithm, exercised against the real server.

This is a Python transcription of SyncService._run() in
lib/services/sync/sync_service.dart -- pull loop, drain outbox, push, adopt
rejections, pull again. It exists because the Dart cannot be compiled or run
in CI here, and because the protocol has failure modes that only appear when
two devices interleave: convergence, and edits that are made offline and have
therefore never been offered to the server.

It caught one real bug, which case 9 now guards: pull ran before push, so a
record arriving from the server silently overwrote an unsent local edit before
the push could offer it. If you change the Dart, change this to match.
"""
import datetime as dt

import pytest

UTC = dt.timezone.utc


def iso(seconds: int) -> str:
    return (dt.datetime(2026, 1, 1, tzinfo=UTC) + dt.timedelta(seconds=seconds)).isoformat()


def _at(value: str) -> dt.datetime:
    return dt.datetime.fromisoformat(value.replace("Z", "+00:00"))


class Device:
    """One installation: local store, outbox and cursor, as the app holds them."""

    def __init__(self, name, client):
        self.name = name
        self.client = client
        self.store = {}
        self.outbox = {}
        self.cursor = 0
        self.note_history = []

    # -- local edits, i.e. what the StorageService hooks record --

    def edit(self, collection, rid, payload, at):
        self.store[(collection, rid)] = {"payload": payload, "updated_at": at}
        self.outbox[(collection, rid)] = {"op": "upsert", "updated_at": at}

    def hard_delete(self, collection, rid, at):
        self.store.pop((collection, rid), None)
        self.outbox[(collection, rid)] = {"op": "delete", "updated_at": at}

    # -- SyncRepositoryBridge.applyRemote --

    def apply_remote(self, rec):
        key = (rec["collection"], rec["id"])
        if rec["deleted"]:
            self.store.pop(key, None)
            return
        existing = self.store.get(key)
        if rec["collection"] == "notes" and existing and existing["payload"] != rec["payload"]:
            # A clobbered note keeps its previous text in note history.
            self.note_history.append((rec["id"], existing["payload"]))
        self.store[key] = {"payload": rec["payload"], "updated_at": rec["updated_at"]}

    # -- SyncService._applyPulled --

    def apply_pulled(self, rec):
        key = (rec["collection"], rec["id"])
        pending = self.outbox.get(key)
        if pending and _at(pending["updated_at"]) > _at(rec["updated_at"]):
            # An unsent local edit that is newer must not be overwritten by the
            # pull that precedes the push carrying it.
            return False, False
        self.apply_remote(rec)
        if pending:
            del self.outbox[key]
            return True, True
        return True, False

    def pull_loop(self, echoes=frozenset()):
        applied = superseded = guard = 0
        while True:
            guard += 1
            assert guard < 1000, "pull did not terminate"
            page = self.client.get(f"/api/v1/sync/changes?since={self.cursor}").json()
            for rec in page["records"]:
                did, sup = self.apply_pulled(rec)
                # Records this device just pushed come back on the drain pass;
                # counting them as received would be a lie.
                if did and (rec["collection"], rec["id"]) not in echoes:
                    applied += 1
                superseded += sup
            self.cursor = page["cursor"]
            if not page["has_more"]:
                return applied, superseded

    def sync(self):
        pulled, conflicts = self.pull_loop()
        pushed = 0
        echoes = set()

        entries = list(self.outbox.items())
        if entries:
            records = []
            for (collection, rid), meta in entries:
                local = None if meta["op"] == "delete" else self.store.get((collection, rid))
                if local is None:
                    records.append({
                        "collection": collection, "id": rid, "payload": None,
                        "updated_at": meta["updated_at"], "deleted": True,
                    })
                else:
                    records.append({
                        "collection": collection, "id": rid,
                        "payload": local["payload"],
                        "updated_at": local["updated_at"], "deleted": False,
                    })

            echoes = {(r["collection"], r["id"]) for r in records}
            result = self.client.post(
                "/api/v1/sync/changes",
                json={"device_id": self.name, "records": records},
            ).json()
            pushed = result["applied"]
            conflicts += len(result["rejected"])
            for rejection in result["rejected"]:
                if rejection.get("server_record"):
                    self.apply_remote(rejection["server_record"])

            self.outbox.clear()
            more, superseded = self.pull_loop(echoes)
            pulled += more
            conflicts += superseded

        return pulled, pushed, conflicts


@pytest.fixture
def devices(client):
    return Device("phone", client), Device("laptop", client)


def test_first_sync_uploads_and_second_device_receives(devices):
    phone, laptop = devices
    phone.edit("todos", "t1", {"text": "Buy milk"}, iso(0))
    phone.edit("notes", "n1", {"content": "shopping list"}, iso(0))
    assert phone.sync() == (0, 2, 0)

    assert laptop.sync() == (2, 0, 0)
    assert laptop.store == phone.store


def test_resync_with_no_changes_is_a_no_op(devices):
    phone, laptop = devices
    phone.edit("todos", "t1", {"text": "a"}, iso(0))
    phone.sync()
    laptop.sync()

    assert phone.sync() == (0, 0, 0)
    assert laptop.sync() == (0, 0, 0)


def test_older_offline_edit_loses_and_is_reported(devices):
    phone, laptop = devices
    phone.edit("todos", "t1", {"text": "original"}, iso(0))
    phone.sync()
    laptop.sync()

    phone.edit("todos", "t1", {"text": "phone version"}, iso(100))
    laptop.edit("todos", "t1", {"text": "laptop version"}, iso(200))

    laptop.sync()
    pulled, pushed, conflicts = phone.sync()

    # Resolved during the pull, so nothing is pushed -- but the user is still
    # told an edit of theirs was overruled.
    assert conflicts == 1
    assert pushed == 0
    assert phone.store[("todos", "t1")]["payload"]["text"] == "laptop version"
    assert phone.store == laptop.store


def test_newer_offline_edit_survives_the_pull_that_precedes_the_push(devices):
    """The regression this suite exists for.

    Pull runs before push. A record arriving for something edited locally but
    not yet sent must not overwrite that edit, or the work is gone before the
    push that would have carried it.
    """
    phone, laptop = devices
    laptop.edit("todos", "t1", {"text": "laptop older"}, iso(1000))
    laptop.sync()

    phone.edit("todos", "t1", {"text": "phone newer"}, iso(2000))
    _, pushed, _ = phone.sync()

    assert phone.store[("todos", "t1")]["payload"]["text"] == "phone newer"
    assert pushed == 1

    laptop.sync()
    assert laptop.store[("todos", "t1")]["payload"]["text"] == "phone newer"


def test_losing_note_version_is_kept_in_history(devices):
    phone, laptop = devices
    phone.edit("notes", "n1", {"content": "original"}, iso(0))
    phone.sync()
    laptop.sync()

    phone.edit("notes", "n1", {"content": "phone text"}, iso(300))
    laptop.edit("notes", "n1", {"content": "laptop text"}, iso(400))
    laptop.sync()
    phone.sync()

    assert phone.store[("notes", "n1")]["payload"]["content"] == "laptop text"
    assert ("n1", {"content": "phone text"}) in phone.note_history


def test_hard_delete_propagates(devices):
    phone, laptop = devices
    phone.edit("todos", "t1", {"text": "doomed"}, iso(0))
    phone.sync()
    laptop.sync()
    assert ("todos", "t1") in laptop.store

    phone.hard_delete("todos", "t1", iso(100))
    phone.sync()
    laptop.sync()
    assert ("todos", "t1") not in laptop.store


def test_delete_racing_an_edit_still_converges(devices):
    phone, laptop = devices
    phone.edit("todos", "t1", {"text": "contested"}, iso(0))
    phone.sync()
    laptop.sync()

    phone.hard_delete("todos", "t1", iso(3000))
    laptop.edit("todos", "t1", {"text": "edited after delete"}, iso(3100))

    for _ in range(2):
        phone.sync()
        laptop.sync()

    assert phone.store.get(("todos", "t1")) == laptop.store.get(("todos", "t1"))


def test_interleaved_edits_converge(devices):
    phone, laptop = devices
    for i in range(5):
        phone.edit("todos", f"p{i}", {"text": f"phone {i}"}, iso(600 + i))
        laptop.edit("todos", f"l{i}", {"text": f"laptop {i}"}, iso(600 + i))

    phone.sync()
    laptop.sync()
    phone.sync()

    assert phone.store == laptop.store
    assert phone.cursor == laptop.cursor


def test_new_device_reconstructs_full_state(devices, client):
    phone, laptop = devices
    for i in range(4):
        phone.edit("todos", f"t{i}", {"text": f"task {i}"}, iso(i))
    phone.edit("notes", "n1", {"content": "a note"}, iso(10))
    phone.hard_delete("todos", "t0", iso(20))
    phone.sync()

    tablet = Device("tablet", client)
    tablet.sync()

    assert tablet.store == phone.store
    assert ("todos", "t0") not in tablet.store
