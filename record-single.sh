#!/bin/bash
set -euo pipefail

MODEL="${1:?}"
PROVIDER="${2:?}"
HLS_URL="${3:?}"
MAX_DURATION="${4:-20400}"
CHUNK_SIZE_MB=48
WORK_DIR="/tmp/recording_${MODEL}"
STATE_DIR="${STATE_DIR:-/tmp/recorder-state}"
START_TIME=$(date +%s)
BOT_TOKEN="${BOT_TOKEN:?}"
CHAT_ID="${CHAT_ID:?}"

send_tg() {
    local text="$1"
    local notify="${2:-true}"
    curl -s "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
        -d "chat_id=${CHAT_ID}" \
        --data-urlencode "text=${text}" \
        -d "disable_notification=${notify}" 2>/dev/null
}

echo "[$(date)] Starting recording: $MODEL ($PROVIDER)"
send_tg "🟢 $MODEL — запись началась (${PROVIDER})" "false"
echo "recording" > "${STATE_DIR}/state_${MODEL}"

mkdir -p "$WORK_DIR"
CHUNK_INDEX=0
TOTAL_BYTES=0
RETRY_COUNT=0
MAX_RETRIES=5

while true; do
    ELAPSED=$(( $(date +%s) - START_TIME ))
    if [ "$ELAPSED" -ge "$MAX_DURATION" ]; then
        echo "[$(date)] Max duration reached"
        echo "duration" > "${STATE_DIR}/recording_ended_${MODEL}"
        break
    fi

    OUTFILE="${WORK_DIR}/${MODEL}_chunk_$(printf '%03d' $CHUNK_INDEX).mp4"
    CHUNK_DURATION=$(( (CHUNK_SIZE_MB * 1024 * 1024) / (500 * 1024) + 30 ))
    [ "$CHUNK_DURATION" -gt 600 ] && CHUNK_DURATION=600

    echo "[$(date)] Recording chunk $CHUNK_INDEX (target ${CHUNK_DURATION}s)"

    # Try streamlink first
    RECORD_OK=false
    if streamlink --version >/dev/null 2>&1; then
        if timeout ${CHUNK_DURATION} streamlink \
            --hls-live-edge 3 \
            --hls-segment-threads 3 \
            --hls-timeout 30 \
            --retry-streams 3 \
            --retry-max 3 \
            --stdout \
            "$HLS_URL" best 2>/tmp/sl_err_${MODEL}.log | \
            timeout ${CHUNK_DURATION} ffmpeg -y \
                -i pipe:0 \
                -c copy \
                -movflags +faststart \
                -f mp4 \
                "$OUTFILE" 2>/tmp/ffmpeg_err_${MODEL}.log; then
            RECORD_OK=true
        fi
    fi

    # Fallback to ffmpeg direct
    if [ "$RECORD_OK" != "true" ]; then
        echo "[$(date)] Streamlink failed, trying ffmpeg direct"
        if timeout ${CHUNK_DURATION} ffmpeg -y \
            -reconnect 1 -reconnect_at_eof 1 -reconnect_streamed 1 -reconnect_delay_max 10 \
            -i "$HLS_URL" \
            -c copy \
            -movflags +faststart \
            -f mp4 \
            "$OUTFILE" 2>/tmp/ffmpeg_err2_${MODEL}.log; then
            RECORD_OK=true
        fi
    fi

    if [ "$RECORD_OK" = "true" ] && [ -f "$OUTFILE" ] && [ -s "$OUTFILE" ]; then
        FILE_SIZE=$(stat -c%s "$OUTFILE" 2>/dev/null || echo 0)
        if [ "$FILE_SIZE" -gt 1024 ]; then
            echo "[$(date)] Chunk $CHUNK_INDEX: $(numfmt --to=iec $FILE_SIZE 2>/dev/null || echo ${FILE_SIZE}B)"

            # Send to Telegram
            if curl -s "https://api.telegram.org/bot${BOT_TOKEN}/sendVideo" \
                -F "chat_id=${CHAT_ID}" \
                -F "video=@${OUTFILE}" \
                -F "caption=${MODEL} #${CHUNK_INDEX} (${PROVIDER})" \
                -F "disable_notification=true" \
                -F "supports_streaming=true" 2>/dev/null | grep -q '"ok":true'; then
                echo "[$(date)] Sent chunk $CHUNK_INDEX to Telegram"
                TOTAL_BYTES=$((TOTAL_BYTES + FILE_SIZE))
                rm -f "$OUTFILE"
                CHUNK_INDEX=$((CHUNK_INDEX + 1))
                RETRY_COUNT=0
            else
                echo "[$(date)] Failed to send chunk, retrying..."
                RETRY_COUNT=$((RETRY_COUNT + 1))
                sleep 10
            fi
        else
            echo "[$(date)] Chunk too small (${FILE_SIZE}B), stream may be offline"
            rm -f "$OUTFILE"
            RETRY_COUNT=$((RETRY_COUNT + 1))
            sleep 5
        fi
    else
        echo "[$(date)] Recording failed (retry $RETRY_COUNT/$MAX_RETRIES)"
        RETRY_COUNT=$((RETRY_COUNT + 1))
        rm -f "$OUTFILE"
        sleep 10
    fi

    if [ "$RETRY_COUNT" -ge "$MAX_RETRIES" ]; then
        echo "[$(date)] Max retries reached, stream may be offline"
        echo "offline" > "${STATE_DIR}/recording_ended_${MODEL}"
        break
    fi

    # Brief check: is HLS still accessible?
    if ! curl -sI --max-time 10 "$HLS_URL" 2>/dev/null | grep -q 'HTTP.*200'; then
        echo "[$(date)] HLS URL no longer accessible"
        echo "offline" > "${STATE_DIR}/recording_ended_${MODEL}"
        break
    fi
done

# Cleanup
rm -rf "$WORK_DIR"
rm -f "${STATE_DIR}/state_${MODEL}"

TOTAL_DURATION=$(( $(date +%s) - START_TIME ))
TOTAL_MB=$(( TOTAL_BYTES / 1048576 ))
send_tg "🔴 $MODEL — запись завершена. Всего: ${TOTAL_MB}MB за $(( TOTAL_DURATION / 60 )) мин." "false"

echo "[$(date)] Recording finished: $MODEL (${TOTAL_MB}MB, ${TOTAL_DURATION}s)"
