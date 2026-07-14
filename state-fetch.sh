#!/bin/bash
# Fetches a file from the 'state' branch via GitHub Contents API (works for private repos)
# Usage: state-fetch.sh <remote-path> <local-save-path>
set -euo pipefail

REMOTE_PATH="$1"
LOCAL_FILE="$2"
REPO="${GITHUB_REPOSITORY:-wpyddzktxt-spec/auto-recorder}"
BRANCH="${STATE_BRANCH:-state}"
TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}"

[ -z "$TOKEN" ] && { echo "WARN: no token for fetch" >&2; exit 1; }

URL="https://api.github.com/repos/${REPO}/contents/${REMOTE_PATH}?ref=${BRANCH}"

# Use python to download + base64 decode in one step
GITHUB_TOKEN="$TOKEN" python3 - "$URL" "$LOCAL_FILE" << 'PYEOF'
import sys, os, json, urllib.request, base64
url, local = sys.argv[1], sys.argv[2]
token = os.environ.get("GITHUB_TOKEN", "")
req = urllib.request.Request(url, headers={
    "Authorization": f"Bearer {token}",
    "Accept": "application/vnd.github+json",
    "User-Agent": "auto-recorder"
})
try:
    with urllib.request.urlopen(req, timeout=20) as r:
        data = json.loads(r.read())
        content_b64 = data.get("content", "")
        if data.get("encoding") == "base64" and content_b64:
            raw = base64.b64decode(content_b64)
            with open(local, "wb") as f:
                f.write(raw)
            print(f"OK: fetched {len(raw)} bytes -> {local}")
            sys.exit(0)
        else:
            print(f"WARN: unexpected encoding {data.get('encoding')}", file=sys.stderr)
            sys.exit(1)
except urllib.error.HTTPError as e:
    print(f"WARN: HTTP {e.code} for {REMOTE_PATH}", file=sys.stderr)
    sys.exit(1)
except Exception as e:
    print(f"WARN: {e}", file=sys.stderr)
    sys.exit(1)
PYEOF
