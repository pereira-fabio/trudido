"""Attachment storage: content addressing, integrity, idempotence."""
import hashlib
import io


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def upload(client, data: bytes, name="photo.jpg", digest=None, mime="image/jpeg"):
    return client.put(
        f"/api/v1/blobs/{digest or sha(data)}",
        files={"file": (name, io.BytesIO(data), mime)},
    )


def test_upload_then_download_returns_identical_bytes(client):
    data = b"\xff\xd8\xff\xe0 pretend jpeg " * 100
    r = upload(client, data)
    assert r.status_code == 200, r.text
    assert r.json()["sha256"] == sha(data)
    assert r.json()["size"] == len(data)

    got = client.get(f"/api/v1/blobs/{sha(data)}")
    assert got.status_code == 200
    assert got.content == data


def test_hash_mismatch_is_refused_and_nothing_is_stored(client):
    data = b"real content"
    wrong = sha(b"different content")
    r = upload(client, data, digest=wrong)
    assert r.status_code == 400
    assert "mismatch" in r.json()["detail"].lower()
    # The failed upload must not be downloadable or leave a partial file.
    assert client.get(f"/api/v1/blobs/{wrong}").status_code == 404


def test_reupload_is_idempotent(client):
    data = b"same bytes every time"
    first = upload(client, data)
    second = upload(client, data)
    assert first.status_code == second.status_code == 200
    assert first.json() == second.json()
    assert len(client.get("/api/v1/blobs/manifest").json()["blobs"]) == 1


def test_manifest_lets_a_client_diff_what_it_has(client):
    a, b = b"attachment one", b"attachment two"
    upload(client, a, name="a.png", mime="image/png")
    upload(client, b, name="b.png", mime="image/png")

    blobs = client.get("/api/v1/blobs/manifest").json()["blobs"]
    assert {x["sha256"] for x in blobs} == {sha(a), sha(b)}
    assert {x["filename"] for x in blobs} == {"a.png", "b.png"}


def test_head_reports_presence_without_transferring(client):
    data = b"voice note"
    assert client.head(f"/api/v1/blobs/{sha(data)}").status_code == 404
    upload(client, data, name="note.m4a", mime="audio/mp4")
    assert client.head(f"/api/v1/blobs/{sha(data)}").status_code == 200


def test_unknown_blob_is_a_404(client):
    assert client.get(f"/api/v1/blobs/{'0' * 64}").status_code == 404


def test_malformed_hash_is_rejected_by_validation(client):
    assert client.get("/api/v1/blobs/not-a-hash").status_code == 422


def test_oversized_upload_is_refused(make_client, monkeypatch):
    with make_client() as c:
        import app.core.config as config

        monkeypatch.setattr(config.settings, "MAX_BLOB_MB", 0)
        data = b"x" * 4096
        assert upload(c, data).status_code == 413


def test_blobs_require_the_token_when_one_is_set(make_client):
    with make_client(token="secret") as c:
        c.headers.pop("X-Trudido-Token")
        assert c.get("/api/v1/blobs/manifest").status_code == 401
