"""Wire shapes. These mirror lib/services/sync/sync_types.dart."""
import datetime as dt
from typing import Any

from pydantic import BaseModel, Field


class RecordIn(BaseModel):
    collection: str = Field(max_length=64)
    id: str = Field(max_length=128)
    payload: dict[str, Any] | None = None
    updated_at: dt.datetime
    deleted: bool = False


class RecordOut(BaseModel):
    collection: str
    id: str
    payload: dict[str, Any] | None
    updated_at: dt.datetime
    deleted: bool
    rev: int


class Rejection(BaseModel):
    """A push the server declined because its own copy was newer."""

    collection: str
    id: str
    server_record: RecordOut | None = None


class PushRequest(BaseModel):
    device_id: str = Field(max_length=128)
    records: list[RecordIn] = Field(default_factory=list)


class PushResponse(BaseModel):
    cursor: int
    applied: int
    rejected: list[Rejection] = Field(default_factory=list)


class PullResponse(BaseModel):
    records: list[RecordOut]
    cursor: int
    has_more: bool


class BlobInfo(BaseModel):
    sha256: str
    filename: str
    size: int
    mime: str | None = None


class BlobManifest(BaseModel):
    blobs: list[BlobInfo]
