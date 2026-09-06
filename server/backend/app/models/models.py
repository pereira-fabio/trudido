"""The store.

Records are opaque: the server keeps `payload` as text and never parses it.
That is what lets the app add a field, or a whole model, without a migration
here -- and it also means a vault note can be stored as ciphertext the server
is structurally incapable of reading.
"""
import datetime as dt

from sqlalchemy import (
    Boolean,
    Column,
    DateTime,
    Integer,
    String,
    Text,
    UniqueConstraint,
    Index,
)

from app.core.database import Base


def utcnow() -> dt.datetime:
    return dt.datetime.now(dt.timezone.utc)


class Record(Base):
    """One synced document, addressed by (collection, id)."""

    __tablename__ = "records"

    pk = Column(Integer, primary_key=True, autoincrement=True)
    collection = Column(String(64), nullable=False)
    record_id = Column(String(128), nullable=False)

    # The document as the client serialised it. NULL for a tombstone.
    payload = Column(Text, nullable=True)

    # The client's own last-modified time. This, not rev, is what conflict
    # resolution compares: rev is server arrival order, which says nothing
    # about which edit actually happened later.
    updated_at = Column(DateTime(timezone=True), nullable=False)

    deleted = Column(Boolean, nullable=False, default=False)

    # Server-assigned, strictly increasing. Clients page through it, so it must
    # never be reused or reordered.
    rev = Column(Integer, nullable=False, index=True)

    device_id = Column(String(128), nullable=True)

    # Unused today; present so multi-user is an added filter rather than a
    # table rewrite.
    user_id = Column(String(128), nullable=True, index=True)

    server_updated_at = Column(DateTime(timezone=True), default=utcnow)

    __table_args__ = (
        UniqueConstraint("collection", "record_id", name="uq_record_identity"),
        Index("ix_records_rev_collection", "rev", "collection"),
    )


class Counter(Base):
    """Monotonic sequence for `rev`.

    SQLite has no sequences, and `MAX(rev) + 1` is not safe against two pushes
    racing. A row bumped inside the same transaction as the write is, because
    SQLite serialises write transactions.
    """

    __tablename__ = "counters"

    name = Column(String(32), primary_key=True)
    value = Column(Integer, nullable=False, default=0)


class Blob(Base):
    """A note attachment, addressed by the SHA-256 of its bytes.

    Content addressing means the same photo pasted into three notes is stored
    and transferred once, and an interrupted upload can simply be retried.
    """

    __tablename__ = "blobs"

    sha256 = Column(String(64), primary_key=True)
    filename = Column(String(512), nullable=False)
    size = Column(Integer, nullable=False)
    mime = Column(String(128), nullable=True)
    created_at = Column(DateTime(timezone=True), default=utcnow)
