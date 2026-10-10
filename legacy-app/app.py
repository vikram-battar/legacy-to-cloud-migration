"""Legacy inventory app — the "before" picture.

A small Flask monolith written like it's 2014 and the cloud doesn't exist:
SQLite file in the working directory, config hardcoded at the top of the
file, no health endpoint, no structured logging. It works fine on one
server. It does not survive contact with a second one.
"""
import os
import sqlite3

from flask import Flask, jsonify, request

# Everything is hardcoded. This is the problem the migration solves.
DB_PATH = os.path.join(os.path.dirname(__file__), "inventory.db")
APP_PORT = 5000
DEBUG = True

app = Flask(__name__)


def get_db():
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    return conn


def init_db():
    conn = get_db()
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS items (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            quantity INTEGER NOT NULL DEFAULT 0
        )
        """
    )
    conn.commit()
    conn.close()


@app.route("/")
def index():
    conn = get_db()
    items = conn.execute("SELECT id, name, quantity FROM items").fetchall()
    conn.close()
    rows = "".join(
        f"<li>{r['name']} — qty {r['quantity']}</li>" for r in items
    )
    return f"<h1>Inventory</h1><ul>{rows}</ul>"


@app.route("/items", methods=["GET"])
def list_items():
    conn = get_db()
    items = conn.execute("SELECT id, name, quantity FROM items").fetchall()
    conn.close()
    return jsonify([dict(r) for r in items])


@app.route("/items", methods=["POST"])
def add_item():
    data = request.get_json(force=True)
    conn = get_db()
    cur = conn.execute(
        "INSERT INTO items (name, quantity) VALUES (?, ?)",
        (data["name"], int(data.get("quantity", 0))),
    )
    conn.commit()
    item_id = cur.lastrowid
    conn.close()
    return jsonify({"id": item_id, "name": data["name"],
                    "quantity": int(data.get("quantity", 0))}), 201


@app.route("/items/<int:item_id>", methods=["GET"])
def get_item(item_id):
    conn = get_db()
    row = conn.execute(
        "SELECT id, name, quantity FROM items WHERE id = ?", (item_id,)
    ).fetchone()
    conn.close()
    if row is None:
        return jsonify({"error": "not found"}), 404
    return jsonify(dict(row))


@app.route("/items/<int:item_id>", methods=["DELETE"])
def delete_item(item_id):
    conn = get_db()
    cur = conn.execute("DELETE FROM items WHERE id = ?", (item_id,))
    conn.commit()
    conn.close()
    if cur.rowcount == 0:
        return jsonify({"error": "not found"}), 404
    return jsonify({"deleted": item_id})


if __name__ == "__main__":
    init_db()
    app.run(host="0.0.0.0", port=APP_PORT, debug=DEBUG)
