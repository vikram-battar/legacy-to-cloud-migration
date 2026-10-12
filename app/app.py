"""Migrated inventory app — the "after" picture.

Same routes and behavior as ../legacy-app/app.py, rebuilt with cloud habits:
- all config from environment variables (12-factor)
- Postgres via DATABASE_URL, with SQLite as a local-dev fallback
- /healthz (liveness) and /readyz (readiness) endpoints for the ALB target group
- structured JSON logging to stdout (CloudWatch picks it up, no agent needed)
- runs as a non-root user in the container, gunicorn in front
"""
import json
import logging
import os
import sqlite3
import sys
import time

from flask import Flask, jsonify, request

# --- config: everything from the environment, nothing hardcoded --------------
PORT = int(os.environ.get("PORT", "5000"))
DATABASE_URL = os.environ.get("DATABASE_URL", "")  # postgres://... or empty
SQLITE_PATH = os.environ.get("SQLITE_PATH", "/tmp/inventory.db")
LOG_LEVEL = os.environ.get("LOG_LEVEL", "INFO").upper()


# --- structured logging ------------------------------------------------------
class JsonFormatter(logging.Formatter):
    def format(self, record):
        payload = {
            "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "level": record.levelname,
            "logger": record.name,
            "msg": record.getMessage(),
        }
        if record.exc_info:
            payload["exc"] = self.formatException(record.exc_info)
        return json.dumps(payload)


handler = logging.StreamHandler(sys.stdout)
handler.setFormatter(JsonFormatter())
log = logging.getLogger("inventory")
log.addHandler(handler)
log.setLevel(LOG_LEVEL)
log.propagate = False


# --- storage: postgres when DATABASE_URL is set, else sqlite -----------------
def _pg_conn():
    import psycopg  # imported lazily: only needed when DATABASE_URL is set

    return psycopg.connect(DATABASE_URL, row_factory=None)


def _sqlite_conn():
    conn = sqlite3.connect(SQLITE_PATH)
    conn.row_factory = sqlite3.Row
    return conn


USE_PG = bool(DATABASE_URL)


def get_db():
    return _pg_conn() if USE_PG else _sqlite_conn()


def _qmark():
    return "%s" if USE_PG else "?"


def init_db():
    conn = get_db()
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS items (
            id SERIAL PRIMARY KEY,
            name TEXT NOT NULL,
            quantity INTEGER NOT NULL DEFAULT 0
        )
        """
        if USE_PG
        else """
        CREATE TABLE IF NOT EXISTS items (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            quantity INTEGER NOT NULL DEFAULT 0
        )
        """
    )
    conn.commit()
    conn.close()
    log.info("database initialized (postgres=%s)", USE_PG)


def _rows_to_dicts(rows):
    out = []
    for r in rows:
        if isinstance(r, dict):
            out.append(r)
        elif hasattr(r, "_asdict"):
            out.append(r._asdict())
        else:  # sqlite3.Row
            out.append(dict(r))
    return out


app = Flask(__name__)


@app.before_request
def _log_request():
    log.info("request %s %s", request.method, request.path)


@app.route("/healthz")
def healthz():
    """Liveness: is the process alive. Cheap by design — the ALB hits this
    constantly, so it must never touch the database."""
    return jsonify({"status": "ok"}), 200


@app.route("/readyz")
def readyz():
    """Readiness: can this instance serve traffic. A DB ping catches the
    most common real outage; ECS gates task registration on this."""
    try:
        conn = get_db()
        conn.execute("SELECT 1")
        conn.close()
        return jsonify({"status": "ok"}), 200
    except Exception as exc:  # noqa: BLE001 — readiness must never raise
        log.error("readiness check failed: %s", exc)
        return jsonify({"status": "degraded", "error": str(exc)}), 503


@app.route("/")
def index():
    items = _all_items()
    rows = "".join(f"<li>{i['name']} — qty {i['quantity']}</li>" for i in items)
    return f"<h1>Inventory</h1><ul>{rows}</ul>"


def _all_items():
    conn = get_db()
    rows = conn.execute("SELECT id, name, quantity FROM items").fetchall()
    conn.close()
    return _rows_to_dicts(rows)


@app.route("/items", methods=["GET"])
def list_items():
    return jsonify(_all_items())


@app.route("/items", methods=["POST"])
def add_item():
    data = request.get_json(force=True)
    q = _qmark()
    conn = get_db()
    if USE_PG:
        cur = conn.execute(
            f"INSERT INTO items (name, quantity) VALUES ({q}, {q}) "
            "RETURNING id",
            (data["name"], int(data.get("quantity", 0))),
        )
        item_id = cur.fetchone()[0]
    else:
        cur = conn.execute(
            f"INSERT INTO items (name, quantity) VALUES ({q}, {q})",
            (data["name"], int(data.get("quantity", 0))),
        )
        item_id = cur.lastrowid
    conn.commit()
    conn.close()
    log.info("item created id=%s name=%s", item_id, data["name"])
    return (
        jsonify({"id": item_id, "name": data["name"],
                 "quantity": int(data.get("quantity", 0))}),
        201,
    )


@app.route("/items/<int:item_id>", methods=["GET"])
def get_item(item_id):
    q = _qmark()
    conn = get_db()
    rows = conn.execute(
        f"SELECT id, name, quantity FROM items WHERE id = {q}", (item_id,)
    ).fetchall()
    conn.close()
    if not rows:
        return jsonify({"error": "not found"}), 404
    return jsonify(_rows_to_dicts(rows)[0])


@app.route("/items/<int:item_id>", methods=["DELETE"])
def delete_item(item_id):
    q = _qmark()
    conn = get_db()
    cur = conn.execute(f"DELETE FROM items WHERE id = {q}", (item_id,))
    deleted = cur.rowcount
    conn.commit()
    conn.close()
    if not deleted:
        return jsonify({"error": "not found"}), 404
    log.info("item deleted id=%s", item_id)
    return jsonify({"deleted": item_id})


if __name__ == "__main__":
    init_db()
    log.info("starting on port %s (postgres=%s)", PORT, USE_PG)
    app.run(host="0.0.0.0", port=PORT)
