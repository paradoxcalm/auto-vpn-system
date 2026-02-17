"""
JetsFlare — CryptoBot (Crypto Pay) Integration
https://help.send.tg/en/articles/10279948-crypto-pay-api
"""

import os
import hashlib
import hmac
import json
import requests

API_TOKEN = os.environ.get("CRYPTOBOT_API_TOKEN", "")
TESTNET = os.environ.get("CRYPTOBOT_TESTNET", "false").lower() == "true"

BASE_URL = "https://testnet-pay.crypt.bot/api" if TESTNET else "https://pay.crypt.bot/api"


def _headers():
    return {
        "Crypto-Pay-API-Token": API_TOKEN,
        "Content-Type": "application/json",
    }


def create_invoice(amount, currency="USDT", description="", payload=""):
    """Create a CryptoBot invoice. Returns {invoice_id, pay_url} or None."""
    if not API_TOKEN:
        return None

    try:
        resp = requests.post(
            f"{BASE_URL}/createInvoice",
            headers=_headers(),
            json={
                "asset": currency,
                "amount": str(amount),
                "description": description,
                "payload": payload,
                "paid_btn_name": "callback",
                "paid_btn_url": os.environ.get("PANEL_URL", ""),
            },
            timeout=15,
        )
        data = resp.json()
        if data.get("ok"):
            result = data["result"]
            return {
                "invoice_id": result["invoice_id"],
                "pay_url": result["pay_url"],
            }
    except Exception:
        pass
    return None


def verify_webhook(body_bytes, signature):
    """Verify CryptoBot webhook signature (HMAC-SHA-256)."""
    if not API_TOKEN or not signature:
        return False
    secret = hashlib.sha256(API_TOKEN.encode()).digest()
    expected = hmac.new(secret, body_bytes, hashlib.sha256).hexdigest()
    return hmac.compare_digest(expected, signature)


def get_invoice(invoice_id):
    """Get invoice details from CryptoBot."""
    if not API_TOKEN:
        return None
    try:
        resp = requests.post(
            f"{BASE_URL}/getInvoices",
            headers=_headers(),
            json={"invoice_ids": str(invoice_id)},
            timeout=15,
        )
        data = resp.json()
        if data.get("ok") and data["result"]["items"]:
            return data["result"]["items"][0]
    except Exception:
        pass
    return None
