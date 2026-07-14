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
    case "$text_lower" in
        /status|status)
            jk=$(curl -s --max-time 10 "https://go.xxxiijmp.com/api/models?modelsList=JustKatrin&strict=1" 2>/dev/null | jq -r '.models[0] | if .stream.online then "🟢 online (\(.viewersCount))" else "🔴 оффлайн" end' 2>/dev/null)
            resp="JustKatrin: ${jk:-🔴 оффлайн}
moonmaiden: 🔴 оффлайн"
            ;;
        /models|models) resp="JustKatrin, moonmaiden" ;;
        /last|last) resp="записей пока нет" ;;
        /help|help|/start|start) resp="/status /models /last /help" ;;
        *) resp="?" ;;
    esac
    curl -s "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
        -d "chat_id=${chat}" --data-urlencode "text=${resp}" -d "disable_notification=false" 2>/dev/null >/dev/null
    echo "$update_id" > "$OFFSET_FILE"
done
[ -f "$OFFSET_FILE" ] && echo "$(($(cat "$OFFSET_FILE") + 1))" > "$OFFSET_FILE"
