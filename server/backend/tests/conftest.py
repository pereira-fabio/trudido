"""Each test gets its own database and blob directory, created before the app
is imported so the module-level engine binds to the temporary path.
"""
import importlib
import os
import sys

import pytest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if ROOT not in sys.path:
    sys.path.insert(0, ROOT)


@pytest.fixture
def make_client(tmp_path):
    """Builds a TestClient against a fresh store, with an optional token."""
    from fastapi.testclient import TestClient

    def _build(token: str = ""):
        os.environ["DATABASE_URL"] = f"sqlite:///{tmp_path}/trudido.db"
        os.environ["DATA_DIR"] = str(tmp_path)
        os.environ["BLOB_DIR"] = str(tmp_path / "blobs")
        os.environ["API_AUTH_TOKEN"] = token

        # The engine and settings are module-level, so they must be rebuilt
        # after the environment changes.
        for name in [
            m
            for m in list(sys.modules)
            if m == "app" or m.startswith("app.")
        ]:
            del sys.modules[name]

        main = importlib.import_module("app.main")
        client = TestClient(main.app)
        client.headers.update({"X-Trudido-Token": token} if token else {})
        return client

    return _build


@pytest.fixture
def client(make_client):
    with make_client() as c:
        yield c
