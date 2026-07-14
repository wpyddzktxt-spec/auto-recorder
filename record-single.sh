#!/bin/bash
set -euo pipefail

MODEL="${1:?}"
PROVIDER="${2:?}"
HLS_URL="${3:?}"
MAX_DURATION="${4:-20400}"
WORK_DIR="/tmp/recording_${MODEL}"
STATE_DIR="${STATE_DIR:-/tmp/recorder-state}"
START_TIME=$(date +%s)

send_tg() {
    local text="$1"
    local notify="${2:-false}"
    curl -s "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
        -d "chat_id=${CHAT_ID}" \
        --data-urlencode "text=${text}" \
        -d "disable_notification=${notify}" 2>/dev/null >/dev/null
}

publish_frame() {
    local frame="$1"
    [ -f "$frame" ] || return 1
    cp -f "$frame" "${STATE_DIR}/last_frame.jpg" 2>/dev/null || true
    if [ -n "${GH_TOKEN:-}" ]; then
        bash "$(dirname "$0")/state-store.sh" "$frame" "last_frame.jpg" "rec ${MODEL}" \
            >/dev/null 2>&1 || true
    fi
}

send_tg "📹 ${MODEL} запись началась" "false"
echo "recording" > "${STATE_DIR}/state_${MODEL}"
mkdir -p "$WORK_DIR"
CHUNK_INDEX=0
TOTAL_BYTES=0
RETRY_COUNT=0
LAST_FRAME="${STATE_DIR}/last_frame.jpg"

while true; do
    ELAPSED=$(( $(date +%s) - START_TIME ))
    [ "$ELAPSED" -ge "$MAX_DURATION" ] && break

    OUTFILE="${WORK_DIR}/${MODEL}_chunk_$(printf '%03d' $CHUNK_INDEX).mp4"
    CHUNK_DURATION=600

    RECORD_OK=false
    if streamlink --version >/dev/null 2>&1; then
        if timeout ${CHUNK_DURATION} streamlink --hls-live-edge 3 --retry-streams 3 --retry-max 3 --stdout "$HLS_URL" best 2>/dev/null | \
            timeout ${CHUNK_DURATION} ffmpeg -y -i pipe:0 -c copy -movflags +faststart -f mp4 "$OUTFILE" 2>/dev/null; then
            RECORD_OK=true
        fi
    fi

    if [ "$RECORD_OK" != "true" ]; then
        if timeout ${CHUNK_DURATION} ffmpeg -y -reconnect 1 -reconnect_at_eof 1 -reconnect_streamed 1 -reconnect_delay_max 10 -i "$HLS_URL" -c copy -movflags +faststart -f mp4 "$OUTFILE" 2>/dev/null; then
            RECORD_OK=true
        fi
    fi

    if [ "$RECORD_OK" = "true" ] && [ -f "$OUTFILE" ] && [ "$(stat -c%s "$OUTFILE" 2>/dev/null || echo 0)" -gt 1024 ]; then
        ffmpeg -sseof -0.1 -i "$OUTFILE" -frames:v 1 -q:v 2 -y "$LAST_FRAME" 2>/dev/null || true
        publish_frame "$LAST_FRAME"
        FILE_SIZE=$(stat -c%s "$OUTFILE")
        if curl -s "https://api.telegram.org/bot${BOT_TOKEN}/sendVideo" \
            -F "chat_id=${CHAT_ID}" \
            -F "video=@${OUTFILE}" \
            -F "supports_streaming=true" 2>/dev/null | grep -q '"ok":true'; then
            TOTAL_BYTES=$((TOTAL_BYTES + FILE_SIZE))
            rm -f "$OUTFILE"
            CHUNK_INDEX=$((CHUNK_INDEX + 1))
            RETRY_COUNT=0
        else
            RETRY_COUNT=$((RETRY_COUNT + 1))
            sleep 10
        fi
    else
        rm -f "$OUTFILE"
        RETRY_COUNT=$((RETRY_COUNT + 1))
        sleep 5
    fi

    [ "$RETRY_COUNT" -ge 5 ] && break
    if ! curl -sI --max-time 10 "$HLS_URL" 2>/dev/null | grep -q '200'; then
        break
    fi
done

rm -rf "$WORK_DIR"
rm -f "${STATE_DIR}/state_${MODEL}"
TOTAL_MB=$(( TOTAL_BYTES / 1048576 ))
TOTAL_MIN=$(( ($(date +%s) - START_TIME) / 60 ))
send_tg "🔴 ${MODEL} offline. ${TOTAL_MB}MB за ${TOTAL_MIN}мин" "false"
