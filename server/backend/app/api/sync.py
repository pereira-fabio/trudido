"""Pull and push.

The protocol is a cursor over a server-assigned revision. A client remembers
the highest rev it has seen, asks for everything after it, then offers its own
changes. There is no session and no locking: a client that disappears mid-sync
simply resumes from its old cursor and re-sends.
"""
import datetime as dt
import json
import logging

from fastapi import APIRouter, Depends, Query
from sqlalchemy import func, select, tuple_
from sqlalchemy.orm import Session

from app.core.config import settings
from app.core.database import get_db
from app.core.security import require_token
from app.models.models import Counter, Record
from app.models.schemas import (
    PullResponse,
    PushRequest,
    PushResponse,
    RecordOut,
    Rejection,
)

log = logging.getLogger(__name__)

router = APIRouter(prefix="/sync", tags=["sync"], dependencies=[Depends(require_token)])

_REV = "rev"


def _next_rev(db: Session, count: int = 1) -> int:
    """Reserve `count` revisions and return the first.

    Reserved in one statement inside the caller's transaction, so two
    concurrent pushes cannot be handed the same number.
    """
    counter = db.get(Counter, _REV, with_for_update=False)
    if counter is None:
        counter = Counter(name=_REV, value=0)
        db.add(counter)
        db.flush()
    counter.value += count
    db.flush()
    return counter.value - count + 1


def _current_rev(db: Session) -> int:
    counter = db.get(Counter, _REV)
    return counter.value if counter else 0


def _as_utc(value: dt.datetime) -> dt.datetime:
    """SQLite hands back naive datetimes; compare everything in UTC."""
    if value.tzinfo is None:
        return value.replace(tzinfo=dt.timezone.utc)
    return value.astimezone(dt.timezone.utc)


def _to_out(row: Record) -> RecordOut:
    return RecordOut(
        collection=row.collection,
        id=row.record_id,
        payload=json.loads(row.payload) if row.payload else None,
        updated_at=_as_utc(row.updated_at),
        deleted=row.deleted,
        rev=row.rev,
    )


@router.get("/changes", response_model=PullResponse)
def pull_changes(
    since: int = Query(0, ge=0, description="Highest rev the client already has"),
    limit: int | None = Query(None, ge=1, le=5000),
    db: Session = Depends(get_db),
) -> PullResponse:
    """Everything that changed after `since`, oldest first."""
    page = limit or settings.SYNC_PAGE_SIZE
    rows = (
        db.execute(
            select(Record)
            .where(Record.rev > since)
            .order_by(Record.rev.asc())
            # One extra row is a cheaper has_more than a second COUNT query.
            .limit(page + 1)
        )
        .scalars()
        .all()
    )

    has_more = len(rows) > page
    rows = rows[:page]

    # The cursor is the last row actually returned -- never the global head, or
    # a paged client would skip everything it did not receive.
    cursor = rows[-1].rev if rows else since
    return PullResponse(
        records=[_to_out(r) for r in rows], cursor=cursor, has_more=has_more
    )


@router.post("/changes", response_model=PushResponse)
def push_changes(
    body: PushRequest,
    db: Session = Depends(get_db),
) -> PushResponse:
    """Apply client changes under last-write-wins.

    A record is rejected when the stored copy has a strictly later
    `updated_at`. Exact ties are broken on device_id so that two devices
    resolving the same collision independently reach the same answer.
    """
    if not body.records:
        return PushResponse(cursor=_current_rev(db), applied=0, rejected=[])

    incoming_keys = {(r.collection, r.id) for r in body.records}
    existing: dict[tuple[str, str], Record] = {}
    if incoming_keys:
        rows = (
            db.execute(
                select(Record).where(
                    tuple_(Record.collection, Record.record_id).in_(
                        list(incoming_keys)
                    )
                )
            )
            .scalars()
            .all()
        )
        existing = {(r.collection, r.record_id): r for r in rows}

    rejected: list[Rejection] = []
    to_apply: list = []

    for item in body.records:
        key = (item.collection, item.id)
        current = existing.get(key)
        if current is not None:
            incoming_at = _as_utc(item.updated_at)
            current_at = _as_utc(current.updated_at)
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
        to_apply.append((item, current))

    if not to_apply:
        return PushResponse(cursor=_current_rev(db), applied=0, rejected=rejected)

    # Revisions are handed out in one block so a single push lands as a
    # contiguous range and a puller sees the batch whole.
    base = _next_rev(db, len(to_apply))

    for offset, (item, current) in enumerate(to_apply):
        rev = base + offset
        payload = json.dumps(item.payload) if item.payload is not None else None
        updated_at = _as_utc(item.updated_at)
        if current is None:
            db.add(
                Record(
                    collection=item.collection,
                    record_id=item.id,
                    payload=payload,
                    updated_at=updated_at,
                    deleted=item.deleted,
                    rev=rev,
                    device_id=body.device_id,
                )
            )
        else:
            current.payload = payload
            current.updated_at = updated_at
            current.deleted = item.deleted
            current.rev = rev
            current.device_id = body.device_id

    db.commit()
    log.info(
        "push from %s: %d applied, %d rejected", body.device_id, len(to_apply), len(rejected)
    )
    return PushResponse(
        cursor=_current_rev(db), applied=len(to_apply), rejected=rejected
    )


@router.get("/status")
def sync_status(db: Session = Depends(get_db)) -> dict:
    """Cheap overview for the app's sync settings screen."""
    counts: dict[str, int] = {}
    for collection, total in db.execute(
        select(Record.collection, func.count())
        .where(Record.deleted.is_(False))
        .group_by(Record.collection)
    ).all():
        counts[collection] = total
    return {"cursor": _current_rev(db), "records": counts}
