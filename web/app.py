#!/usr/bin/env python3
"""
AUTO-VPN Central Panel
Simple web panel that collects VPN keys from all nodes and displays them.
"""

import os
import json
import hashlib
import secrets
from datetime import datetime, timezone
from pathlib import Path
from functools import wraps

from flask import Flask, request, jsonify, render_template, abort, session, redirect, url_for

app = Flask(__name__)
app.secret_key = os.environ.get("SECRET_KEY", secrets.token_urlsafe(32))

DATA_DIR = Path(os.environ.get("DATA_DIR", "/opt/auto-vpn-panel/data"))
DATA_DIR.mkdir(parents=True, exist_ok=True)
NODES_FILE = DATA_DIR / "nodes.json"

# API key for node authentication AND web panel access
API_KEY = os.environ.get("API_KEY", secrets.token_urlsafe(32))

# Web panel password (same as API_KEY by default, or set PANEL_PASSWORD)
PANEL_PASSWORD = os.environ.get("PANEL_PASSWORD", API_KEY)


def load_nodes():
    if NODES_FILE.exists():
        with open(NODES_FILE) as f:
            return json.load(f)
    return []


def save_nodes(nodes):
    with open(NODES_FILE, "w") as f:
        json.dump(nodes, f, indent=2, ensure_ascii=False)


def require_api_key(f):
    @wraps(f)
    def decorated(*args, **kwargs):
        auth = request.headers.get("Authorization", "")
        token = auth.replace("Bearer ", "") if auth.startswith("Bearer ") else ""
        if token != API_KEY:
            return jsonify({"error": "Unauthorized"}), 401
        return f(*args, **kwargs)
    return decorated


# Country flag emoji from country code
def country_flag(code):
    if not code or len(code) != 2:
        return ""
    return chr(0x1F1E6 + ord(code[0].upper()) - ord('A')) + \
           chr(0x1F1E6 + ord(code[1].upper()) - ord('A'))


app.jinja_env.globals.update(country_flag=country_flag)


# ======================== API ROUTES ========================

@app.route("/api/nodes/register", methods=["POST"])
@require_api_key
def register_node():
    """Called by install.sh on each server to register itself."""
    data = request.get_json()
    if not data:
        return jsonify({"error": "No data"}), 400

    required = ["node_name", "server_ip", "vless_link"]
    for field in required:
        if field not in data:
            return jsonify({"error": f"Missing field: {field}"}), 400

    nodes = load_nodes()

    # Update existing or add new
    node_id = hashlib.sha256(data["server_ip"].encode()).hexdigest()[:12]
    data["id"] = node_id
    data["last_seen"] = datetime.now(timezone.utc).isoformat()
    data["status"] = "online"

    existing = next((i for i, n in enumerate(nodes) if n.get("id") == node_id), None)
    if existing is not None:
        nodes[existing] = data
    else:
        nodes.append(data)

    save_nodes(nodes)

    return jsonify({"status": "ok", "node_id": node_id}), 201


@app.route("/api/nodes", methods=["GET"])
@require_api_key
def list_nodes():
    """List all nodes (requires API key — contains sensitive links)."""
    nodes = load_nodes()
    return jsonify(nodes)


@app.route("/api/nodes/<node_id>", methods=["DELETE"])
@require_api_key
def delete_node(node_id):
    nodes = load_nodes()
    nodes = [n for n in nodes if n.get("id") != node_id]
    save_nodes(nodes)
    return jsonify({"status": "deleted"})


@app.route("/api/nodes/<node_id>/heartbeat", methods=["POST"])
@require_api_key
def heartbeat(node_id):
    """Nodes call this periodically to confirm they're alive."""
    nodes = load_nodes()
    for n in nodes:
        if n.get("id") == node_id:
            n["last_seen"] = datetime.now(timezone.utc).isoformat()
            n["status"] = "online"
            break
    save_nodes(nodes)
    return jsonify({"status": "ok"})


# ======================== WEB AUTH ========================

def require_login(f):
    @wraps(f)
    def decorated(*args, **kwargs):
        if not session.get("authenticated"):
            return redirect(url_for("login"))
        return f(*args, **kwargs)
    return decorated


@app.route("/login", methods=["GET", "POST"])
def login():
    error = None
    if request.method == "POST":
        if request.form.get("password") == PANEL_PASSWORD:
            session["authenticated"] = True
            return redirect(url_for("index"))
        error = "Wrong password"
    return render_template("login.html", error=error)


@app.route("/logout")
def logout():
    session.clear()
    return redirect(url_for("login"))


# ======================== WEB ROUTES ========================

@app.route("/")
@require_login
def index():
    nodes = load_nodes()
    # Group by country
    countries = {}
    for n in nodes:
        cc = n.get("country_code", "XX")
        if cc not in countries:
            countries[cc] = {
                "code": cc,
                "name": n.get("country_name", "Unknown"),
                "flag": country_flag(cc),
                "nodes": []
            }
        countries[cc]["nodes"].append(n)

    return render_template("index.html",
                           countries=countries,
                           nodes=nodes,
                           total=len(nodes))


# ======================== PUBLIC CLIENT PAGE ========================

@app.route("/go")
def client_page():
    """Public client page — no login required.
    Shows two buttons: iOS / Android.
    Auto-picks best server, copies config, redirects to app store.
    No suspicious words anywhere on the page.
    """
    nodes = load_nodes()
    # Only expose minimal safe data to client page
    safe_nodes = []
    for n in nodes:
        if n.get("status") == "online" or not n.get("status"):
            safe_nodes.append({
                "cc": n.get("country_code", "XX"),
                "vless_link": n.get("vless_link", ""),
                "hysteria_link": n.get("hysteria_link", ""),
                "status": n.get("status", "online"),
            })
    return render_template("client.html",
                           nodes_json=json.dumps(safe_nodes, ensure_ascii=False))


# ======================== MAIN ========================

if __name__ == "__main__":
    print(f"\n  AUTO-VPN Central Panel")
    print(f"  API Key: {API_KEY}")
    print(f"  Data: {DATA_DIR}\n")

    host = os.environ.get("HOST", "0.0.0.0")
    port = int(os.environ.get("PORT", 8080))
    debug = os.environ.get("DEBUG", "false").lower() == "true"

    app.run(host=host, port=port, debug=debug)
