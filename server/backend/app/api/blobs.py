"""Note attachments, addressed by content hash.

Photos, voice notes and video live outside the record store: they are large,
immutable, and shared between notes. Hashing the bytes means an attachment is
uploaded once no matter how many notes embed it, and a half-finished upload is
fixed by repeating it rather than by reconciling anything.
"""
import hashlib
import logging
import os

from fastapi import APIRouter, Depends, File, HTTPException, Path, UploadFile, status
from fastapi.responses import FileResponse
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.core.config import settings
from app.core.database import get_db
from app.core.security import require_token
from app.models.models import Blob
from app.models.schemas import BlobInfo, BlobManifest

log = logging.getLogger(__name__)

router = APIRouter(prefix="/blobs", tags=["blobs"], dependencies=[Depends(require_token)])

_SHA256 = r"^[0-9a-f]{64}$"
_CHUNK = 1024 * 1024


def _blob_path(sha256: str) -> str:
    """Two-character fan-out, so one directory never holds every attachment."""
    return os.path.join(settings.BLOB_DIR, sha256[:2], sha256)


@router.get("/manifest", response_model=BlobManifest)
def manifest(db: Session = Depends(get_db)) -> BlobManifest:
    """Every hash the server holds, so a client can diff against its own."""
    rows = db.execute(select(Blob)).scalars().all()
    return BlobManifest(
        blobs=[
            BlobInfo(sha256=b.sha256, filename=b.filename, size=b.size, mime=b.mime)
            for b in rows
        ]
    )


@router.head("/{sha256}")
def blob_exists(
    sha256: str = Path(pattern=_SHA256),
    db: Session = Depends(get_db),
):
    """Existence check, so a client can skip an upload without sending bytes."""
    if db.get(Blob, sha256) is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Unknown blob.")
    return {}


@router.put("/{sha256}", response_model=BlobInfo)
async def upload_blob(
    sha256: str = Path(pattern=_SHA256),
    file: UploadFile = File(...),
    db: Session = Depends(get_db),
) -> BlobInfo:
    """Store an attachment under the hash of its bytes.

    Idempotent: re-uploading something already held is a no-op. The hash is
    recomputed here rather than trusted, so a corrupted transfer is refused
    instead of being served back to every other device.
    """
    existing = db.get(Blob, sha256)
    if existing is not None and os.path.exists(_blob_path(sha256)):
        return BlobInfo(
            sha256=existing.sha256,
            filename=existing.filename,
            size=existing.size,
            mime=existing.mime,
        )

    target = _blob_path(sha256)
    os.makedirs(os.path.dirname(target), exist_ok=True)
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
    except Exception:
        if os.path.exists(tmp):
            os.remove(tmp)
        raise

    record = Blob(
        sha256=sha256,
        filename=os.path.basename(file.filename or sha256),
        size=size,
        mime=file.content_type,
    )
    db.merge(record)
    db.commit()
    log.info("stored blob %s (%d bytes)", sha256[:12], size)
    return BlobInfo(sha256=sha256, filename=record.filename, size=size, mime=record.mime)


@router.get("/{sha256}")
def download_blob(
    sha256: str = Path(pattern=_SHA256),
    db: Session = Depends(get_db),
) -> FileResponse:
    record = db.get(Blob, sha256)
    path = _blob_path(sha256)
    if record is None or not os.path.exists(path):
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Unknown blob.")
    return FileResponse(
        path,
        media_type=record.mime or "application/octet-stream",
        filename=record.filename,
    )
