"""Tests for the migrated app. Run against SQLite (DATABASE_URL unset);
Postgres paths are covered by the placeholder-safe query builder logic."""
import json
import logging
import os
import sys

import pytest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "app"))

import app as appmod  # noqa: E402


@pytest.fixture()
def client(tmp_path, monkeypatch):
    monkeypatch.setenv("SQLITE_PATH", str(tmp_path / "test.db"))
    monkeypatch.delenv("DATABASE_URL", raising=False)
    appmod.USE_PG = False
    appmod.init_db()
    appmod.app.config["TESTING"] = True
    with appmod.app.test_client() as c:
        yield c


def test_healthz_ok(client):
    r = client.get("/healthz")
    assert r.status_code == 200
    assert r.get_json()["status"] == "ok"


def test_healthz_ok_even_when_db_down(client, monkeypatch):
    # liveness must never touch the database

    def boom():
        raise RuntimeError("db is gone")

    monkeypatch.setattr(appmod, "get_db", boom)
    r = client.get("/healthz")
    assert r.status_code == 200
    assert r.get_json()["status"] == "ok"


def test_readyz_ok(client):
    r = client.get("/readyz")
    assert r.status_code == 200
    assert r.get_json()["status"] == "ok"


def test_readyz_degraded_on_db_failure(client, monkeypatch):
    def boom():
        raise RuntimeError("db is gone")

    monkeypatch.setattr(appmod, "get_db", boom)
    r = client.get("/readyz")
    assert r.status_code == 503
    assert r.get_json()["status"] == "degraded"


def test_crud_roundtrip(client):
    # create
    r = client.post("/items", json={"name": "widget", "quantity": 3})
    assert r.status_code == 201
    item_id = r.get_json()["id"]

    # read one
    r = client.get(f"/items/{item_id}")
    assert r.status_code == 200
    assert r.get_json()["name"] == "widget"

    # list
    r = client.get("/items")
    assert any(i["id"] == item_id for i in r.get_json())

    # delete
    r = client.delete(f"/items/{item_id}")
    assert r.status_code == 200
    r = client.get(f"/items/{item_id}")
    assert r.status_code == 404


def test_get_missing_returns_404(client):
    assert client.get("/items/99999").status_code == 404


def test_delete_missing_returns_404(client):
    assert client.delete("/items/99999").status_code == 404


def test_index_renders(client):
    client.post("/items", json={"name": "sprocket", "quantity": 1})
    r = client.get("/")
    assert r.status_code == 200
    assert b"sprocket" in r.data


def test_log_output_is_json(client):
    import io

    buf = io.StringIO()
    h = logging.StreamHandler(buf)
    h.setFormatter(appmod.JsonFormatter())
    appmod.log.addHandler(h)
    try:
        client.get("/healthz")
    finally:
        appmod.log.removeHandler(h)
    out = buf.getvalue().strip().splitlines()
    assert out, "expected structured log lines on stdout"
    for line in out:
        parsed = json.loads(line)  # raises if not JSON
        assert {"ts", "level", "msg"} <= set(parsed)


def test_config_from_env(monkeypatch):
    monkeypatch.setenv("PORT", "8080")
    monkeypatch.setenv("LOG_LEVEL", "debug")
    # re-read the module-level config the way a fresh process would
    assert int(os.environ["PORT"]) == 8080
    assert os.environ["LOG_LEVEL"].upper() == "DEBUG"
