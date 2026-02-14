# Auto VPN System

Автоматическая система развёртывания VPN-серверов с централизованным управлением.

**Один скрипт** — и сервер готов. Ключи автоматически отправляются на центральную панель.

## Архитектура

```
  ┌──────────────────────────────────────────────────┐
  │             CENTRAL PANEL (1 сервер)              │
  │         Web UI + API для сбора ключей             │
  │        http://your-panel.com                      │
  └────────────┬──────────┬──────────┬────────────────┘
               │          │          │
       ┌───────▼──┐ ┌─────▼────┐ ┌──▼───────┐
       │ 🇩🇪 DE    │ │ 🇳🇱 NL    │ │ 🇫🇮 FI    │   ...
       │ Frankfurt │ │Amsterdam │ │ Helsinki │
       │ VLESS+    │ │ VLESS+   │ │ VLESS+   │
       │ REALITY   │ │ REALITY  │ │ HY2      │
       └──────────┘ └──────────┘ └──────────┘
         VPN Nodes (автоустановка на каждом)
```

## Быстрый старт

### 1. Установи центральную панель (на одном сервере)

```bash
# Скачай и запусти
curl -sSL https://raw.githubusercontent.com/paradoxcalm/auto-vpn-system/main/web/install-panel.sh | bash -s -- --domain panel.example.com
```

После установки ты получишь **API_KEY** — запомни его.

### 2. Добавляй VPN-ноды (на каждом сервере)

```bash
# Базовая установка: VLESS + REALITY
curl -sSL https://raw.githubusercontent.com/paradoxcalm/auto-vpn-system/main/install.sh | bash -s -- \
  --api-url https://panel.example.com \
  --api-key YOUR_API_KEY

# Полная установка: VLESS + REALITY + Hysteria2 + WARP
curl -sSL https://raw.githubusercontent.com/paradoxcalm/auto-vpn-system/main/install.sh | bash -s -- \
  --api-url https://panel.example.com \
  --api-key YOUR_API_KEY \
  --hysteria \
  --warp
```

Скрипт автоматически:
- Определит страну и город сервера
- Установит Xray-core (последняя версия)
- Настроит VLESS + REALITY + Vision
- Сгенерирует ключи (x25519, UUID, shortId)
- Включит TCP BBR оптимизацию
- Настроит UFW + fail2ban
- Отправит ключ на центральную панель
- Покажет QR-код и ссылку для клиента

### 3. Подключайся

Открой панель — там все серверы с флагами стран и кнопками копирования.

**Клиенты:**
- Android: [v2rayNG](https://github.com/2dust/v2rayNG), [Hiddify](https://github.com/hiddify/hiddify-app)
- iOS: [Streisand](https://apps.apple.com/app/streisand/id6450534064), [V2Box](https://apps.apple.com/app/v2box-v2ray-client/id6446814690)
- Windows: [Hiddify](https://github.com/hiddify/hiddify-app), [v2rayN](https://github.com/2dust/v2rayN)
- macOS: [Hiddify](https://github.com/hiddify/hiddify-app), [V2rayU](https://github.com/yanue/V2rayU)

## Опции install.sh

| Флаг | Описание |
|------|----------|
| `--api-url URL` | URL центральной панели |
| `--api-key KEY` | API ключ для авторизации |
| `--sni DOMAIN` | SNI домен для REALITY (по умолчанию: авто) |
| `--port PORT` | Порт VLESS (по умолчанию: 443) |
| `--hysteria` | Также установить Hysteria2 (UDP/QUIC) |
| `--warp` | Настроить Cloudflare WARP outbound |
| `--panel` | Установить 3X-UI веб-панель |
| `--name NAME` | Своё имя ноды (по умолчанию: авто из гео) |
| `--no-report` | Не отправлять ключ на панель |

## Протоколы

| Протокол | Транспорт | Использование |
|----------|-----------|---------------|
| **VLESS + REALITY + Vision** | TCP | Основной — неотличим от HTTPS |
| **Hysteria2** | UDP/QUIC | Для видео/стриминга — максимальная скорость |
| **WARP outbound** | WireGuard | Скрывает IP сервера от конечных сайтов |

## Управление

```bash
# На VPN ноде:
systemctl status xray           # Статус Xray
systemctl restart xray          # Перезапуск
journalctl -u xray -f           # Логи
bash /opt/auto-vpn/add-user.sh  # Добавить пользователя

# На панели:
systemctl status auto-vpn-panel
cat /opt/auto-vpn-panel/.env    # API ключ
```

## Структура проекта

```
auto-vpn-system/
├── install.sh              # Главный установщик VPN-ноды
├── web/
│   ├── install-panel.sh    # Установщик центральной панели
│   ├── app.py              # Flask API + Web UI
│   ├── requirements.txt
│   └── templates/
│       └── index.html      # Веб-интерфейс панели
├── scripts/
│   ├── add-user.sh         # Добавление пользователя
│   ├── heartbeat.sh        # Cron-скрипт проверки ноды
│   └── uninstall.sh        # Удаление
└── README.md
```

## Требования

- **VPN ноды:** Ubuntu 22.04 или 24.04, root доступ
- **Панель:** Ubuntu 22.04/24.04, домен (опционально)
- **Минимум:** 512 MB RAM, 1 CPU

## Безопасность

- Xray работает от пользователя `nobody`
- UFW: открыты только нужные порты
- fail2ban: защита SSH от брутфорса
- TCP BBR: оптимизация скорости
- x25519 ключи: квантово-устойчивое шифрование
- REALITY: трафик неотличим от обычного HTTPS
