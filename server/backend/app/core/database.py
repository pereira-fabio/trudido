"""SQLite engine and session handling.

SQLite is deliberate: this is one person's task list, the write rate is a few
records a minute at worst, and a single file is trivially backed up by the same
snapshot that covers the rest of the NAS.
"""
import os
from pathlib import Path

from sqlalchemy import create_engine, event
from sqlalchemy.orm import declarative_base, sessionmaker

from app.core.config import settings

Base = declarative_base()


def _ensure_parent(url: str) -> None:
    """Create the database's directory, so a fresh volume does not fail to open."""
    if url.startswith("sqlite:///"):
        path = url.replace("sqlite:////", "/").replace("sqlite:///", "")
        if path and path != ":memory:":
            Path(path).parent.mkdir(parents=True, exist_ok=True)


_ensure_parent(settings.DATABASE_URL)

engine = create_engine(
    settings.DATABASE_URL,
    # FastAPI serves a request on whichever thread it likes; the sessions here
    # are short-lived and never shared, so the check is noise.
    connect_args={"check_same_thread": False}
    if settings.DATABASE_URL.startswith("sqlite")
    else {},
    pool_pre_ping=True,
)


@event.listens_for(engine, "connect")
def _sqlite_pragmas(dbapi_connection, _record):
    """WAL so a long pull does not block a push, and enforced foreign keys."""
    if not settings.DATABASE_URL.startswith("sqlite"):
        return
    cursor = dbapi_connection.cursor()
    cursor.execute("PRAGMA journal_mode=WAL")
    cursor.execute("PRAGMA foreign_keys=ON")
    # Durable enough for this workload and markedly faster than FULL on the
    # spinning disks a NAS tends to have.
    cursor.execute("PRAGMA synchronous=NORMAL")
    cursor.close()


SessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine)


def get_db():
    """FastAPI dependency yielding a session that is always closed."""
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()


def init_storage() -> None:
    """Create tables and the blob directory. Safe to run on every boot."""
    os.makedirs(settings.BLOB_DIR, exist_ok=True)
    Base.metadata.create_all(bind=engine)
