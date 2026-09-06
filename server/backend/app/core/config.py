import os

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    PROJECT_NAME: str = "Trudido Sync"
    API_V1_STR: str = "/api/v1"

    # Shared secret sent by the app as X-Trudido-Token. Empty leaves sync open,
    # which is fine on an isolated home network and is what a first run gets;
    # set it to any value to require it, and enter the same value in the app
    # under Settings -> Sync.
    API_AUTH_TOKEN: str = os.getenv("API_AUTH_TOKEN", "")

    # Storage paths, shaped for a TrueNAS mount or a local LXC volume.
    DATA_DIR: str = os.getenv("DATA_DIR", "/data")
    DATABASE_URL: str = os.getenv("DATABASE_URL", "sqlite:////data/trudido.db")

    # Where note attachments land. One directory per two-character hash prefix,
    # so a few thousand files do not end up in a single directory.
    BLOB_DIR: str = os.getenv("BLOB_DIR", "/data/blobs")

    # Largest single attachment accepted, in megabytes. Video notes are the
    # reason this is not smaller.
    MAX_BLOB_MB: int = int(os.getenv("MAX_BLOB_MB", "256"))

    # Records returned by one pull. The client pages until has_more is false.
    SYNC_PAGE_SIZE: int = int(os.getenv("SYNC_PAGE_SIZE", "500"))

    # Permitted browser origins for the web build. "*" is the default because
    # the token, not the origin, is what actually guards this server.
    CORS_ORIGINS: str = os.getenv("CORS_ORIGINS", "*")

    model_config = SettingsConfigDict(case_sensitive=True, env_file=".env")


settings = Settings()
