#!/bin/bash
set -euo pipefail

BOT_TOKEN="${BOT_TOKEN:?}"
CHAT_ID="${CHAT_ID:?}"
STATE_DIR="${STATE_DIR:-/tmp/recorder-state}"
HEALTH_FILE="${STATE_DIR}/last_health"
NOW=$(date +%s)

mkdir -p "$STATE_DIR"

if [ -f "$HEALTH_FILE" ]; then
    LAST=$(cat "$HEALTH_FILE")
    GAP=$((NOW - LAST))
    if [ "$GAP" -gt 1200 ]; then
        curl -s "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
            -d "chat_id=${CHAT_ID}" \
            -d "text=⚠️ Система не проверялась ${GAP} секунд. Возможна проблема с GitHub Actions." \
            -d "disable_notification=false" 2>/dev/null
    fi
fi

echo "$NOW" > "$HEALTH_FILE"
echo "[$(date)] Health check OK"
