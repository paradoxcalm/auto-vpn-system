#!/usr/bin/env python3
"""
JetsFlare — Telegram Bot
Runs as a separate systemd service, shares SQLite DB with the panel.
"""

import os
import sys
import logging
from datetime import datetime, timezone
from pathlib import Path

# Add parent dir for imports
sys.path.insert(0, str(Path(__file__).parent))

import models

try:
    from telegram import Update, InlineKeyboardButton, InlineKeyboardMarkup
    from telegram.ext import (
        Application, CommandHandler, CallbackQueryHandler, ContextTypes,
    )
except ImportError:
    print("python-telegram-bot not installed. Run: pip install python-telegram-bot>=21.0")
    sys.exit(1)

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
logger = logging.getLogger("bot")

BOT_TOKEN = os.environ.get("TELEGRAM_BOT_TOKEN", "")
DATA_DIR = Path(os.environ.get("DATA_DIR", "/opt/auto-vpn-panel/data"))
PANEL_URL = os.environ.get("PANEL_URL", "")

# Init DB
models.init_db(DATA_DIR)


def get_db():
    return models.get_db()


# ======================== /start ========================

async def start_handler(update: Update, context: ContextTypes.DEFAULT_TYPE):
    tg_id = update.effective_user.id
    tg_username = update.effective_user.username or ""

    db = get_db()
    user = models.get_user_by_telegram(db, tg_id)

    # Check for referral code in /start payload
    referral_code = None
    if context.args:
        arg = context.args[0]
        if arg.startswith("ref_"):
            referral_code = arg[4:]

    if user:
        # Existing user — show welcome back
        days = "--"
        if user["subscription_expires_at"]:
            d = (datetime.fromisoformat(user["subscription_expires_at"]) - datetime.now(timezone.utc)).days
            days = max(0, d)

        links = models.generate_vless_links(db, user["uuid"])
        link_text = "\n".join([f"  {l['country_name']}: `{l['link']}`" for l in links[:5]])
        if not link_text:
            link_text = "  No servers available yet"

        text = (
            f"Welcome back, *{user['nickname']}*!\n\n"
            f"Tier: *{user['tier'].upper()}*\n"
            f"Days left: *{days}*\n"
            f"Access code: `{user['referral_code']}`\n\n"
            f"Your configs:\n{link_text}\n\n"
            f"Commands: /status /config /referral /pay"
        )
        db.close()
        await update.message.reply_text(text, parse_mode="Markdown")
        return

    # New user — register
    nickname = update.effective_user.first_name or f"User{tg_id}"
    try:
        user = models.create_user(
            db, nickname,
            referral_code_used=referral_code,
            telegram_id=tg_id,
            telegram_username=tg_username,
        )
    except Exception as e:
        db.close()
        await update.message.reply_text(f"Registration error: {e}")
        return

    links = models.generate_vless_links(db, user["uuid"])
    link_text = "\n".join([f"  {l['country_name']}: `{l['link']}`" for l in links[:5]])
    if not link_text:
        link_text = "  Servers are being configured, try /config in a few minutes"

    trial_days = models.get_setting(db, "trial_days")
    db.close()

    text = (
        f"Welcome to *JetsFlare*! ⚡\n\n"
        f"Your *{trial_days}-day free trial* is active!\n\n"
        f"Access code (save it!): `{user['referral_code']}`\n\n"
        f"Connection profiles:\n{link_text}\n\n"
        f"How to connect:\n"
        f"1. Copy a config link above\n"
        f"2. Open Streisand (iOS) or v2rayNG (Android)\n"
        f"3. Paste from clipboard\n\n"
        f"Share your referral link to get +5 free days per invite!\n"
        f"/referral — get your link\n"
        f"/status — check subscription\n"
        f"/pay — upgrade to VIP"
    )
    await update.message.reply_text(text, parse_mode="Markdown")


# ======================== /status ========================

async def status_handler(update: Update, context: ContextTypes.DEFAULT_TYPE):
    db = get_db()
    user = models.get_user_by_telegram(db, update.effective_user.id)
    if not user:
        db.close()
        await update.message.reply_text("You're not registered. Send /start to begin.")
        return

    days = "--"
    if user["subscription_expires_at"]:
        d = (datetime.fromisoformat(user["subscription_expires_at"]) - datetime.now(timezone.utc)).days
        days = max(0, d)

    traffic = models.get_user_traffic_today(db, user["id"])
    traffic_mb = round(traffic / 1024 / 1024, 1)
    limit_mb = user["daily_traffic_limit_mb"]
    ref_count = models.get_referral_count(db, user["id"])
    db.close()

    limit_str = f"{limit_mb} MB" if limit_mb > 0 else "Unlimited"

    text = (
        f"*{user['nickname']}* — {user['tier'].upper()}\n\n"
        f"Status: *{user['status']}*\n"
        f"Days left: *{days}*\n"
        f"Devices: *{user['device_limit']}*\n"
        f"Traffic today: *{traffic_mb} MB* / {limit_str}\n"
        f"Referrals: *{ref_count}*\n"
        f"Code: `{user['referral_code']}`"
    )
    await update.message.reply_text(text, parse_mode="Markdown")


# ======================== /config ========================

async def config_handler(update: Update, context: ContextTypes.DEFAULT_TYPE):
    db = get_db()
    user = models.get_user_by_telegram(db, update.effective_user.id)
    if not user:
        db.close()
        await update.message.reply_text("Not registered. Send /start")
        return

    links = models.generate_vless_links(db, user["uuid"])
    db.close()

    if not links:
        await update.message.reply_text("No servers available. Try again later.")
        return

    # Send each link as a separate message for easy copying
    for link in links:
        flag = ""
        cc = link.get("country_code", "")
        if cc and len(cc) == 2:
            flag = chr(0x1F1E6 + ord(cc[0].upper()) - ord("A")) + chr(0x1F1E6 + ord(cc[1].upper()) - ord("A"))

        text = f"{flag} *{link['node_name']}*\n`{link['link']}`"
        await update.message.reply_text(text, parse_mode="Markdown")


# ======================== /referral ========================

async def referral_handler(update: Update, context: ContextTypes.DEFAULT_TYPE):
    db = get_db()
    user = models.get_user_by_telegram(db, update.effective_user.id)
    if not user:
        db.close()
        await update.message.reply_text("Not registered. Send /start")
        return

    ref_count = models.get_referral_count(db, user["id"])
    bonus_days = int(models.get_setting(db, "referral_bonus_days"))
    db.close()

    bot_username = (await context.bot.get_me()).username
    deep_link = f"https://t.me/{bot_username}?start=ref_{user['referral_code']}"
    web_link = f"{PANEL_URL}/go?ref={user['referral_code']}" if PANEL_URL else ""

    text = (
        f"*Share & earn free days!*\n\n"
        f"Each friend you invite = *+{bonus_days} days* for you!\n\n"
        f"Your referral link:\n`{deep_link}`\n"
    )
    if web_link:
        text += f"\nWeb link:\n`{web_link}`\n"

    text += (
        f"\nReferrals so far: *{ref_count}*\n"
        f"Total bonus: *{ref_count * bonus_days} days*"
    )
    await update.message.reply_text(text, parse_mode="Markdown")


# ======================== /pay ========================

async def pay_handler(update: Update, context: ContextTypes.DEFAULT_TYPE):
    db = get_db()
    user = models.get_user_by_telegram(db, update.effective_user.id)
    if not user:
        db.close()
        await update.message.reply_text("Not registered. Send /start")
        return

    price = models.get_setting(db, "vip_price_usdt")
    duration = models.get_setting(db, "vip_duration_days")
    db.close()

    keyboard = [
        [InlineKeyboardButton(f"Pay ${price} USDT ({duration} days)", callback_data=f"pay_USDT_{price}")],
        [InlineKeyboardButton(f"Pay in TON ({duration} days)", callback_data=f"pay_TON_{price}")],
    ]
    reply_markup = InlineKeyboardMarkup(keyboard)

    text = (
        f"*Upgrade to VIP*\n\n"
        f"Unlimited traffic, more devices, full speed\n\n"
        f"Price: *${price}* for *{duration} days*"
    )
    await update.message.reply_text(text, parse_mode="Markdown", reply_markup=reply_markup)


async def pay_callback(update: Update, context: ContextTypes.DEFAULT_TYPE):
    query = update.callback_query
    await query.answer()

    parts = query.data.split("_")
    if len(parts) < 3 or parts[0] != "pay":
        return

    currency = parts[1]

    db = get_db()
    user = models.get_user_by_telegram(db, query.from_user.id)
    if not user:
        db.close()
        await query.edit_message_text("Not registered. Send /start")
        return

    price = float(models.get_setting(db, "vip_price_usdt"))
    days = int(models.get_setting(db, "vip_duration_days"))

    try:
        from crypto_pay import create_invoice
        result = create_invoice(
            amount=price,
            currency=currency,
            description=f"JetsFlare VIP {days} days",
            payload=f'{{"user_id": {user["id"]}, "days": {days}}}',
        )
    except ImportError:
        db.close()
        await query.edit_message_text("Payment system not configured yet.")
        return

    if not result:
        db.close()
        await query.edit_message_text("Could not create invoice. Try again later.")
        return

    models.create_payment(db, user["id"], price, currency, days, invoice_id=str(result["invoice_id"]))
    db.close()

    keyboard = [[InlineKeyboardButton("Pay Now", url=result["pay_url"])]]
    await query.edit_message_text(
        f"Invoice created! Click the button to pay.\n\nAfter payment, your VIP will be activated automatically.",
        reply_markup=InlineKeyboardMarkup(keyboard),
    )


# ======================== /help ========================

async def help_handler(update: Update, context: ContextTypes.DEFAULT_TYPE):
    text = (
        "*JetsFlare Bot* ⚡\n\n"
        "/start — Register or view your account\n"
        "/status — Check subscription & traffic\n"
        "/config — Get connection profiles\n"
        "/referral — Share & earn free days\n"
        "/pay — Upgrade to VIP\n"
        "/help — This message"
    )
    await update.message.reply_text(text, parse_mode="Markdown")


# ======================== Main ========================

def main():
    if not BOT_TOKEN:
        logger.error("TELEGRAM_BOT_TOKEN not set!")
        sys.exit(1)

    logger.info("Starting JetsFlare Telegram bot...")

    app = Application.builder().token(BOT_TOKEN).build()

    app.add_handler(CommandHandler("start", start_handler))
    app.add_handler(CommandHandler("status", status_handler))
    app.add_handler(CommandHandler("config", config_handler))
    app.add_handler(CommandHandler("referral", referral_handler))
    app.add_handler(CommandHandler("pay", pay_handler))
    app.add_handler(CommandHandler("help", help_handler))
    app.add_handler(CallbackQueryHandler(pay_callback, pattern=r"^pay_"))

    app.run_polling(drop_pending_updates=True)


if __name__ == "__main__":
    main()
