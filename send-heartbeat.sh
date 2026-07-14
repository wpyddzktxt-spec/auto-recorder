#!/bin/bash
set -euo pipefail

BOT_TOKEN="${BOT_TOKEN:?}"
CHAT_ID="${CHAT_ID:?}"

# Check JustKatrin
jk=$(curl -s --max-time 10 "https://go.xxxiijmp.com/api/models?modelsList=JustKatrin&strict=1" 2>/dev/null | jq -r '
    if .models and (.models | length > 0) then
        .models[0] | if .stream.online then "🟢 Онлайн (\(.viewersCount // 0) зр.)" else "🔴 Офлайн" end
    else "🔴 Офлайн" end' 2>/dev/null)

# Check records dir for recent activity
RECENT=""
if [ -d /tmp/recording_* ] 2>/dev/null; then
    RECENT="📹 Идёт запись!"
else
    RECENT="💤 Запись не активна"
fi

MSG="💓 Heartbeat $(date -u '+%H:%M UTC')
JustKatrin: ${jk:-🔴 Офлайн}
moonmaiden: 🔴 Офлайн (BongaCams)
${RECENT}"

curl -s "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
    -d "chat_id=${CHAT_ID}" \
    --data-urlencode "text=${MSG}" \
    -d "disable_notification=true" 2>/dev/null

echo "[$(date)] Heartbeat sent"
