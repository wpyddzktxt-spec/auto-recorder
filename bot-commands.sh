#!/bin/bash
set -euo pipefail

BOT_TOKEN="${BOT_TOKEN:?}"
CHAT_ID="${CHAT_ID:?}"
STATE_DIR="${STATE_DIR:-/tmp/recorder-state}"
OFFSET_FILE="${STATE_DIR}/bot_offset"

mkdir -p "$STATE_DIR"
[ -f "$OFFSET_FILE" ] && OFFSET=$(cat "$OFFSET_FILE") || OFFSET=0

UPDATES=$(curl -s --max-time 10 "https://api.telegram.org/bot${BOT_TOKEN}/getUpdates?offset=${OFFSET}&timeout=3" 2>/dev/null)

echo "$UPDATES" | jq -r '.result[]? | "\(.update_id)|\(.message.chat.id // "")|\(.message.text // "")"' 2>/dev/null | while IFS='|' read -r update_id chat text; do
    [ -z "$chat" ] && continue
    [ "$chat" != "$CHAT_ID" ] && continue

    text_lower=$(echo "$text" | tr '[:upper:]' '[:lower:]')
    resp=""

    case "$text_lower" in
        /status|status)
            jk=$(curl -s --max-time 10 "https://go.xxxiijmp.com/api/models?modelsList=JustKatrin&strict=1" 2>/dev/null | jq -r '
                if .models and (.models | length > 0) then
                    .models[0] | if .stream.online then "🟢 Онлайн (\(.viewersCount) зрителей)" else "🔴 Офлайн" end
                else "🔴 Офлайн" end' 2>/dev/null)
            bc_status="🔴 Офлайн"
            resp="JustKatrin: ${jk:-🔴 Офлайн}
moonmaiden: ${bc_status}"
            ;;
        /models|models)
            resp="📋 Модели на мониторинге:
• JustKatrin (Stripchat)
• moonmaiden (BongaCams)
Проверка каждые 5 минут, запись → Telegram"
            ;;
        /last|last)
            resp="📹 Статистика пока недоступна. Бот только запущен."
            ;;
        /help|help|/start|start)
            resp="🤖 Бот авто-записи стримов

Команды:
/status — Статус моделей
/models — Список моделей
/last — Последние записи

Запись запускается автоматически при появлении модели онлайн."
            ;;
        *)
            resp="Неизвестная команда. Используйте: /status /models /last /help"
            ;;
    esac

    if [ -n "$resp" ]; then
        curl -s "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
            -d "chat_id=${chat}" \
            --data-urlencode "text=${resp}" \
            -d "disable_notification=false" 2>/dev/null
        echo "[$(date)] Responded to ${chat}: ${text}"
    fi

    echo "$update_id" > "$OFFSET_FILE"
done

# Update offset to last processed + 1
if [ -f "$OFFSET_FILE" ]; then
    NEW_OFFSET=$(($(cat "$OFFSET_FILE") + 1))
    echo "$NEW_OFFSET" > "$OFFSET_FILE"
fi
