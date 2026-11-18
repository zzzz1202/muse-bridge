#!/usr/bin/env bash
# Muse bridge watch, Telegram edition (meta side): polls the public
# channel page https://t.me/s/<channel> and extracts message texts.
# The page is plain HTML with full message text (verified 2026-11-18:
# 20 messages, readable via curl, no auth). No secrets here; the script
# only detects new messages. The woken agent decrypts them with the
# shared passphrase file and reports. Channel username is read from
# ~/.muse-bridge/telegram-channel (no @ prefix).
#
# State: {"seen": ["<16-hex-hash>", ...]} — hashes of the messages
# currently visible on the page. A message whose hash is not in state
# is new. First run establishes the baseline silently.
set -euo pipefail
source "$HATCH_HOOK_RUNTIME"

CHANNEL="$(cat ~/.muse-bridge/telegram-channel 2>/dev/null || true)"
if [[ -z "$CHANNEL" ]]; then
  log "channel not configured" '{}'
  silent "telegram channel not configured"
fi

TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

if ! curl --fail --silent --show-error --max-time 15 -A "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36" "https://t.me/s/${CHANNEL}" -o "$TMP"; then
  log "fetch failed" '{"channel":"'"$CHANNEL"'"}'
  silent "fetch failed, will retry next poll"
fi

STATE="$(hook_state_get)"
DIFF="$(python3 - "$TMP" "$STATE" <<'PYEOF'
import sys, re, html, json, hashlib
state = json.loads(sys.argv[2]) if len(sys.argv) > 2 and sys.argv[2].strip() else {}
seen = set(state.get('seen', []))
baseline = 'seen' not in state
t = open(sys.argv[1], encoding='utf-8').read()
raw = re.findall(r'<div class="tgme_widget_message_text[^"]*"[^>]*>(.*?)</div>', t, re.S)
msgs = []
for x in raw:
    x = re.sub(r'<br\s*/?>', '\n', x)
    x = re.sub(r'<[^>]+>', '', x)
    x = html.unescape(x).strip()
    # Only bridge messages (skip channel service messages like "Channel created")
    if x and re.match(r'^from (meta|gongsi|shengxian) · to ', x):
        msgs.append(x)
hashes = [hashlib.sha256(m.encode()).hexdigest()[:16] for m in msgs]
new = [m for m, h in zip(msgs, hashes) if h not in seen]
print(json.dumps({'new': new, 'seen': hashes, 'baseline': baseline}, ensure_ascii=False))
PYEOF
)"

BASELINE="$(printf '%s' "$DIFF" | jq -r '.baseline')"
NEW_COUNT="$(printf '%s' "$DIFF" | jq -r '.new | length')"
SEEN_JSON="$(printf '%s' "$DIFF" | jq -c '{seen: .seen}')"

hook_state_set "$SEEN_JSON"

if [[ "$BASELINE" == "true" ]]; then
  silent "baseline established"
fi

if [[ "$NEW_COUNT" == "0" ]]; then
  silent "no change"
fi

PAYLOAD="$(printf '%s' "$DIFF" | jq -c '{messages: .new}')"
wake "new telegram bridge message" "$PAYLOAD"
