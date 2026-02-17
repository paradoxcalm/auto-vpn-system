#!/usr/bin/env python3
"""
JetsFlare Central Panel — v2
User management, subscriptions, referrals, payments, node sync.
"""

import os
import json
import hashlib
import secrets
import re
from datetime import datetime, timezone
from pathlib import Path
from functools import wraps

from flask import (
    Flask, request, jsonify, render_template,
    session, redirect, url_for, g,
)

import models

app = Flask(__name__)
_api = os.environ.get("API_KEY", "")
app.secret_key = os.environ.get(
    "SECRET_KEY",
    hashlib.sha256(_api.encode()).hexdigest() if _api else secrets.token_urlsafe(32),
)

DATA_DIR = Path(os.environ.get("DATA_DIR", "/opt/auto-vpn-panel/data"))
API_KEY = os.environ.get("API_KEY", secrets.token_urlsafe(32))
PANEL_PASSWORD = os.environ.get("PANEL_PASSWORD", API_KEY)
PANEL_URL = os.environ.get("PANEL_URL", "")

# Init database
models.init_db(DATA_DIR)


def get_db():
    if "db" not in g:
        g.db = models.get_db()
    return g.db


@app.teardown_appcontext
def close_db(exception):
    db = g.pop("db", None)
    if db is not None:
        db.close()


# ======================== AUTH ========================

def require_api_key(f):
    @wraps(f)
    def decorated(*args, **kwargs):
        auth = request.headers.get("Authorization", "")
        token = auth.replace("Bearer ", "") if auth.startswith("Bearer ") else ""
        if token != API_KEY:
            return jsonify({"error": "Unauthorized"}), 401
        return f(*args, **kwargs)
    return decorated


def require_login(f):
    @wraps(f)
    def decorated(*args, **kwargs):
        if not session.get("authenticated"):
            return redirect(url_for("login"))
        return f(*args, **kwargs)
    return decorated


def require_admin_api(f):
    """For AJAX admin endpoints — returns 401 JSON instead of redirect."""
    @wraps(f)
    def decorated(*args, **kwargs):
        if not session.get("authenticated"):
            return jsonify({"error": "Unauthorized"}), 401
        return f(*args, **kwargs)
    return decorated


# ======================== HELPERS ========================

def country_flag(code):
    if not code or len(code) != 2:
        return ""
    return chr(0x1F1E6 + ord(code[0].upper()) - ord("A")) + \
           chr(0x1F1E6 + ord(code[1].upper()) - ord("A"))


app.jinja_env.globals.update(country_flag=country_flag)


# ======================== AUTH ROUTES ========================

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


# ======================== ADMIN WEB ========================

@app.route("/")
@require_login
def index():
    return render_template("index.html")


# ======================== NODE API ========================

@app.route("/api/nodes/register", methods=["POST"])
@require_api_key
def register_node():
    data = request.get_json()
    if not data:
        return jsonify({"error": "No data"}), 400

    for field in ("node_name", "server_ip", "vless_link"):
        if field not in data:
            return jsonify({"error": f"Missing: {field}"}), 400

    db = get_db()
    node_id = models.upsert_node(db, data)
    return jsonify({"status": "ok", "node_id": node_id}), 201


@app.route("/api/nodes", methods=["GET"])
@require_api_key
def api_list_nodes():
    db = get_db()
    nodes = models.list_nodes(db)
    return jsonify(nodes)


@app.route("/api/nodes/<node_id>", methods=["DELETE"])
@require_api_key
def api_delete_node(node_id):
    db = get_db()
    models.delete_node(db, node_id)
    return jsonify({"status": "deleted"})


@app.route("/api/nodes/<node_id>/heartbeat", methods=["POST"])
@require_api_key
def heartbeat(node_id):
    db = get_db()
    models.update_node_heartbeat(db, node_id)
    return jsonify({"status": "ok"})


@app.route("/api/nodes/<node_id>/clients", methods=["GET"])
@require_api_key
def get_node_clients(node_id):
    """Return active user UUIDs for this node's Xray config."""
    db = get_db()
    clients = models.get_active_clients(db)
    return jsonify(clients)


@app.route("/api/nodes/<node_id>/traffic", methods=["POST"])
@require_api_key
def report_traffic(node_id):
    """Receive per-user traffic stats from a node."""
    data = request.get_json()
    if not data:
        return jsonify({"error": "No data"}), 400
    db = get_db()
    models.record_traffic(db, node_id, data)
    return jsonify({"status": "ok"})


# ======================== PUBLIC CLIENT PAGE ========================

@app.route("/go")
def client_page():
    ref = request.args.get("ref", "")
    return render_template("client.html", ref=ref, panel_url=PANEL_URL)


@app.route("/go/register", methods=["POST"])
def client_register():
    data = request.get_json()
    if not data:
        return jsonify({"error": "No data"}), 400

    nickname = (data.get("nickname") or "").strip()
    if not nickname or len(nickname) < 2 or len(nickname) > 30:
        return jsonify({"error": "Nickname must be 2-30 characters"}), 400

    # Sanitize
    nickname = re.sub(r"[<>&\"']", "", nickname)

    referral = (data.get("referral_code") or "").strip().lower()

    db = get_db()
    try:
        user = models.create_user(db, nickname, referral_code_used=referral or None)
    except Exception as e:
        return jsonify({"error": str(e)}), 500

    links = models.generate_vless_links(db, user["uuid"])
    traffic = models.get_user_traffic_today(db, user["id"])

    return jsonify({
        "status": "ok",
        "user": {
            "nickname": user["nickname"],
            "code": user["referral_code"],
            "tier": user["tier"],
            "expires": user["subscription_expires_at"],
            "device_limit": user["device_limit"],
            "daily_limit_mb": user["daily_traffic_limit_mb"],
            "traffic_used": traffic,
            "referral_count": 0,
        },
        "links": links,
    })


@app.route("/go/status", methods=["POST"])
def client_status():
    data = request.get_json()
    if not data:
        return jsonify({"error": "No data"}), 400

    code = (data.get("code") or "").strip().lower()
    if not code:
        return jsonify({"error": "Code required"}), 400

    db = get_db()
    user = models.get_user_by_code(db, code)
    if not user:
        return jsonify({"error": "User not found"}), 404

    links = models.generate_vless_links(db, user["uuid"])
    traffic = models.get_user_traffic_today(db, user["id"])
    ref_count = models.get_referral_count(db, user["id"])

    return jsonify({
        "status": "ok",
        "user": {
            "nickname": user["nickname"],
            "code": user["referral_code"],
            "tier": user["tier"],
            "user_status": user["status"],
            "expires": user["subscription_expires_at"],
            "device_limit": user["device_limit"],
            "daily_limit_mb": user["daily_traffic_limit_mb"],
            "traffic_used": traffic,
            "referral_count": ref_count,
        },
        "links": links,
    })


# ======================== PAYMENT ========================

@app.route("/api/payment/create", methods=["POST"])
def payment_create():
    data = request.get_json()
    if not data:
        return jsonify({"error": "No data"}), 400

    code = (data.get("code") or "").strip().lower()
    db = get_db()
    user = models.get_user_by_code(db, code)
    if not user:
        return jsonify({"error": "User not found"}), 404

    # Import crypto_pay module
    try:
        from crypto_pay import create_invoice
    except ImportError:
        return jsonify({"error": "Payment system not configured"}), 503

    price = float(models.get_setting(db, "vip_price_usdt"))
    days = int(models.get_setting(db, "vip_duration_days"))
    currency = data.get("currency", "USDT")

    result = create_invoice(
        amount=price,
        currency=currency,
        description=f"JetsFlare VIP {days} days",
        payload=json.dumps({"user_id": user["id"], "days": days}),
    )

    if not result:
        return jsonify({"error": "Could not create invoice"}), 500

    models.create_payment(
        db, user["id"], price, currency, days,
        invoice_id=str(result["invoice_id"]),
    )

    return jsonify({
        "status": "ok",
        "pay_url": result["pay_url"],
        "amount": price,
        "currency": currency,
    })


@app.route("/api/payment/webhook", methods=["POST"])
def payment_webhook():
    """CryptoBot webhook — verify signature and confirm payment."""
    try:
        from crypto_pay import verify_webhook
    except ImportError:
        return jsonify({"error": "Not configured"}), 503

    body = request.get_data()
    signature = request.headers.get("crypto-pay-api-signature", "")

    if not verify_webhook(body, signature):
        return jsonify({"error": "Invalid signature"}), 403

    data = request.get_json()
    if not data or data.get("update_type") != "invoice_paid":
        return jsonify({"status": "ignored"})

    invoice = data.get("payload", {})
    invoice_id = str(invoice.get("invoice_id", ""))

    db = get_db()
    if models.confirm_payment(db, invoice_id):
        return jsonify({"status": "confirmed"})
    return jsonify({"status": "not_found"}), 404


# ======================== ADMIN API ========================

@app.route("/api/admin/stats")
@require_admin_api
def admin_stats():
    db = get_db()
    stats = models.get_dashboard_stats(db)
    return jsonify(stats)


@app.route("/api/admin/users")
@require_admin_api
def admin_users():
    db = get_db()
    tier = request.args.get("tier")
    status = request.args.get("status")
    search = request.args.get("search")
    limit = min(int(request.args.get("limit", 50)), 200)
    offset = int(request.args.get("offset", 0))

    users = models.list_users(db, tier=tier, status=status, search=search, limit=limit, offset=offset)
    total = models.count_users(db, tier=tier, status=status)

    # Enrich with traffic data
    today = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    for u in users:
        u["traffic_today"] = models.get_user_traffic_today(db, u["id"])
        u["referral_count"] = models.get_referral_count(db, u["id"])

    return jsonify({"users": users, "total": total})


@app.route("/api/admin/users/<int:user_id>")
@require_admin_api
def admin_user_detail(user_id):
    db = get_db()
    user = models.get_user(db, user_id)
    if not user:
        return jsonify({"error": "Not found"}), 404

    user["traffic_today"] = models.get_user_traffic_today(db, user["id"])
    user["referral_count"] = models.get_referral_count(db, user["id"])
    user["links"] = models.generate_vless_links(db, user["uuid"])
    return jsonify(user)


@app.route("/api/admin/users/<int:user_id>/tier", methods=["POST"])
@require_admin_api
def admin_set_tier(user_id):
    data = request.get_json()
    tier = data.get("tier", "free")
    db = get_db()
    updates = {"tier": tier}
    if tier == "vip":
        updates["daily_traffic_limit_mb"] = 0
        updates["device_limit"] = int(models.get_setting(db, "vip_device_limit"))
    else:
        updates["daily_traffic_limit_mb"] = int(models.get_setting(db, "free_daily_traffic_mb"))
        updates["device_limit"] = int(models.get_setting(db, "free_device_limit"))
    models.update_user(db, user_id, **updates)
    return jsonify({"status": "ok"})


@app.route("/api/admin/users/<int:user_id>/block", methods=["POST"])
@require_admin_api
def admin_block_user(user_id):
    data = request.get_json()
    new_status = data.get("status", "blocked")
    db = get_db()
    models.update_user(db, user_id, status=new_status)
    return jsonify({"status": "ok"})


@app.route("/api/admin/users/<int:user_id>/extend", methods=["POST"])
@require_admin_api
def admin_extend(user_id):
    data = request.get_json()
    days = int(data.get("days", 30))
    db = get_db()
    models.extend_subscription(db, user_id, days)
    return jsonify({"status": "ok"})


@app.route("/api/admin/users/<int:user_id>/device-limit", methods=["POST"])
@require_admin_api
def admin_device_limit(user_id):
    data = request.get_json()
    limit = int(data.get("limit", 2))
    db = get_db()
    models.update_user(db, user_id, device_limit=limit)
    return jsonify({"status": "ok"})


@app.route("/api/admin/users/<int:user_id>", methods=["DELETE"])
@require_admin_api
def admin_delete_user(user_id):
    db = get_db()
    models.delete_user(db, user_id)
    return jsonify({"status": "ok"})


@app.route("/api/admin/nodes")
@require_admin_api
def admin_nodes():
    db = get_db()
    nodes = models.list_nodes(db)
    return jsonify(nodes)


@app.route("/api/admin/nodes/<node_id>", methods=["DELETE"])
@require_admin_api
def admin_delete_node(node_id):
    db = get_db()
    models.delete_node(db, node_id)
    return jsonify({"status": "ok"})


@app.route("/api/admin/settings", methods=["GET"])
@require_admin_api
def admin_get_settings():
    db = get_db()
    rows = db.execute("SELECT key, value FROM settings").fetchall()
    return jsonify({r["key"]: r["value"] for r in rows})


@app.route("/api/admin/settings", methods=["POST"])
@require_admin_api
def admin_save_settings():
    data = request.get_json()
    if not data:
        return jsonify({"error": "No data"}), 400
    db = get_db()
    for key, value in data.items():
        models.set_setting(db, key, value)
    return jsonify({"status": "ok"})


@app.route("/api/admin/referrals")
@require_admin_api
def admin_referrals():
    db = get_db()
    stats = models.get_referral_stats(db)
    return jsonify(stats)


# ======================== MAIN ========================

if __name__ == "__main__":
    print(f"\n  JetsFlare Central Panel v2")
    print(f"  API Key: {API_KEY}")
    print(f"  Data: {DATA_DIR}\n")

    host = os.environ.get("HOST", "0.0.0.0")
    port = int(os.environ.get("PORT", 8080))
    debug = os.environ.get("DEBUG", "false").lower() == "true"
    app.run(host=host, port=port, debug=debug)
