with open('.github/workflows/check-and-dispatch.yml', 'r') as f:
    content = f.read()

# Replace the moonmaiden section with HLS-content-based detection
old = '''      - name: Check moonmaiden (BongaCams)
        run: |
          echo "=== moonmaiden ==="
          # v6.34: mybro.tv API (AMF Cloudflare-blocked)
          MN_JSON=$(curl -s --max-time 8 'https://mybro.tv/api/v1/models/alias/moonmaiden_' \\
            -H 'User-Agent: Mozilla/5.0' 2>/dev/null || echo '{}')
          MN_IS_ONLINE=$(echo "$MN_JSON" | python3 -c 'import sys,json; d=json.load(sys.stdin); print((d.get("model") or {}).get("isOnline") or False)' 2>/dev/null)
          if [ "$MN_IS_ONLINE" != "True" ]; then
            echo "Offline"
            exit 0
          fi
          MN_HLS=$(echo "$MN_JSON" | python3 -c 'import sys,json; d=json.load(sys.stdin); print((d.get("model") or {}).get("streamUrl") or "")' 2>/dev/null)
          if [ -z "$MN_HLS" ] || [ "$MN_HLS" = "None" ]; then
            echo "No HLS"
            exit 0
          fi
          if ! curl -sIf --max-time 10 "$MN_HLS" >/dev/null 2>&1; then
            echo "HLS unreachable"
            exit 0
          fi
          echo "HLS OK"
          QUEUED=$(curl -s -H "Authorization: Bearer ${GITHUB_TOKEN}" \\
            -H "Accept: application/vnd.github+json" \\
            "https://api.github.com/repos/${GITHUB_REPOSITORY}/actions/workflows/record.yml/runs?status=queued&per_page=5" 2>/dev/null | \\
            jq -r '.total_count // 0' 2>/dev/null || echo 0)
          if [ "$QUEUED" -gt 0 ] 2>/dev/null; then
            echo "$QUEUED queued — skip"
            exit 0
          fi
          curl -s -X POST \\
            -H "Authorization: Bearer ${GITHUB_TOKEN}" \\
            -H "Accept: application/vnd.github+json" \\
            "https://api.github.com/repos/${GITHUB_REPOSITORY}/actions/workflows/record.yml/dispatches" \\
            -d "$(jq -n --arg m "moonmaiden" --arg p "bongacams" --arg h "$MN_HLS" --arg r "main" \\
              '{ref:$r, inputs:{model:$m, provider:$p, hls_url:$h}}')" 2>/dev/null
          echo "Done"
          curl -s "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \\
            -d "chat_id=${CHAT_ID}" \\
            --data-urlencode "text=🟢 moonmaiden online" 2>/dev/null >/dev/null || true'''

new = '''      - name: Check moonmaiden (BongaCams)
        run: |
          echo "=== moonmaiden ==="
          # v6.35: get HLS from mybro.tv, check if playlist has segments (isOnline is unreliable)
          MN_JSON=$(curl -s --max-time 8 'https://mybro.tv/api/v1/models/alias/moonmaiden_' \\
            -H 'User-Agent: Mozilla/5.0' 2>/dev/null || echo '{}')
          MN_HLS=$(echo "$MN_JSON" | python3 -c 'import sys,json; d=json.load(sys.stdin); print((d.get("model") or {}).get("streamUrl") or "")' 2>/dev/null)
          if [ -z "$MN_HLS" ] || [ "$MN_HLS" = "None" ] || [ "$MN_HLS" = "" ]; then
            echo "No HLS URL"
            exit 0
          fi
          # Check if playlist has actual video segments (EXTINF lines), not just header
          MN_PLAYLIST=$(curl -s --max-time 8 "$MN_HLS" 2>/dev/null || echo "")
          MN_SEGMENTS=$(echo "$MN_PLAYLIST" | grep -c '#EXTINF' 2>/dev/null || echo 0)
          if [ "$MN_SEGMENTS" -eq 0 ]; then
            echo "HLS empty (no segments, stream not active)"
            exit 0
          fi
          echo "LIVE! ($MN_SEGMENTS segments in playlist)"
          QUEUED=$(curl -s -H "Authorization: Bearer ${GITHUB_TOKEN}" \\
            -H "Accept: application/vnd.github+json" \\
            "https://api.github.com/repos/${GITHUB_REPOSITORY}/actions/workflows/record.yml/runs?status=queued&per_page=5" 2>/dev/null | \\
            jq -r '.total_count // 0' 2>/dev/null || echo 0)
          if [ "$QUEUED" -gt 0 ] 2>/dev/null; then
            echo "$QUEUED queued — skip"
            exit 0
          fi
          curl -s -X POST \\
            -H "Authorization: Bearer ${GITHUB_TOKEN}" \\
            -H "Accept: application/vnd.github+json" \\
            "https://api.github.com/repos/${GITHUB_REPOSITORY}/actions/workflows/record.yml/dispatches" \\
            -d "$(jq -n --arg m "moonmaiden" --arg p "bongacams" --arg h "$MN_HLS" --arg r "main" \\
              '{ref:$r, inputs:{model:$m, provider:$p, hls_url:$h}}')" 2>/dev/null
          echo "Done"
          curl -s "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \\
            -d "chat_id=${CHAT_ID}" \\
            --data-urlencode "text=🟢 moonmaiden online" 2>/dev/null >/dev/null || true'''

if old in content:
    content = content.replace(old, new)
    print("✓ Replaced")
else:
    print("⚠ Full block not found, trying regex...")
    import re
    # Try to find the moonmaiden block and replace
    pattern = r'      - name: Check moonmaiden \(BongaCams\).*?(?=\n      - name: Check Maddy)'
    if re.search(pattern, content, re.DOTALL):
        content = re.sub(pattern, new, content, flags=re.DOTALL)
        print("✓ Replaced via regex")
    else:
        print("⚠ Can't find block")

with open('.github/workflows/check-and-dispatch.yml', 'w') as f:
    f.write(content)
