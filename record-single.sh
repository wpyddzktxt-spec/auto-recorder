#!/bin/bash
set -euo pipefail

MODEL="${1:?}"
PROVIDER="${2:?}"
HLS_URL="${3:?}"
MAX_DURATION="${4:-20400}"
WORK_DIR="/tmp/recording_${MODEL}"
STATE_DIR="${STATE_DIR:-/tmp/recorder-state}"
START_TIME=$(date +%s)
BOT_TOKEN="${BOT_TOKEN:-}"
CHAT_ID="${CHAT_ID:-}"
GITHUB_TOKEN="${GITHUB_TOKEN:-}"

send_tg() {
    local text="$1"
    local notify="${2:-false}"
    if [ -n "$BOT_TOKEN" ] && [ -n "$CHAT_ID" ]; then
        curl -s "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
            -d "chat_id=${CHAT_ID}" \
            --data-urlencode "text=${text}" \
            -d "disable_notification=${notify}" 2>/dev/null >/dev/null || true
    fi
}

publish_frame() {
    local frame="$1"
    [ -f "$frame" ] || return 1
    cp -f "$frame" "${STATE_DIR}/last_frame.jpg" 2>/dev/null || true
    if [ -n "${GITHUB_TOKEN:-}" ]; then
        bash "$(dirname "$0")/state-store.sh" "$frame" "last_frame.jpg" "rec ${MODEL}" \
            >/dev/null 2>&1 || true
    fi
}

# Step 0: validate the HLS URL is accessible
echo "[$(date -u +%H:%M:%S)] ${MODEL}: validating HLS URL..."
HLS_STATUS=$(curl -sI --max-time 10 "${HLS_URL}" 2>/dev/null | head -1 | grep -c '200\|302' || echo 0)
if [ "$HLS_STATUS" -eq 0 ]; then
    echo "[$(date -u +%H:%M:%S)] ${MODEL}: HLS URL unreachable — abort: ${HLS_URL:0:120}"
    exit 0
fi
echo "[$(date -u +%H:%M:%S)] ${MODEL}: HLS URL OK, starting capture loop"

echo "recording" > "${STATE_DIR}/state_${MODEL}" 2>/dev/null || true
mkdir -p "$WORK_DIR"
CHUNK_INDEX=0
TOTAL_BYTES=0
RETRY_COUNT=0
LAST_FRAME="${STATE_DIR}/last_frame.jpg"
NOTIFIED_START=false

# Fast mode: first 3 chunks are 60s each for quick-start models (JustKatrin)
FAST_CHUNKS=3
while true; do
    ELAPSED=$(( $(date +%s) - START_TIME ))
    [ "$ELAPSED" -ge "$MAX_DURATION" ] && break

    OUTFILE="${WORK_DIR}/${MODEL}_chunk_$(printf '%03d' $CHUNK_INDEX).mp4"
    if [ "$CHUNK_INDEX" -lt "$FAST_CHUNKS" ]; then
        CHUNK_DURATION=60
    else
        CHUNK_DURATION=600
    fi

    RECORD_OK=false

    # Try streamlink first (pip version, not apt)
    if streamlink --version >/dev/null 2>&1; then
        if timeout ${CHUNK_DURATION} streamlink --hls-live-edge 3 --retry-streams 2 --retry-max 2 --stdout "$HLS_URL" best 2>/tmp/sl_error_${MODEL}.log | \
            timeout ${CHUNK_DURATION} ffmpeg -y -i pipe:0 -c copy -movflags +faststart -f mp4 "$OUTFILE" 2>/dev/null; then
            if [ -f "$OUTFILE" ] && [ "$(stat -c%s "$OUTFILE" 2>/dev/null || echo 0)" -gt 1024 ]; then
                RECORD_OK=true
            fi
        fi
    fi

    # Fallback: ffmpeg direct HLS
    if [ "$RECORD_OK" != "true" ]; then
        if timeout ${CHUNK_DURATION} ffmpeg -y -reconnect 1 -reconnect_at_eof 1 -reconnect_streamed 1 -reconnect_delay_max 10 -i "$HLS_URL" -c copy -movflags +faststart -f mp4 "$OUTFILE" 2>/dev/null; then
            if [ -f "$OUTFILE" ] && [ "$(stat -c%s "$OUTFILE" 2>/dev/null || echo 0)" -gt 1024 ]; then
                RECORD_OK=true
            fi
        fi
    fi

    if [ "$RECORD_OK" = "true" ] && [ -f "$OUTFILE" ]; then
        CHUNK_SIZE=$(stat -c%s "$OUTFILE" 2>/dev/null || echo 0)
        if [ "$CHUNK_SIZE" -gt 1024 ]; then
        if [ "$NOTIFIED_START" != "true" ]; then
            send_tg "📹 ${MODEL} запись началась" "false"
            NOTIFIED_START=true
        fi
        ffmpeg -sseof -0.1 -i "$OUTFILE" -frames:v 1 -q:v 2 -y "$LAST_FRAME" 2>/dev/null || true
        publish_frame "$LAST_FRAME"
        FILE_SIZE=$(stat -c%s "$OUTFILE" 2>/dev/null || echo 0)
        if [ -n "$BOT_TOKEN" ] && [ -n "$CHAT_ID" ]; then
            if curl -s "https://api.telegram.org/bot${BOT_TOKEN}/sendVideo" \
                -F "chat_id=${CHAT_ID}" \
                -F "video=@${OUTFILE}" \
                -F "supports_streaming=true" 2>/dev/null | grep -q '"ok":true'; then
                TOTAL_BYTES=$((TOTAL_BYTES + FILE_SIZE))
                echo "[$(date -u +%H:%M:%S)] ${MODEL}: chunk ${CHUNK_INDEX} sent (${FILE_SIZE} bytes)"
                rm -f "$OUTFILE"
                CHUNK_INDEX=$((CHUNK_INDEX + 1))
                RETRY_COUNT=0
            else
                echo "[$(date -u +%H:%M:%S)] ${MODEL}: Telegram send failed, retrying"
                RETRY_COUNT=$((RETRY_COUNT + 1))
                sleep 10
            fi
        else
            # No Telegram credentials — just accumulate and clean up
            TOTAL_BYTES=$((TOTAL_BYTES + FILE_SIZE))
            echo "[$(date -u +%H:%M:%S)] ${MODEL}: chunk ${CHUNK_INDEX} saved (${FILE_SIZE} bytes)"
            rm -f "$OUTFILE"
            CHUNK_INDEX=$((CHUNK_INDEX + 1))
            RETRY_COUNT=0
            fi
        else
            echo "[$(date -u +%H:%M:%S)] ${MODEL}: chunk too small (${CHUNK_SIZE} bytes), skipping"
            rm -f "$OUTFILE"
        fi
    else
        rm -f "$OUTFILE"
        RETRY_COUNT=$((RETRY_COUNT + 1))
        echo "[$(date -u +%H:%M:%S)] ${MODEL}: capture failed (retry ${RETRY_COUNT}/5)"
        
        # Check if stream is still alive at the HLS level
        if ! curl -sI --max-time 10 "$HLS_URL" 2>/dev/null | head -1 | grep -q '200'; then
            echo "[$(date -u +%H:%M:%S)] ${MODEL}: HLS URL no longer accessible — stream ended"
            break
        fi
        sleep 5
    fi

    [ "$RETRY_COUNT" -ge 5 ] && break
done

# Cleanup
rm -rf "$WORK_DIR"
rm -f "${STATE_DIR}/state_${MODEL}" 2>/dev/null || true
rm -f /tmp/sl_error_${MODEL}.log 2>/dev/null || true

TOTAL_MB=$(( TOTAL_BYTES / 1048576 ))
TOTAL_MIN=$(( ($(date +%s) - START_TIME) / 60 ))

if [ "$NOTIFIED_START" = "true" ]; then
    send_tg "🔴 ${MODEL} offline. ${TOTAL_MB}MB за ${TOTAL_MIN}мин" "false"
else
    echo "[$(date -u +%H:%M:%S)] ${MODEL}: no video captured — nothing sent"
fi
