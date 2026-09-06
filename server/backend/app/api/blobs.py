"""Note attachments, addressed by content hash.

Photos, voice notes and video live outside the record store: they are large,
immutable, and shared between notes. Hashing the bytes means an attachment is
uploaded once no matter how many notes embed it, and a half-finished upload is
fixed by repeating it rather than by reconciling anything.

Each blob keeps its metadata in a small JSON file beside it, so the directory
is self-describing and survives being copied, snapshotted or restored without
needing a database to agree with it.
"""
import hashlib
import json
import logging
import os

from fastapi import APIRouter, Depends, File, HTTPException, Path, UploadFile, status
from fastapi.responses import FileResponse

from app.core.config import settings
from app.core.filestore import FileStore, get_store, utcnow
from app.core.security import require_token
from app.models.schemas import BlobInfo, BlobManifest

log = logging.getLogger(__name__)

router = APIRouter(prefix="/blobs", tags=["blobs"], dependencies=[Depends(require_token)])

_SHA256 = r"^[0-9a-f]{64}$"
_CHUNK = 1024 * 1024


def store() -> FileStore:
    return get_store()


def _blob_path(sha256: str):
    """Two-character fan-out, so one directory never holds every attachment."""
    return store().blobs_dir / sha256[:2] / sha256


def _meta_path(sha256: str):
    return _blob_path(sha256).with_suffix(".json")


def _read_meta(sha256: str) -> dict | None:
    path = _meta_path(sha256)
    if not path.exists():
        return None
    try:
        with open(path, encoding="utf-8") as handle:
            return json.load(handle)
    except (OSError, ValueError) as exc:
        log.warning("Unreadable blob metadata %s: %s", path, exc)
        return None


@router.get("/manifest", response_model=BlobManifest)
def manifest() -> BlobManifest:
    """Every hash the server holds, so a client can diff against its own."""
    blobs: list[BlobInfo] = []
    blobs_dir = store().blobs_dir
    if not blobs_dir.exists():
        return BlobManifest(blobs=blobs)

    for meta_file in blobs_dir.glob("*/*.json"):
        try:
            with open(meta_file, encoding="utf-8") as handle:
                meta = json.load(handle)
            blobs.append(
                BlobInfo(
                    sha256=meta["sha256"],
                    filename=meta["filename"],
                    size=int(meta["size"]),
                    mime=meta.get("mime"),
                )
            )
        except (OSError, ValueError, KeyError) as exc:
            log.warning("Skipping blob metadata %s: %s", meta_file, exc)
    return BlobManifest(blobs=blobs)


@router.head("/{sha256}")
def blob_exists(sha256: str = Path(pattern=_SHA256)):
    """Existence check, so a client can skip an upload without sending bytes."""
    if not _blob_path(sha256).exists():
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Unknown blob.")
    return {}


@router.put("/{sha256}", response_model=BlobInfo)
async def upload_blob(
    sha256: str = Path(pattern=_SHA256),
    file: UploadFile = File(...),
) -> BlobInfo:
    """Store an attachment under the hash of its bytes.

    Idempotent: re-uploading something already held is a no-op. The hash is
    recomputed here rather than trusted, so a corrupted transfer is refused
    instead of being served back to every other device.
    """
    target = _blob_path(sha256)
    existing = _read_meta(sha256)
    if existing is not None and target.exists():
        return BlobInfo(
            sha256=sha256,
            filename=existing["filename"],
            size=int(existing["size"]),
            mime=existing.get("mime"),
        )

    target.parent.mkdir(parents=True, exist_ok=True)
    # Written beside the target and renamed, so a failed upload can never be
    # mistaken for a complete one.
    tmp = f"{target}.part"
    digest = hashlib.sha256()
    size = 0
    limit = settings.MAX_BLOB_MB * 1024 * 1024

    try:
        with open(tmp, "wb") as out:
            while chunk := await file.read(_CHUNK):
                size += len(chunk)
                if size > limit:
                    raise HTTPException(
                        status_code=status.HTTP_413_REQUEST_ENTITY_TOO_LARGE,
                        detail=f"Attachment exceeds MAX_BLOB_MB ({settings.MAX_BLOB_MB} MB).",
                    )
                digest.update(chunk)
                out.write(chunk)

        actual = digest.hexdigest()
        if actual != sha256:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail=f"Content hash mismatch: declared {sha256}, received {actual}.",
            )
        os.replace(tmp, target)
    except HTTPException:
        if os.path.exists(tmp):
            os.remove(tmp)
        raise
    except OSError as exc:
        if os.path.exists(tmp):
            os.remove(tmp)
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail=f"Storage unavailable: {exc}",
        ) from exc

    meta = {
        "sha256": sha256,
        "filename": os.path.basename(file.filename or sha256),
        "size": size,
        "mime": file.content_type,
        "created_at": utcnow().isoformat(),
    }
    meta_tmp = f"{_meta_path(sha256)}.tmp"
    with open(meta_tmp, "w", encoding="utf-8") as handle:
        json.dump(meta, handle)
    os.replace(meta_tmp, _meta_path(sha256))

    log.info("stored blob %s (%d bytes)", sha256[:12], size)
    return BlobInfo(
        sha256=sha256, filename=meta["filename"], size=size, mime=meta["mime"]
    )


@router.get("/{sha256}")
def download_blob(sha256: str = Path(pattern=_SHA256)) -> FileResponse:
    path = _blob_path(sha256)
    meta = _read_meta(sha256)
    if meta is None or not path.exists():
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Unknown blob.")
    return FileResponse(
        path,
        media_type=meta.get("mime") or "application/octet-stream",
        filename=meta["filename"],
    )
