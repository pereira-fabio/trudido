"""Pull and push.

The protocol is a cursor over a server-assigned revision. A client remembers
the highest rev it has seen, asks for everything after it, then offers its own
changes. There is no session and no locking: a client that disappears mid-sync
simply resumes from its old cursor and re-sends.

Storage is plain files (see core/filestore.py), so the whole store can live on
a NAS share. Nothing about the wire format depends on that.
"""
import datetime as dt
import logging

from fastapi import APIRouter, Depends, HTTPException, Query, status

from app.core.config import settings
from app.core.filestore import FileStore, StoredRecord, UnsafeName, as_utc, get_store
from app.core.security import require_token
from app.models.schemas import (
    PullResponse,
    PushRequest,
    PushResponse,
    RecordOut,
    Rejection,
)

log = logging.getLogger(__name__)

router = APIRouter(prefix="/sync", tags=["sync"], dependencies=[Depends(require_token)])


def store() -> FileStore:
    return get_store()


def _to_out(record: StoredRecord) -> RecordOut:
    return RecordOut(
        collection=record.collection,
        id=record.record_id,
        payload=record.payload,
        updated_at=record.updated_at,
        deleted=record.deleted,
        rev=record.rev,
    )


@router.get("/changes", response_model=PullResponse)
def pull_changes(
    since: int = Query(0, ge=0, description="Highest rev the client already has"),
    limit: int | None = Query(None, ge=1, le=5000),
) -> PullResponse:
    """Everything that changed after `since`, oldest first."""
    page = limit or settings.SYNC_PAGE_SIZE
    try:
        records, has_more = store().changes_since(since, page)
    except OSError as exc:
        # A soft-mounted share fails rather than hangs when it is unreachable.
        # Say so plainly; the client keeps its cursor and retries next sync.
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail=f"Storage unavailable: {exc}",
        ) from exc

    # The cursor is the last row actually returned -- never the global head, or
    # a paged client would skip everything it did not receive.
    cursor = records[-1].rev if records else since
    return PullResponse(
        records=[_to_out(r) for r in records], cursor=cursor, has_more=has_more
    )


@router.post("/changes", response_model=PushResponse)
def push_changes(body: PushRequest) -> PushResponse:
    """Apply client changes under last-write-wins.

    A record is rejected when the stored copy has a strictly later
    `updated_at`. Exact ties are broken on device_id so that two devices
    resolving the same collision independently reach the same answer.
    """
    file_store = store()

    if not body.records:
        return PushResponse(cursor=file_store.current_rev(), applied=0, rejected=[])

    try:
        existing = file_store.get_many(
            {(r.collection, r.id) for r in body.records}
        )
    except OSError as exc:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail=f"Storage unavailable: {exc}",
        ) from exc

    rejected: list[Rejection] = []
    to_apply: list[StoredRecord] = []

    for item in body.records:
        current = existing.get((item.collection, item.id))
        incoming_at = as_utc(item.updated_at)

        if current is not None:
            current_at = as_utc(current.updated_at)
            if current_at > incoming_at or (
                current_at == incoming_at
                and (current.device_id or "") > body.device_id
            ):
                rejected.append(
                    Rejection(
                        collection=item.collection,
                        id=item.id,
                        server_record=_to_out(current),
                    )
                )
                continue

        to_apply.append(
            StoredRecord(
                collection=item.collection,
                record_id=item.id,
                payload=item.payload,
                updated_at=incoming_at,
                deleted=item.deleted,
                # Replaced with the real revision when it is stored.
                rev=0,
            )
        )

    if not to_apply:
        return PushResponse(
            cursor=file_store.current_rev(), applied=0, rejected=rejected
        )

    try:
        cursor = file_store.put_many(to_apply, body.device_id)
    except UnsafeName as exc:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST, detail=str(exc)
        ) from exc
    except OSError as exc:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail=f"Storage unavailable: {exc}",
        ) from exc

    log.info(
        "push from %s: %d applied, %d rejected",
        body.device_id,
        len(to_apply),
        len(rejected),
    )
    return PushResponse(cursor=cursor, applied=len(to_apply), rejected=rejected)


@router.get("/status")
def sync_status() -> dict:
    """Cheap overview for the app's sync settings screen."""
    file_store = store()
    return {
        "cursor": file_store.current_rev(),
        "records": file_store.counts_by_collection(),
        "storage": str(file_store.root),
    }
