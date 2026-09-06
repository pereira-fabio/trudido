"""Sync protocol behaviour: cursors, last-write-wins, tombstones, auth."""
import datetime as dt

UTC = dt.timezone.utc


def iso(offset_seconds: int = 0) -> str:
    return (
        dt.datetime(2026, 1, 1, 12, 0, 0, tzinfo=UTC)
        + dt.timedelta(seconds=offset_seconds)
    ).isoformat()


def rec(rid, *, collection="todos", text="a task", at=0, deleted=False, payload=True):
    return {
        "collection": collection,
        "id": rid,
        "payload": {"id": rid, "text": text} if payload else None,
        "updated_at": iso(at),
        "deleted": deleted,
    }


def push(client, records, device="device-a"):
    r = client.post(
        "/api/v1/sync/changes", json={"device_id": device, "records": records}
    )
    assert r.status_code == 200, r.text
    return r.json()


def pull(client, since=0, limit=None):
    params = {"since": since}
    if limit:
        params["limit"] = limit
    r = client.get("/api/v1/sync/changes", params=params)
    assert r.status_code == 200, r.text
    return r.json()


# --------------------------------------------------------------- basics

def test_health_needs_no_token(client):
    assert client.get("/api/v1/health").json()["status"] == "ok"


def test_empty_pull_returns_caller_cursor(client):
    body = pull(client, since=7)
    assert body["records"] == []
    assert body["cursor"] == 7
    assert body["has_more"] is False


def test_push_then_pull_round_trip(client):
    result = push(client, [rec("t1"), rec("t2")])
    assert result["applied"] == 2
    assert result["rejected"] == []

    body = pull(client)
    assert [r["id"] for r in body["records"]] == ["t1", "t2"]
    assert body["records"][0]["payload"]["text"] == "a task"
    assert body["cursor"] == result["cursor"]


def test_pull_since_excludes_what_client_has(client):
    push(client, [rec("t1")])
    first = pull(client)
    push(client, [rec("t2")])
    body = pull(client, since=first["cursor"])
    assert [r["id"] for r in body["records"]] == ["t2"]


def test_paging_cursor_never_skips_records(client):
    push(client, [rec(f"t{i}") for i in range(10)])

    seen, cursor, guard = [], 0, 0
    while True:
        guard += 1
        assert guard < 20, "pagination did not terminate"
        body = pull(client, since=cursor, limit=3)
        seen.extend(r["id"] for r in body["records"])
        cursor = body["cursor"]
        if not body["has_more"]:
            break

    assert seen == [f"t{i}" for i in range(10)]
    assert len(seen) == len(set(seen)), "a record was returned twice"


# ------------------------------------------------- last-write-wins

def test_newer_edit_wins(client):
    push(client, [rec("t1", text="original", at=0)])
    result = push(client, [rec("t1", text="newer", at=60)], device="device-b")
    assert result["applied"] == 1
    assert pull(client)["records"][0]["payload"]["text"] == "newer"


def test_older_edit_is_rejected_and_server_copy_returned(client):
    push(client, [rec("t1", text="newer", at=60)])
    result = push(client, [rec("t1", text="stale", at=0)], device="device-b")

    assert result["applied"] == 0
    assert len(result["rejected"]) == 1
    rejection = result["rejected"][0]
    assert rejection["id"] == "t1"
    assert rejection["server_record"]["payload"]["text"] == "newer"
    # The loser must not have been written.
    assert pull(client)["records"][0]["payload"]["text"] == "newer"


def test_exact_tie_is_broken_deterministically(client):
    """Two devices resolving the same collision must reach the same answer."""
    push(client, [rec("t1", text="from-b", at=30)], device="device-b")
    result = push(client, [rec("t1", text="from-a", at=30)], device="device-a")

    # device-b > device-a, so the stored copy holds and the push is refused.
    assert result["applied"] == 0
    assert pull(client)["records"][0]["payload"]["text"] == "from-b"

    # And the reverse order reaches the identical state.
    result2 = push(client, [rec("t1", text="from-c", at=30)], device="device-c")
    assert result2["applied"] == 1
    assert pull(client)["records"][0]["payload"]["text"] == "from-c"


def test_rejection_does_not_consume_a_revision(client):
    push(client, [rec("t1", at=60)])
    before = pull(client)["cursor"]
    push(client, [rec("t1", at=0)], device="device-b")
    assert pull(client)["cursor"] == before


def test_mixed_batch_applies_the_good_and_rejects_the_stale(client):
    push(client, [rec("t1", text="newer", at=60)])
    result = push(
        client, [rec("t1", text="stale", at=0), rec("t2", text="fresh", at=90)],
        device="device-b",
    )
    assert result["applied"] == 1
    assert [r["id"] for r in result["rejected"]] == ["t1"]

    by_id = {r["id"]: r for r in pull(client)["records"]}
    assert by_id["t1"]["payload"]["text"] == "newer"
    assert by_id["t2"]["payload"]["text"] == "fresh"


# ------------------------------------------------------------ deletes

def test_soft_delete_keeps_payload_so_other_devices_show_a_bin(client):
    push(client, [rec("t1")])
    push(client, [{**rec("t1", at=60), "payload": {"id": "t1", "isDeleted": True}}])
    record = pull(client)["records"][0]
    assert record["deleted"] is False
    assert record["payload"]["isDeleted"] is True


def test_hard_delete_is_a_tombstone_with_no_payload(client):
    push(client, [rec("t1")])
    push(client, [rec("t1", at=60, deleted=True, payload=False)])
    record = pull(client)["records"][0]
    assert record["deleted"] is True
    assert record["payload"] is None


def test_tombstone_can_be_created_without_the_record_existing(client):
    """A device that deleted while offline may never have pushed the original."""
    result = push(client, [rec("gone", at=60, deleted=True, payload=False)])
    assert result["applied"] == 1
    assert pull(client)["records"][0]["deleted"] is True


# --------------------------------------------------------- collections

def test_collections_are_independent_namespaces(client):
    push(client, [rec("shared-id", collection="todos", text="task")])
    push(client, [rec("shared-id", collection="notes", text="note")])
    records = pull(client)["records"]
    assert len(records) == 2
    assert {r["collection"] for r in records} == {"todos", "notes"}


def test_status_counts_live_records_by_collection(client):
    push(client, [rec("t1"), rec("t2"), rec("n1", collection="notes")])
    push(client, [rec("t2", at=60, deleted=True, payload=False)])
    body = client.get("/api/v1/sync/status").json()
    assert body["records"] == {"todos": 1, "notes": 1}


# ---------------------------------------------------------------- auth

def test_token_is_enforced_when_configured(make_client):
    with make_client(token="secret") as c:
        assert c.get("/api/v1/health").status_code == 200

        c.headers.pop("X-Trudido-Token")
        assert c.get("/api/v1/sync/changes").status_code == 401

        c.headers["X-Trudido-Token"] = "wrong"
        assert c.get("/api/v1/sync/changes").status_code == 401

        c.headers["X-Trudido-Token"] = "secret"
        assert c.get("/api/v1/sync/changes").status_code == 200
        assert c.get("/api/v1/auth/check").json()["token_required"] is True


def test_no_token_configured_leaves_sync_open(client):
    assert client.get("/api/v1/sync/changes").status_code == 200
    assert client.get("/api/v1/auth/check").json()["token_required"] is False
