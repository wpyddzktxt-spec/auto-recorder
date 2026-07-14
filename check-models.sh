#!/bin/bash
set -euo pipefail

BOT_TOKEN="${BOT_TOKEN:?}"
CHAT_ID="${CHAT_ID:?}"
STATE_DIR="${STATE_DIR:-/tmp/recorder-state}"
FILTER_MODEL="${1:-}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

mkdir -p "$STATE_DIR"

# ---------- logging ----------
LOG="/tmp/recorder-state/check.log"
exec 2> >(tee -a "$LOG" >&2)

# cross-runner persistent state file (lives on 'state' branch)
PERSIST_FILE="check_state.json"

log() { echo "[$(date -u +%H:%M:%S)] $*"; }

# Load persistent state from 'state' branch; fall back to empty {}.
# IMPORTANT: redirect state-fetch.sh's stdout to /dev/null — it prints
# informational "OK: fetched N bytes" lines that would otherwise be
# captured here and break jq parsing of PSTATE (causes exit 5 on runs
# after the first one when the state file exists).
load_state() {
  if [ -n "${GITHUB_TOKEN:-}" ]; then
    bash "${SCRIPT_DIR}/state-fetch.sh" "$PERSIST_FILE" "$STATE_DIR/$PERSIST_FILE" >/dev/null 2>&1 || true
  fi
  if [ -f "$STATE_DIR/$PERSIST_FILE" ]; then
    cat "$STATE_DIR/$PERSIST_FILE"
  else
    echo '{}'
  fi
}

# Save persistent state to 'state' branch
save_state() {
  local content="$1"
  echo "$content" > "$STATE_DIR/$PERSIST_FILE"
  if [ -n "${GITHUB_TOKEN:-}" ]; then
    bash "${SCRIPT_DIR}/state-store.sh" "$STATE_DIR/$PERSIST_FILE" "$PERSIST_FILE" "check state" \
      >/dev/null 2>&1 || true
  fi
}
# Note: state-store.sh also has its own status messages to stdout; the
# >/dev/null 2>&1 above already swallows them.

# Update a single key in the persistent state JSON
# usage: update_state KEY VALUE JSON
# returns: updated JSON
update_state() {
  local key="$1" value="$2" json="$3"
  echo "$json" | jq -c --arg k "$key" --arg v "$value" '.[$k] = $v' 2>/dev/null || echo "$json"
}

send_tg() {
    local text="$1"
    local notify="${2:-true}"
    log "  TG: $text (notify=$notify)"
    curl -s "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
        -d "chat_id=${CHAT_ID}" \
        --data-urlencode "text=${text}" \
        -d "disable_notification=${notify}" 2>/dev/null >/dev/null || true
}

send_photo_file() {
    local file="$1"
    local caption="$2"
    [ -f "$file" ] || return 1
    log "  TG photo: $file ($caption)"
    curl -s "https://api.telegram.org/bot${BOT_TOKEN}/sendPhoto" \
        -F "chat_id=${CHAT_ID}" \
        -F "photo=@${file}" \
        -F "caption=${caption}" 2>/dev/null >/dev/null
}

send_photo_url() {
    local url="$1"
    local caption="$2"
    [ -n "$url" ] || return 1
    log "  TG photo(url): $url ($caption)"
    curl -s "https://api.telegram.org/bot${BOT_TOKEN}/sendPhoto" \
        -F "chat_id=${CHAT_ID}" \
        -F "photo=${url}" \
        -F "caption=${caption}" 2>/dev/null >/dev/null
}

# Extract first frame from HLS as preview
extract_frame_from_hls() {
    local url="$1"
    local out="$2"
    log "  ffmpeg extract: $url -> $out"
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

# Stripchat check: returns "online|URL|VIEWERS|SNAPSHOT|PREVIEW" or "offline"
# API does NOT have .stream.online — we infer online from .stream.url presence
check_stripchat() {
    local model="$1"
    local data
    data=$(curl -s --max-time 15 "https://go.xxxiijmp.com/api/models?modelsList=${model}&strict=1" 2>/dev/null || echo "")
    [ -z "$data" ] && { echo "offline"; return; }

    local status
    status=$(echo "$data" | jq -r '
        if (.count // 0) > 0 and (.models | length > 0) and (.models[0].stream.url // null) != null then
            "online|\(.models[0].stream.url)|\(.models[0].viewersCount // 0)|\(.models[0].snapshotUrl // "")|\(.models[0].previewUrl // "")"
        else "offline" end
    ' 2>/dev/null)
    [ -z "$status" ] && status="offline"
    echo "$status"
}

check_bongacams() {
    local model="$1"
    local amf_resp
    amf_resp=$(curl -s --max-time 15 -X POST 'https://bongacams.com/tools/amf.php?x-country=en' \
        -H 'User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36' \
        -H 'Origin: https://bongacams.com' \
        -H 'Referer: https://bongacams.com/' \
        -d "method=getRoomData&args[]=${model}&args[]=false" 2>/dev/null || echo "")

    if echo "$amf_resp" | grep -q '"status":"success"'; then
        local hls_url viewers
        hls_url=$(echo "$amf_resp" | grep -oP '"videoServerUrl":"[^"]*"' | head -1 | sed 's/"videoServerUrl":"//;s/"//')
        viewers=$(echo "$amf_resp" | grep -oP '"viewersCount":\d+' | head -1 | sed 's/"viewersCount"://')
        if [ -n "$hls_url" ]; then
            echo "online|${hls_url}/hls/stream_${model}/playlist.m3u8|${viewers:-0}||"
            return
        fi
    fi
    echo "offline"
}

# ---------- main ----------
log "=== check-models.sh start ==="
log "Models: $(awk -F'|' 'NF>=2 && $1 !~ /^#/' models.txt | tr '\n' ' ')"

# Load persistent state
PSTATE=$(load_state)
log "Persistent state: $PSTATE"

# Read models.txt
MODELS=()
while IFS='|' read -r model provider method; do
    [[ -z "$model" || "$model" =~ ^# ]] && continue
    model=$(echo "$model" | xargs)
    provider=$(echo "$provider" | xargs)
    [ -n "$FILTER_MODEL" ] && [ "$model" != "$FILTER_MODEL" ] && continue
    MODELS+=("$model|$provider")
done < models.txt

for entry in "${MODELS[@]}"; do
    model="${entry%|*}"
    provider="${entry#*|}"

    # If this model is currently being recorded (state file on this runner), skip
    if [ -f "${STATE_DIR}/state_${model}" ]; then
        log "[$model] skipping: state_$model exists on this runner"
        continue
    fi

    prev_state=$(echo "$PSTATE" | jq -r --arg m "$model" '.[$m] // "offline"' 2>/dev/null)
    [ -z "$prev_state" ] && prev_state="offline"
    log "[$model] prev_state=$prev_state provider=$provider"

    result="offline"
    case "$provider" in
        stripchat) result=$(check_stripchat "$model") ;;
        bongacams) result=$(check_bongacams "$model") ;;
        *) log "[$model] unknown provider '$provider', skipping"; continue ;;
    esac

    status=$(echo "$result" | cut -d'|' -f1)
    log "[$model] current status=$status result=$result"

    if [ "$status" = "online" ]; then
        hls_url=$(echo "$result" | cut -d'|' -f2)
        viewers=$(echo "$result" | cut -d'|' -f3)
        snapshot=$(echo "$result" | cut -d'|' -f4)
        preview=$(echo "$result" | cut -d'|' -f5)

        # Transition offline -> online: notify + dispatch recording
        if [ "$prev_state" != "online" ]; then
            log "[$model] TRANSITION offline -> online — sending notification + dispatching record"
            local_frame="${STATE_DIR}/preview_${model}.jpg"
            sent=0
            photo_url="${snapshot:-${preview}}"
            if [ -n "$photo_url" ] && [ "$photo_url" != "null" ] && [ "$photo_url" != "" ]; then
                send_photo_url "$photo_url" "🟢 ${model} online (${viewers} зр.)" && sent=1 || true
            fi
            if [ "$sent" -eq 0 ] && [ -n "$hls_url" ] && [ "$hls_url" != "null" ]; then
                if extract_frame_from_hls "$hls_url" "$local_frame"; then
                    publish_frame "$local_frame"
                    send_photo_file "$local_frame" "🟢 ${model} online (${viewers} зр.)" && sent=1 || true
                fi
            fi
            if [ "$sent" -eq 0 ]; then
                send_tg "🟢 ${model} online (${viewers} зр.)" "false"
            fi

            # Dispatch recording
            if [ -n "$hls_url" ] && [ "$hls_url" != "null" ] && [ -n "${GITHUB_TOKEN:-}" ]; then
                log "[$model] dispatching record workflow"
                curl -s -X POST -H "Authorization: Bearer ${GITHUB_TOKEN}" \
                    -H "Accept: application/vnd.github+json" \
                    "https://api.github.com/repos/${GITHUB_REPOSITORY}/actions/workflows/record.yml/dispatches" \
                    -d "{\"ref\":\"main\",\"inputs\":{\"model\":\"${model}\",\"provider\":\"${provider}\",\"hls_url\":\"${hls_url}\"}}" 2>/dev/null >/dev/null \
                    && log "[$model] record workflow dispatched" \
                    || log "[$model] record dispatch FAILED"
            fi
        else
            log "[$model] still online (no transition)"
        fi
        # Save current state
        PSTATE=$(update_state "$model" "online" "$PSTATE")
    else
        # offline
        if [ "$prev_state" = "online" ]; then
            log "[$model] TRANSITION online -> offline"
            send_tg "🔴 ${model} offline" "false"
        fi
        PSTATE=$(update_state "$model" "offline" "$PSTATE")
    fi
done

# Persist updated state
save_state "$PSTATE"
log "=== check-models.sh done ==="
