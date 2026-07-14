#!/bin/bash
BOT_TOKEN="${BOT_TOKEN:?}"
CHAT_ID="${CHAT_ID:?}"
jk=$(curl -s --max-time 10 "https://go.xxxiijmp.com/api/models?modelsList=JustKatrin&strict=1" 2>/dev/null | jq -r '.models[0] | if .stream.online then "online" else "оффлайн" end' 2>/dev/null)
curl -s "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
    -d "chat_id=${CHAT_ID}" \
    --data-urlencode "text=💓 JK:${jk:-оффлайн} MM:оффлайн" \
    -d "disable_notification=true" 2>/dev/null >/dev/null
