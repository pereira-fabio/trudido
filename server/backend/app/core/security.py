"""Token check for the sync API.

One shared secret, compared in constant time. There are no accounts here: this
server holds one person's data and is reached over their own network. The
record schema still carries a nullable user_id so accounts can be added later
without rewriting the store.
"""
import hmac

from fastapi import Header, HTTPException, status

from app.core.config import settings


def require_token(x_trudido_token: str | None = Header(default=None)) -> None:
    """FastAPI dependency. A blank API_AUTH_TOKEN disables the check entirely."""
    expected = settings.API_AUTH_TOKEN
    if not expected:
        return
    if not x_trudido_token or not hmac.compare_digest(x_trudido_token, expected):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid or missing X-Trudido-Token.",
        )
