#!/bin/bash
# Fetches a file from the 'state' branch as raw bytes
# Usage: state-fetch.sh <remote-path> <local-save-path>
set -euo pipefail

REMOTE_PATH="$1"
LOCAL_FILE="$2"
REPO="${GITHUB_REPOSITORY:-wpyddzktxt-spec/auto-recorder}"
BRANCH="${STATE_BRANCH:-state}"
URL="https://raw.githubusercontent.com/${REPO}/${BRANCH}/${REMOTE_PATH}"

HTTP_CODE=$(curl -sf -L --max-time 20 -o "$LOCAL_FILE" -w "%{http_code}" "$URL" 2>/dev/null || echo "000")
if [ "$HTTP_CODE" = "200" ] && [ -s "$LOCAL_FILE" ]; then
  echo "OK: fetched ${REMOTE_PATH} -> ${LOCAL_FILE}"
  exit 0
else
  rm -f "$LOCAL_FILE"
  echo "WARN: fetch failed (HTTP $HTTP_CODE) for ${REMOTE_PATH}" >&2
  exit 1
fi
