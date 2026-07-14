#!/bin/bash
set -euo pipefail

BOT_TOKEN="${BOT_TOKEN:?}"
CHAT_ID="${CHAT_ID:?}"
STATE_DIR="${STATE_DIR:-/tmp/recorder-state}"
FILTER_MODEL="${1:-}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

mkdir -p "$STATE_DIR"

send_tg() {
    local text="$1"
    local notify="${2:-true}"
    curl -s "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
        -d "chat_id=${CHAT_ID}" \
        --data-urlencode "text=${text}" \
        -d "disable_notification=${notify}" 2>/dev/null >/dev/null
}

send_photo_file() {
    local file="$1"
    local caption="$2"
    [ -f "$file" ] || return 1
    curl -s "https://api.telegram.org/bot${BOT_TOKEN}/sendPhoto" \
        -F "chat_id=${CHAT_ID}" \
        -F "photo=@${file}" \
        -F "caption=${caption}" 2>/dev/null >/dev/null
}

send_photo_url() {
    local url="$1"
    local caption="$2"
    [ -n "$url" ] || return 1
    curl -s "https://api.telegram.org/bot${BOT_TOKEN}/sendPhoto" \
        -F "chat_id=${CHAT_ID}" \
        -F "photo=${url}" \
        -F "caption=${caption}" 2>/dev/null >/dev/null
}

# Extract first frame from HLS as preview
extract_frame_from_hls() {
    local url="$1"
    local out="$2"
    timeout 20 ffmpeg -y -i "$url" -frames:v 1 -q:v 3 -ss 2 -vf "scale=480:-1" "$out" 2>/dev/null || true
    [ -s "$out" ]
}

publish_frame() {
    local frame="$1"
    [ -f "$frame" ] || return 1
    cp -f "$frame" "${STATE_DIR}/last_frame.jpg" 2>/dev/null || true
    if [ -n "${GITHUB_TOKEN:-}" ] && [ -x "${SCRIPT_DIR}/state-store.sh" ]; then
        bash "${SCRIPT_DIR}/state-store.sh" "$frame" "last_frame.jpg" "preview update" \
            >/dev/null 2>&1 || true
    fi
}

check_stripchat() {
    local model="$1"
    local data
    data=$(curl -s --max-time 15 "https://go.xxxiijmp.com/api/models?modelsList=${model}&strict=1" 2>/dev/null)
    local status
    status=$(echo "$data" | jq -r '
        if .models and (.models | length > 0) then
            .models[0] | if .stream.online then "online|\(.stream.url // "")|\(.viewersCount // 0)|\(.snapshotUrl // "")|\(.previewUrl // "")" else "offline" end
        else "offline" end' 2>/dev/null)
    echo "$status"
}

check_bongacams() {
    local model="$1"
    local amf_resp
    amf_resp=$(curl -s --max-time 15 -X POST 'https://bongacams.com/tools/amf.php?x-country=en' \
        -H 'User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36' \
        -H 'Origin: https://bongacams.com' \
        -H 'Referer: https://bongacams.com/' \
        -d "method=getRoomData&args[]=${model}&args[]=false" 2>/dev/null)

    if echo "$amf_resp" | grep -q '"status":"success"'; then
        local hls_url viewers
        hls_url=$(echo "$amf_resp" | grep -oP '"videoServerUrl":"[^"]*"' | head -1 | sed 's/"videoServerUrl":"//;s/"//')
        viewers=$(echo "$amf_resp" | grep -oP '"viewersCount":\d+' | head -1 | sed '"s/"viewersCount"://')
        if [ -n "$hls_url" ]; then
            echo "online|${hls_url}/hls/stream_${model}/playlist.m3u8|${viewers:-0}||"
            return
        fi
    fi
    echo "offline"
}

while IFS='|' read -r model provider method; do
    [[ -z "$model" || "$model" =~ ^# ]] && continue
    model=$(echo "$model" | xargs)
    provider=$(echo "$provider" | xargs)
    [ -n "$FILTER_MODEL" ] && [ "$model" != "$FILTER_MODEL" ] && continue

    if [ -f "${STATE_DIR}/state_${model}" ]; then
        continue
    fi

    prev_state_file="${STATE_DIR}/prev_${model}"
    prev_state="offline"
    [ -f "$prev_state_file" ] && prev_state=$(cat "$prev_state_file")

    result="offline"
    case "$provider" in
        stripchat) result=$(check_stripchat "$model") ;;
        bongacams) result=$(check_bongacams "$model") ;;
        *) continue ;;
    esac

    status=$(echo "$result" | cut -d'|' -f1)
    echo "$status" > "$prev_state_file"

    if [ "$status" = "online" ]; then
        hls_url=$(echo "$result" | cut -d'|' -f2)
        viewers=$(echo "$result" | cut -d'|' -f3)
        snapshot=$(echo "$result" | cut -d'|' -f4)
        preview=$(echo "$result" | cut -d'|' -f5)

        if [ "$prev_state" != "online" ]; then
            # Just went online — notify with screenshot
            local_frame="${STATE_DIR}/preview_${model}.jpg"
            sent=0
            # Try API snapshot/preview first
            photo_url="${snapshot:-${preview}}"
            if [ -n "$photo_url" ] && [ "$photo_url" != "null" ] && [ "$photo_url" != "" ]; then
                if send_photo_url "$photo_url" "🟢 ${model} online (${viewers} зр.)"; then
                    sent=1
                fi
            fi
            # Fallback: extract frame from HLS
            if [ "$sent" -eq 0 ] && [ -n "$hls_url" ]; then
                if extract_frame_from_hls "$hls_url" "$local_frame"; then
                    publish_frame "$local_frame"
                    send_photo_file "$local_frame" "🟢 ${model} online (${viewers} зр.)"
                    sent=1
                fi
            fi
            # Fallback: text only
            if [ "$sent" -eq 0 ]; then
                send_tg "🟢 ${model} online (${viewers} зр.)" "false"
            fi

            # Trigger recording
            if [ -n "$hls_url" ]; then
                if [ -n "${GITHUB_TOKEN:-}" ]; then
                    curl -s -X POST -H "Authorization: Bearer ${GITHUB_TOKEN}" \
                        -H "Accept: application/vnd.github+json" \
                        "https://api.github.com/repos/${GITHUB_REPOSITORY}/actions/workflows/record.yml/dispatches" \
                        -d "{\"ref\":\"main\",\"inputs\":{\"model\":\"${model}\",\"provider\":\"${provider}\",\"hls_url\":\"${hls_url}\"}}" 2>/dev/null >/dev/null
                fi
            fi
        fi
    else
        if [ "$prev_state" = "online" ]; then
            send_tg "🔴 ${model} offline" "false"
        fi
    fi
done < models.txt
