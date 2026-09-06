"""Trudido sync server.

A sync peer, not a source of truth. The app works exactly as it always has
with this server switched off or unreachable; everything here is additive.
"""
import logging
from contextlib import asynccontextmanager

from fastapi import Depends, FastAPI
from fastapi.middleware.cors import CORSMiddleware

from app.api import blobs, sync
from app.core.config import settings
from app.core.filestore import configure_store
from app.core.migrate_sqlite import migrate_if_needed
from app.core.security import require_token

logging.basicConfig(
    level=logging.INFO, format="%(asctime)s %(levelname)-8s %(name)s: %(message)s"
)
log = logging.getLogger("trudido")


@asynccontextmanager
async def lifespan(_app: FastAPI):
    store = configure_store(settings.DATA_DIR)
    migrate_if_needed(store, settings.DATABASE_URL)
    guarded = "token required" if settings.API_AUTH_TOKEN else "OPEN (no token set)"
    log.info(
        "%s ready - storing in %s - %s", settings.PROJECT_NAME, store.root, guarded
    )
    yield


app = FastAPI(
    title=settings.PROJECT_NAME,
    lifespan=lifespan,
    version="1.0.0",
    description=(
        "Self-hosted sync for Trudido. Records are stored as opaque JSON files "
        "under one directory, so the whole store can live on a NAS share. "
        "Vault notes arrive already encrypted and are never readable here."
    ),
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=[o.strip() for o in settings.CORS_ORIGINS.split(",") if o.strip()],
    allow_credentials=False,
    allow_methods=["*"],
    allow_headers=["*"],
)

app.include_router(sync.router, prefix=settings.API_V1_STR)
app.include_router(blobs.router, prefix=settings.API_V1_STR)


@app.get("/api/v1/health")
def health() -> dict:
    """Unauthenticated, so a container healthcheck needs no secret."""
    return {"status": "ok", "service": settings.PROJECT_NAME}


@app.get("/api/v1/auth/check", dependencies=[Depends(require_token)])
def auth_check() -> dict:
    """What the app's "Test connection" button calls."""
    return {"status": "ok", "token_required": bool(settings.API_AUTH_TOKEN)}
