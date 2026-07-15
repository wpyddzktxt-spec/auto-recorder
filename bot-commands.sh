#!/bin/bash
set -euo pipefail
BOT_TOKEN="${BOT_TOKEN:?}"
CHAT_ID="${CHAT_ID:?}"
STATE_DIR="${STATE_DIR:-/tmp/recorder-state}"
OFFSET_FILE="${STATE_DIR}/bot_offset"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$STATE_DIR"
[ -f "$OFFSET_FILE" ] && OFFSET=$(cat "$OFFSET_FILE") || OFFSET=0

UPDATES=$(curl -s --max-time 10 "https://api.telegram.org/bot${BOT_TOKEN}/getUpdates?offset=${OFFSET}&timeout=3" 2>/dev/null)
echo "$UPDATES" | jq -r '.result[]? | "\(.update_id)|\(.message.chat.id // "")|\(.message.text // "")"' 2>/dev/null | while IFS='|' read -r update_id chat text; do
    [ -z "$chat" ] && continue
    [ "$chat" != "$CHAT_ID" ] && continue
    text_lower=$(echo "$text" | tr '[:upper:]' '[:lower:]')
    case "$text_lower" in
        /status|status)
            # JustKatrin (Stripchat) — official API detects private/p2p shows too
            # Fallback: go.xxxiijmp.com if official API is blocked (returns HTML)
            jk_official=$(curl -s --max-time 8 \
              "https://stripchat.com/api/front/v2/models/username/JustKatrin/cam" \
              -H "User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36" \
              -H "Accept: application/json" 2>/dev/null || echo "")
            if [ -n "$jk_official" ] && echo "$jk_official" | grep -q '^[[:space:]]*{'; then
              jk_is_live=$(echo "$jk_official" | jq -r '.user.user.isLive // false' 2>/dev/null)
              if [ "$jk_is_live" = "true" ]; then
                # Get viewers from go.xxxiijmp.com (may be 0 during private shows)
                jk_views=$(curl -s --max-time 5 \
                  "https://go.xxxiijmp.com/api/models?modelsList=JustKatrin&strict=1" 2>/dev/null | \
                  jq -r '.models[0].viewersCount // 0' 2>/dev/null || echo 0)
                jk="🟢 online (${jk_views} зр.)"
              else
                jk="🔴 оффлайн"
              fi
            else
              # Fallback: official API blocked — use go.xxxiijmp.com
              jk_data=$(curl -s --max-time 5 \
                "https://go.xxxiijmp.com/api/models?modelsList=JustKatrin&strict=1" 2>/dev/null || echo "")
              jk=$(echo "$jk_data" | jq -r '
                if (.count // 0) > 0 and .models[0].stream.url != null then
                  "🟢 online (\(.models[0].viewersCount // 0) зр.)"
                else "🔴 оффлайн" end' 2>/dev/null)
              [ -z "$jk" ] && jk="🔴 оффлайн"
            fi

            # moonmaiden (BongaCams) — AMF for isOnline, mybro API for viewers
            mn="🔴 оффлайн"
            mn_resp=$(curl -s --max-time 10 "https://bongacams.com/tools/amf.php?method=getRoomData&args[]=moonmaiden" \
              -H "User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36" \
              -H "Referer: https://bongacams.com/moonmaiden" \
              -H "X-Requested-With: XMLHttpRequest" 2>/dev/null || echo "")
            if echo "$mn_resp" | grep -q '"isOnline":true\|"isOnline": true'; then
              mn_views=$(echo "$mn_resp" | python3 -c 'import sys,json
try:
    d=json.loads(sys.stdin.read())
    v=(d.get("performerData") or {}).get("viewersCount") or 0
    print(int(v))
except Exception: pass' 2>/dev/null || echo 0)
              mn="🟢 online (${mn_views} зр.)"
            fi

            # Maddy_May (MyFreeCams) — WebSocket check
            mm_result=$(timeout 12 python3 "${SCRIPT_DIR}/check-mfc.py" 34721990 2>/dev/null || echo "offline")
            mm_status=$(echo "$mm_result" | cut -d'|' -f1)
            if [ "$mm_status" = "online" ]; then
              mm_views=$(echo "$mm_result" | cut -d'|' -f3)
              mm="🟢 online (${mm_views:-0} зр.)"
            else
              mm="🔴 оффлайн"
            fi

            resp="JustKatrin: ${jk}
moonmaiden: ${mn}
Maddy_May: ${mm}"
            ;;
        /models|models) resp="JustKatrin (Stripchat), moonmaiden (BongaCams), Maddy_May (MyFreeCams)" ;;
        /last|last) resp="записей пока нет" ;;
        /help|help|/start|start) resp="/status /models /last /help" ;;
        *) resp="? /help для команд" ;;
    esac
    curl -s "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
        -d "chat_id=${chat}" --data-urlencode "text=${resp}" 2>/dev/null >/dev/null
    echo "$update_id" > "$OFFSET_FILE"
done
[ -f "$OFFSET_FILE" ] && echo "$(($(cat "$OFFSET_FILE") + 1))" > "$OFFSET_FILE"
