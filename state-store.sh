#!/bin/bash
# Commits a local file to the 'state' branch via GitHub Contents API
# Usage: state-store.sh <local-file> <remote-path> [commit-msg]
set -euo pipefail

LOCAL_FILE="$1"
REMOTE_PATH="$2"
MSG="${3:-update ${REMOTE_PATH}}"

REPO="${GITHUB_REPOSITORY:-wpyddzktxt-spec/auto-recorder}"
BRANCH="${STATE_BRANCH:-state}"
TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}"

[ -z "$TOKEN" ] && { echo "ERROR: no token" >&2; exit 1; }
[ -f "$LOCAL_FILE" ] || { echo "ERROR: file not found: $LOCAL_FILE" >&2; exit 1; }

# Base64 encode content (no line wrap)
CONTENT=$(base64 -w 0 "$LOCAL_FILE" 2>/dev/null || base64 "$LOCAL_FILE" | tr -d '\n')

# Get current file SHA if it exists on the branch
EXISTING=$(curl -sf -H "Authorization: Bearer ${TOKEN}" \
  -H "Accept: application/vnd.github+json" \
  "https://api.github.com/repos/${REPO}/contents/${REMOTE_PATH}?ref=${BRANCH}" 2>/dev/null || echo "")
SHA=$(echo "$EXISTING" | jq -r '.sha // ""' 2>/dev/null)

# Build JSON payload using jq for safe escaping
if [ -n "$SHA" ] && [ "$SHA" != "null" ]; then
  PAYLOAD=$(jq -n --arg msg "$MSG" --arg c "$CONTENT" --arg s "$SHA" --arg b "$BRANCH" \
    '{message: $msg, content: $c, sha: $s, branch: $b}')
else
  PAYLOAD=$(jq -n --arg msg "$MSG" --arg c "$CONTENT" --arg b "$BRANCH" \
    '{message: $msg, content: $c, branch: $b}')
fi

RESULT=$(curl -s -X PUT \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Accept: application/vnd.github+json" \
  -H "Content-Type: application/json" \
  "https://api.github.com/repos/${REPO}/contents/${REMOTE_PATH}" \
  -d "$PAYLOAD")

if echo "$RESULT" | jq -e '.commit.id // .content.sha' >/dev/null 2>&1; then
  echo "OK: committed ${REMOTE_PATH} to ${BRANCH}"
else
  echo "WARN: commit may have failed" >&2
  echo "$RESULT" | head -c 300 >&2
  echo "" >&2
fi
