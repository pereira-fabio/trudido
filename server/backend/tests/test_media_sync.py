"""The client's attachment reconciliation, against the real blob API.

A Python transcription of MediaSync.run() in lib/services/sync/media_sync.dart,
plus MediaRef.referencedIn's scan. The Dart cannot be run here, and the parts
worth checking are the ones that only show up with two devices: that an
attachment uploads once, that a device missing it fetches it, and that the
bytes survive.
"""
import hashlib
import io
import json

import pytest

# Mirrors MediaRef._reference. Matches both a portable trudido://media/<name>
# reference and a legacy absolute path, since both end in media/<name>.
import re

REFERENCE = re.compile(r"media/([A-Za-z0-9._\-]+)")


def referenced_in(content: str) -> set[str]:
    return {m.group(1) for m in REFERENCE.finditer(content) if m.group(1)}


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def quill_note(*paths: str) -> str:
    """Content shaped like a real Quill delta: embeds are JSON inside JSON."""
    ops = []
    for path in paths:
        media = json.dumps({"type": "image", "path": path})
        ops.append({"insert": {"custom": json.dumps({"media": media})}})
    ops.append({"insert": "some text\n"})
    return json.dumps(ops)


class Device:
    """Local attachment store plus the reconciliation pass."""

    def __init__(self, client):
        self.client = client
        self.files: dict[str, bytes] = {}
        self.notes: list[str] = []

    def manifest(self):
        blobs = self.client.get("/api/v1/blobs/manifest").json()["blobs"]
        hashes = {b["sha256"] for b in blobs}
        by_name: dict[str, str] = {}
        for blob in blobs:
            by_name.setdefault(blob["filename"], blob["sha256"])
        return hashes, by_name

    def reconcile(self):
        referenced = set()
        for note in self.notes:
            referenced |= referenced_in(note)
        if not referenced:
            return 0, 0

        hashes, by_name = self.manifest()
        uploaded = downloaded = 0

        for name in sorted(referenced):
            local = self.files.get(name)
            if local is not None:
                digest = sha(local)
                if digest in hashes:
                    continue
                r = self.client.put(
                    f"/api/v1/blobs/{digest}",
                    files={"file": (name, io.BytesIO(local), "image/jpeg")},
                )
                assert r.status_code == 200, r.text
                uploaded += 1
                continue

            digest = by_name.get(name)
            if digest is None:
                continue  # false positive, or another device has not sent it yet
            got = self.client.get(f"/api/v1/blobs/{digest}")
            assert got.status_code == 200
            self.files[name] = got.content
            downloaded += 1

        return uploaded, downloaded


@pytest.fixture
def devices(client):
    return Device(client), Device(client)


# ------------------------------------------------------- the scan

def test_scan_finds_portable_references():
    content = quill_note("trudido://media/image_1757.jpg")
    assert referenced_in(content) == {"image_1757.jpg"}


def test_scan_finds_legacy_absolute_paths():
    """Notes written before portable refs existed must still sync their media."""
    content = quill_note(
        "/data/user/0/com.trudido.app/app_flutter/media/voice_1757.m4a"
    )
    assert referenced_in(content) == {"voice_1757.m4a"}


def test_scan_handles_both_forms_in_one_note():
    content = quill_note(
        "trudido://media/new_1.jpg",
        "/data/user/0/com.trudido.app/app_flutter/media/old_2.jpg",
    )
    assert referenced_in(content) == {"new_1.jpg", "old_2.jpg"}


def test_scan_of_a_note_with_no_media_is_empty():
    assert referenced_in(json.dumps([{"insert": "just words\n"}])) == set()


# --------------------------------------------- reconciliation

def test_attachment_reaches_the_second_device_intact(devices):
    phone, laptop = devices
    picture = b"\xff\xd8\xff\xe0" + b"pretend jpeg " * 500

    phone.files["image_1.jpg"] = picture
    phone.notes.append(quill_note("trudido://media/image_1.jpg"))
    assert phone.reconcile() == (1, 0)

    # The note syncs through the record protocol; the file follows here.
    laptop.notes.append(quill_note("trudido://media/image_1.jpg"))
    assert laptop.reconcile() == (0, 1)
    assert laptop.files["image_1.jpg"] == picture


def test_second_pass_transfers_nothing(devices):
    phone, _ = devices
    phone.files["image_1.jpg"] = b"stable bytes"
    phone.notes.append(quill_note("trudido://media/image_1.jpg"))

    assert phone.reconcile() == (1, 0)
    assert phone.reconcile() == (0, 0)


def test_same_image_in_two_notes_uploads_once(devices):
    phone, _ = devices
    picture = b"one image, two notes"
    phone.files["shared.jpg"] = picture
    phone.notes.append(quill_note("trudido://media/shared.jpg"))
    phone.notes.append(quill_note("trudido://media/shared.jpg"))

    assert phone.reconcile() == (1, 0)
    assert len(phone.client.get("/api/v1/blobs/manifest").json()["blobs"]) == 1


def test_identical_bytes_under_two_names_store_once(devices):
    """Content addressing: the server keys on bytes, not filenames."""
    phone, _ = devices
    picture = b"identical content"
    phone.files["a.jpg"] = picture
    phone.files["b.jpg"] = picture
    phone.notes.append(quill_note("trudido://media/a.jpg", "trudido://media/b.jpg"))

    phone.reconcile()
    assert len(phone.client.get("/api/v1/blobs/manifest").json()["blobs"]) == 1


def test_legacy_note_from_another_device_still_fetches(devices):
    """The path in it is another device's absolute path and cannot be used as
    one; only the filename is meaningful."""
    phone, laptop = devices
    audio = b"a voice note"
    phone.files["voice_9.m4a"] = audio
    phone.notes.append(quill_note("trudido://media/voice_9.m4a"))
    phone.reconcile()

    laptop.notes.append(
        quill_note("/data/user/0/com.trudido.app/app_flutter/media/voice_9.m4a")
    )
    assert laptop.reconcile() == (0, 1)
    assert laptop.files["voice_9.m4a"] == audio


def test_reference_the_server_does_not_have_is_skipped(devices):
    """A false positive from the loose scan, or a file not yet uploaded.
    Neither should raise."""
    _, laptop = devices
    laptop.notes.append(quill_note("trudido://media/never_existed.jpg"))
    assert laptop.reconcile() == (0, 0)


def test_a_device_that_missed_an_upload_recovers_on_the_next_pass(devices):
    """Reconciliation is self-healing: nothing records that work is outstanding,
    so a failed pass is repaired by simply running again."""
    phone, laptop = devices
    phone.files["late.jpg"] = b"uploaded late"
    phone.notes.append(quill_note("trudido://media/late.jpg"))

    laptop.notes.append(quill_note("trudido://media/late.jpg"))
    assert laptop.reconcile() == (0, 0)  # nothing on the server yet

    phone.reconcile()
    assert laptop.reconcile() == (0, 1)  # and now there is
    assert laptop.files["late.jpg"] == b"uploaded late"
