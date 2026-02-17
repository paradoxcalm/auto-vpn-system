"""
JetsFlare Panel — Database Models (SQLite)
"""

import sqlite3
import uuid as _uuid
import string
import random
import json
from datetime import datetime, timezone, timedelta
from pathlib import Path

DB_PATH = None  # Set by init_db()

SCHEMA = """
CREATE TABLE IF NOT EXISTS users (
    id                      INTEGER PRIMARY KEY AUTOINCREMENT,
    uuid                    TEXT NOT NULL UNIQUE,
    nickname                TEXT NOT NULL,
    tier                    TEXT NOT NULL DEFAULT 'free',
    status                  TEXT NOT NULL DEFAULT 'active',
    device_limit            INTEGER NOT NULL DEFAULT 2,
    daily_traffic_limit_mb  INTEGER NOT NULL DEFAULT 1024,
    subscription_expires_at TEXT,
    referral_code           TEXT NOT NULL UNIQUE,
    referred_by             INTEGER REFERENCES users(id),
    telegram_id             INTEGER UNIQUE,
    telegram_username       TEXT,
    created_at              TEXT NOT NULL DEFAULT (datetime('now')),
    updated_at              TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS nodes (
    id                  TEXT PRIMARY KEY,
    node_name           TEXT NOT NULL,
    server_ip           TEXT NOT NULL,
    cf_domain           TEXT,
    country_code        TEXT DEFAULT 'XX',
    country_name        TEXT DEFAULT 'Unknown',
    city                TEXT DEFAULT '',
    isp                 TEXT DEFAULT '',
    protocols           TEXT DEFAULT '["vless-ws-tls"]',
    xray_version        TEXT,
    vless_link          TEXT,
    vless_link_template TEXT,
    ws_path             TEXT DEFAULT '/ws',
    status              TEXT DEFAULT 'online',
    last_seen           TEXT,
    installed_at        TEXT,
    created_at          TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS traffic_logs (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id         INTEGER NOT NULL REFERENCES users(id),
    node_id         TEXT NOT NULL REFERENCES nodes(id),
    uplink_bytes    INTEGER NOT NULL DEFAULT 0,
    downlink_bytes  INTEGER NOT NULL DEFAULT 0,
    recorded_at     TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS daily_traffic (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id     INTEGER NOT NULL REFERENCES users(id),
    date        TEXT NOT NULL,
    total_bytes INTEGER NOT NULL DEFAULT 0,
    UNIQUE(user_id, date)
);

CREATE TABLE IF NOT EXISTS payments (
    id                  INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id             INTEGER NOT NULL REFERENCES users(id),
    amount              REAL NOT NULL,
    currency            TEXT NOT NULL DEFAULT 'USDT',
    crypto_invoice_id   TEXT UNIQUE,
    status              TEXT NOT NULL DEFAULT 'pending',
    days_added          INTEGER NOT NULL DEFAULT 30,
    paid_at             TEXT,
    created_at          TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS referrals (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    referrer_id INTEGER NOT NULL REFERENCES users(id),
    referred_id INTEGER NOT NULL REFERENCES users(id),
    bonus_days  INTEGER NOT NULL DEFAULT 5,
    applied_at  TEXT NOT NULL DEFAULT (datetime('now')),
    UNIQUE(referrer_id, referred_id)
);

CREATE TABLE IF NOT EXISTS settings (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_users_uuid ON users(uuid);
CREATE INDEX IF NOT EXISTS idx_users_referral_code ON users(referral_code);
CREATE INDEX IF NOT EXISTS idx_users_telegram_id ON users(telegram_id);
CREATE INDEX IF NOT EXISTS idx_traffic_user_date ON traffic_logs(user_id, recorded_at);
CREATE INDEX IF NOT EXISTS idx_daily_traffic ON daily_traffic(user_id, date);
CREATE INDEX IF NOT EXISTS idx_payments_user ON payments(user_id);
CREATE INDEX IF NOT EXISTS idx_payments_invoice ON payments(crypto_invoice_id);
"""

DEFAULT_SETTINGS = {
    "trial_days": "3",
    "referral_bonus_days": "5",
    "free_daily_traffic_mb": "1024",
    "free_device_limit": "2",
    "vip_device_limit": "5",
    "vip_price_usdt": "5.00",
    "vip_duration_days": "30",
    "brand_name": "JetsFlare",
}


def get_db():
    db = sqlite3.connect(str(DB_PATH))
    db.row_factory = sqlite3.Row
    db.execute("PRAGMA journal_mode=WAL")
    db.execute("PRAGMA busy_timeout=5000")
    db.execute("PRAGMA foreign_keys=ON")
    return db


def init_db(data_dir):
    global DB_PATH
    data_dir = Path(data_dir)
    data_dir.mkdir(parents=True, exist_ok=True)
    DB_PATH = data_dir / "panel.db"

    db = get_db()
    db.executescript(SCHEMA)

    # Seed default settings
    for key, value in DEFAULT_SETTINGS.items():
        db.execute(
            "INSERT OR IGNORE INTO settings (key, value) VALUES (?, ?)",
            (key, value),
        )

    # Migrate nodes.json if it exists
    nodes_json = data_dir / "nodes.json"
    if nodes_json.exists():
        _migrate_nodes_json(db, nodes_json)

    db.commit()
    db.close()


def _migrate_nodes_json(db, nodes_json_path):
    """One-time migration from nodes.json to SQLite."""
    existing = db.execute("SELECT COUNT(*) FROM nodes").fetchone()[0]
    if existing > 0:
        return  # Already migrated

    try:
        with open(nodes_json_path) as f:
            nodes = json.load(f)
    except (json.JSONDecodeError, IOError):
        return

    for n in nodes:
        # Build vless_link_template from vless_link
        vless_link = n.get("vless_link", "")
        template = vless_link
        node_uuid = n.get("uuid", "")
        if node_uuid and vless_link:
            template = vless_link.replace(node_uuid, "{uuid}")

        protocols = json.dumps(n.get("protocols", ["vless-ws-tls"]))

        db.execute(
            """INSERT OR IGNORE INTO nodes
               (id, node_name, server_ip, cf_domain, country_code, country_name,
                city, isp, protocols, xray_version, vless_link, vless_link_template,
                status, last_seen, installed_at)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
            (
                n.get("id", ""),
                n.get("node_name", "Unknown"),
                n.get("server_ip", ""),
                n.get("cf_domain", ""),
                n.get("country_code", "XX"),
                n.get("country_name", "Unknown"),
                n.get("city", ""),
                n.get("isp", ""),
                protocols,
                n.get("xray_version", ""),
                vless_link,
                template,
                n.get("status", "online"),
                n.get("last_seen", ""),
                n.get("installed_at", ""),
            ),
        )


# ======================== HELPERS ========================


def _gen_referral_code(db):
    chars = string.ascii_lowercase + string.digits
    for _ in range(100):
        code = "".join(random.choices(chars, k=8))
        if not db.execute(
            "SELECT 1 FROM users WHERE referral_code = ?", (code,)
        ).fetchone():
            return code
    raise RuntimeError("Could not generate unique referral code")


def get_setting(db, key):
    row = db.execute("SELECT value FROM settings WHERE key = ?", (key,)).fetchone()
    return row["value"] if row else DEFAULT_SETTINGS.get(key, "")


def set_setting(db, key, value):
    db.execute(
        "INSERT OR REPLACE INTO settings (key, value) VALUES (?, ?)",
        (key, str(value)),
    )
    db.commit()


# ======================== USER CRUD ========================


def create_user(db, nickname, referral_code_used=None, telegram_id=None, telegram_username=None):
    """Create a new user with trial subscription. Returns user dict."""
    user_uuid = str(_uuid.uuid4())
    ref_code = _gen_referral_code(db)
    trial_days = int(get_setting(db, "trial_days"))
    free_limit = int(get_setting(db, "free_daily_traffic_mb"))
    free_devices = int(get_setting(db, "free_device_limit"))
    expires = (datetime.now(timezone.utc) + timedelta(days=trial_days)).isoformat()

    referred_by = None
    if referral_code_used:
        referrer = db.execute(
            "SELECT id FROM users WHERE referral_code = ?", (referral_code_used,)
        ).fetchone()
        if referrer:
            referred_by = referrer["id"]

    db.execute(
        """INSERT INTO users
           (uuid, nickname, tier, status, device_limit, daily_traffic_limit_mb,
            subscription_expires_at, referral_code, referred_by,
            telegram_id, telegram_username)
           VALUES (?, ?, 'free', 'active', ?, ?, ?, ?, ?, ?, ?)""",
        (
            user_uuid, nickname, free_devices, free_limit,
            expires, ref_code, referred_by, telegram_id, telegram_username,
        ),
    )
    user_id = db.execute("SELECT last_insert_rowid()").fetchone()[0]

    # Apply referral bonus to referrer
    if referred_by:
        bonus = int(get_setting(db, "referral_bonus_days"))
        db.execute(
            "INSERT OR IGNORE INTO referrals (referrer_id, referred_id, bonus_days) VALUES (?, ?, ?)",
            (referred_by, user_id, bonus),
        )
        # Extend referrer subscription
        referrer_user = db.execute("SELECT subscription_expires_at FROM users WHERE id = ?", (referred_by,)).fetchone()
        base = referrer_user["subscription_expires_at"]
        if base:
            try:
                base_dt = datetime.fromisoformat(base)
            except ValueError:
                base_dt = datetime.now(timezone.utc)
        else:
            base_dt = datetime.now(timezone.utc)
        if base_dt < datetime.now(timezone.utc):
            base_dt = datetime.now(timezone.utc)
        new_expires = (base_dt + timedelta(days=bonus)).isoformat()
        db.execute(
            "UPDATE users SET subscription_expires_at = ?, updated_at = datetime('now') WHERE id = ?",
            (new_expires, referred_by),
        )

    db.commit()

    return get_user(db, user_id)


def get_user(db, user_id):
    row = db.execute("SELECT * FROM users WHERE id = ?", (user_id,)).fetchone()
    return dict(row) if row else None


def get_user_by_code(db, code):
    row = db.execute("SELECT * FROM users WHERE referral_code = ?", (code,)).fetchone()
    return dict(row) if row else None


def get_user_by_uuid(db, user_uuid):
    row = db.execute("SELECT * FROM users WHERE uuid = ?", (user_uuid,)).fetchone()
    return dict(row) if row else None


def get_user_by_telegram(db, telegram_id):
    row = db.execute("SELECT * FROM users WHERE telegram_id = ?", (telegram_id,)).fetchone()
    return dict(row) if row else None


def list_users(db, tier=None, status=None, search=None, limit=100, offset=0):
    query = "SELECT * FROM users WHERE 1=1"
    params = []
    if tier:
        query += " AND tier = ?"
        params.append(tier)
    if status:
        query += " AND status = ?"
        params.append(status)
    if search:
        query += " AND (nickname LIKE ? OR referral_code LIKE ? OR uuid LIKE ?)"
        s = f"%{search}%"
        params.extend([s, s, s])
    query += " ORDER BY id DESC LIMIT ? OFFSET ?"
    params.extend([limit, offset])
    rows = db.execute(query, params).fetchall()
    return [dict(r) for r in rows]


def count_users(db, tier=None, status=None):
    query = "SELECT COUNT(*) FROM users WHERE 1=1"
    params = []
    if tier:
        query += " AND tier = ?"
        params.append(tier)
    if status:
        query += " AND status = ?"
        params.append(status)
    return db.execute(query, params).fetchone()[0]


def update_user(db, user_id, **fields):
    allowed = {
        "nickname", "tier", "status", "device_limit",
        "daily_traffic_limit_mb", "subscription_expires_at",
        "telegram_id", "telegram_username",
    }
    updates = {k: v for k, v in fields.items() if k in allowed}
    if not updates:
        return
    updates["updated_at"] = datetime.now(timezone.utc).isoformat()
    set_clause = ", ".join(f"{k} = ?" for k in updates)
    values = list(updates.values()) + [user_id]
    db.execute(f"UPDATE users SET {set_clause} WHERE id = ?", values)
    db.commit()


def delete_user(db, user_id):
    db.execute("DELETE FROM referrals WHERE referrer_id = ? OR referred_id = ?", (user_id, user_id))
    db.execute("DELETE FROM daily_traffic WHERE user_id = ?", (user_id,))
    db.execute("DELETE FROM traffic_logs WHERE user_id = ?", (user_id,))
    db.execute("DELETE FROM payments WHERE user_id = ?", (user_id,))
    db.execute("DELETE FROM users WHERE id = ?", (user_id,))
    db.commit()


def extend_subscription(db, user_id, days):
    user = get_user(db, user_id)
    if not user:
        return
    base = user["subscription_expires_at"]
    if base:
        try:
            base_dt = datetime.fromisoformat(base)
        except ValueError:
            base_dt = datetime.now(timezone.utc)
    else:
        base_dt = datetime.now(timezone.utc)
    if base_dt < datetime.now(timezone.utc):
        base_dt = datetime.now(timezone.utc)
    new_expires = (base_dt + timedelta(days=days)).isoformat()
    db.execute(
        "UPDATE users SET subscription_expires_at = ?, updated_at = datetime('now') WHERE id = ?",
        (new_expires, user_id),
    )
    db.commit()


# ======================== NODE CRUD ========================


def get_node(db, node_id):
    row = db.execute("SELECT * FROM nodes WHERE id = ?", (node_id,)).fetchone()
    if not row:
        return None
    d = dict(row)
    try:
        d["protocols"] = json.loads(d["protocols"])
    except (json.JSONDecodeError, TypeError):
        d["protocols"] = ["vless-ws-tls"]
    return d


def list_nodes(db):
    rows = db.execute("SELECT * FROM nodes ORDER BY country_code, node_name").fetchall()
    result = []
    for row in rows:
        d = dict(row)
        try:
            d["protocols"] = json.loads(d["protocols"])
        except (json.JSONDecodeError, TypeError):
            d["protocols"] = ["vless-ws-tls"]
        result.append(d)
    return result


def upsert_node(db, data):
    """Insert or update a node from API registration."""
    import hashlib
    node_id = data.get("id") or hashlib.sha256(data["server_ip"].encode()).hexdigest()[:12]

    # Build template from vless_link
    vless_link = data.get("vless_link", "")
    template = data.get("vless_link_template", "")
    if not template and vless_link:
        node_uuid = data.get("uuid", "")
        if node_uuid:
            template = vless_link.replace(node_uuid, "{uuid}")

    protocols = json.dumps(data.get("protocols", ["vless-ws-tls"]))

    db.execute(
        """INSERT INTO nodes
           (id, node_name, server_ip, cf_domain, country_code, country_name,
            city, isp, protocols, xray_version, vless_link, vless_link_template,
            ws_path, status, last_seen, installed_at)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'online', ?, ?)
           ON CONFLICT(id) DO UPDATE SET
            node_name=excluded.node_name, cf_domain=excluded.cf_domain,
            country_code=excluded.country_code, country_name=excluded.country_name,
            city=excluded.city, isp=excluded.isp, protocols=excluded.protocols,
            xray_version=excluded.xray_version, vless_link=excluded.vless_link,
            vless_link_template=excluded.vless_link_template, ws_path=excluded.ws_path,
            status='online', last_seen=excluded.last_seen""",
        (
            node_id,
            data.get("node_name", "Unknown"),
            data.get("server_ip", ""),
            data.get("cf_domain", ""),
            data.get("country_code", "XX"),
            data.get("country_name", "Unknown"),
            data.get("city", ""),
            data.get("isp", ""),
            protocols,
            data.get("xray_version", ""),
            vless_link,
            template,
            data.get("ws_path", "/ws"),
            datetime.now(timezone.utc).isoformat(),
            data.get("installed_at", ""),
        ),
    )
    db.commit()
    return node_id


def delete_node(db, node_id):
    db.execute("DELETE FROM traffic_logs WHERE node_id = ?", (node_id,))
    db.execute("DELETE FROM nodes WHERE id = ?", (node_id,))
    db.commit()


def update_node_heartbeat(db, node_id):
    db.execute(
        "UPDATE nodes SET last_seen = ?, status = 'online' WHERE id = ?",
        (datetime.now(timezone.utc).isoformat(), node_id),
    )
    db.commit()


# ======================== ACTIVE CLIENTS FOR NODES ========================


def get_active_clients(db):
    """Return list of {uuid, email} for all users who should have VPN access."""
    today = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    rows = db.execute(
        """SELECT u.id, u.uuid, u.tier, u.daily_traffic_limit_mb
           FROM users u
           WHERE u.status = 'active'
             AND (u.subscription_expires_at IS NULL
                  OR u.subscription_expires_at > datetime('now'))""",
    ).fetchall()

    clients = []
    for r in rows:
        # Check daily traffic for free users
        if r["tier"] == "free" and r["daily_traffic_limit_mb"] > 0:
            dt = db.execute(
                "SELECT total_bytes FROM daily_traffic WHERE user_id = ? AND date = ?",
                (r["id"], today),
            ).fetchone()
            if dt and dt["total_bytes"] >= r["daily_traffic_limit_mb"] * 1024 * 1024:
                continue  # Over limit

        clients.append({
            "id": r["uuid"],
            "email": f"u{r['id']}@panel",
        })
    return clients


# ======================== TRAFFIC ========================


def record_traffic(db, node_id, traffic_data):
    """Record traffic from a node heartbeat.
    traffic_data: dict of {email: {uplink: bytes, downlink: bytes}}
    """
    today = datetime.now(timezone.utc).strftime("%Y-%m-%d")

    for email, stats in traffic_data.items():
        # Parse user_id from email format "u123@panel"
        if not email.startswith("u") or "@" not in email:
            continue
        try:
            user_id = int(email.split("@")[0][1:])
        except (ValueError, IndexError):
            continue

        up = stats.get("uplink", 0)
        down = stats.get("downlink", 0)
        total = up + down

        if total <= 0:
            continue

        db.execute(
            """INSERT INTO traffic_logs (user_id, node_id, uplink_bytes, downlink_bytes)
               VALUES (?, ?, ?, ?)""",
            (user_id, node_id, up, down),
        )

        db.execute(
            """INSERT INTO daily_traffic (user_id, date, total_bytes)
               VALUES (?, ?, ?)
               ON CONFLICT(user_id, date) DO UPDATE SET
                total_bytes = total_bytes + ?""",
            (user_id, today, total, total),
        )

    db.commit()


def get_user_traffic_today(db, user_id):
    today = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    row = db.execute(
        "SELECT total_bytes FROM daily_traffic WHERE user_id = ? AND date = ?",
        (user_id, today),
    ).fetchone()
    return row["total_bytes"] if row else 0


# ======================== PAYMENTS ========================


def create_payment(db, user_id, amount, currency, days, invoice_id=None):
    db.execute(
        """INSERT INTO payments (user_id, amount, currency, crypto_invoice_id, days_added)
           VALUES (?, ?, ?, ?, ?)""",
        (user_id, amount, currency, invoice_id, days),
    )
    db.commit()
    return db.execute("SELECT last_insert_rowid()").fetchone()[0]


def confirm_payment(db, invoice_id):
    """Mark payment as paid and extend user subscription."""
    payment = db.execute(
        "SELECT * FROM payments WHERE crypto_invoice_id = ? AND status = 'pending'",
        (invoice_id,),
    ).fetchone()
    if not payment:
        return False

    db.execute(
        "UPDATE payments SET status = 'paid', paid_at = datetime('now') WHERE id = ?",
        (payment["id"],),
    )

    # Extend subscription and upgrade to VIP
    extend_subscription(db, payment["user_id"], payment["days_added"])
    vip_devices = int(get_setting(db, "vip_device_limit"))
    db.execute(
        """UPDATE users SET tier = 'vip', daily_traffic_limit_mb = 0,
           device_limit = ?, updated_at = datetime('now') WHERE id = ?""",
        (vip_devices, payment["user_id"]),
    )
    db.commit()
    return True


# ======================== REFERRAL STATS ========================


def get_referral_count(db, user_id):
    return db.execute(
        "SELECT COUNT(*) FROM referrals WHERE referrer_id = ?", (user_id,)
    ).fetchone()[0]


def get_referral_stats(db):
    """Top referrers for admin panel."""
    rows = db.execute(
        """SELECT u.id, u.nickname, u.referral_code,
                  COUNT(r.id) as ref_count,
                  COALESCE(SUM(r.bonus_days), 0) as total_bonus
           FROM users u
           LEFT JOIN referrals r ON r.referrer_id = u.id
           GROUP BY u.id
           HAVING ref_count > 0
           ORDER BY ref_count DESC
           LIMIT 50""",
    ).fetchall()
    return [dict(r) for r in rows]


# ======================== ADMIN STATS ========================


def get_dashboard_stats(db):
    total = count_users(db)
    free = count_users(db, tier="free")
    vip = count_users(db, tier="vip")
    blocked = count_users(db, status="blocked")
    active = db.execute(
        """SELECT COUNT(*) FROM users
           WHERE status = 'active'
             AND (subscription_expires_at IS NULL
                  OR subscription_expires_at > datetime('now'))"""
    ).fetchone()[0]
    nodes_total = db.execute("SELECT COUNT(*) FROM nodes").fetchone()[0]
    nodes_online = db.execute("SELECT COUNT(*) FROM nodes WHERE status = 'online'").fetchone()[0]
    revenue = db.execute(
        "SELECT COALESCE(SUM(amount), 0) FROM payments WHERE status = 'paid'"
    ).fetchone()[0]
    revenue_30d = db.execute(
        """SELECT COALESCE(SUM(amount), 0) FROM payments
           WHERE status = 'paid' AND paid_at > datetime('now', '-30 days')"""
    ).fetchone()[0]

    return {
        "total_users": total,
        "free_users": free,
        "vip_users": vip,
        "blocked_users": blocked,
        "active_users": active,
        "nodes_total": nodes_total,
        "nodes_online": nodes_online,
        "revenue_total": revenue,
        "revenue_30d": revenue_30d,
    }


# ======================== VLESS LINK GENERATION ========================


def generate_vless_links(db, user_uuid):
    """Generate VLESS links for a user across all online nodes."""
    nodes = db.execute(
        "SELECT * FROM nodes WHERE status = 'online' AND vless_link_template IS NOT NULL AND vless_link_template != ''"
    ).fetchall()

    links = []
    for node in nodes:
        template = node["vless_link_template"]
        link = template.replace("{uuid}", user_uuid)
        # Also replace {node_name} if present
        link = link.replace("{node_name}", node["node_name"])
        links.append({
            "node_name": node["node_name"],
            "country_code": node["country_code"],
            "country_name": node["country_name"],
            "city": node["city"],
            "link": link,
        })
    return links
