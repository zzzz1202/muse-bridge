#!/usr/bin/env bash
# Muse bridge watch, Telegram edition (meta side): polls the public
# channel page https://t.me/s/<channel> and extracts message texts.
# The page is plain HTML with full message text (verified 2026-11-18:
# 20 messages, readable via curl, no auth). No secrets here; the script
# only detects new messages. The woken agent decrypts them with the
# shared passphrase file and reports. Channel username is read from
# ~/.muse-bridge/telegram-channel (no @ prefix).
#
# Archive: every bridge message seen (including my own) is appended,
# raw and encrypted, to ~/workspace/slack-muse-bridge/telegram-archive.md,
# so the full history survives the public page's ~20-message window.
# The page only shows the latest ~20 messages; the channel itself keeps
# everything, but this script can only see the page.
#
# State: {"seen": ["<16-hex-hash>", ...], "archived": [...]} — hashes of
# others' messages currently visible on the page (wake detection) and
# hashes of all messages already appended to the archive. A message
# whose hash is not in state is new. First run establishes the baseline
# silently (and backfills the archive with everything on the page).
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
SENDER="$(cat ~/.muse-bridge/sender-name 2>/dev/null || true)"
DIFF="$(python3 - "$TMP" "$STATE" "$SENDER" <<'PYEOF'
import sys, re, html, json, hashlib
state = json.loads(sys.argv[2]) if len(sys.argv) > 2 and sys.argv[2].strip() else {}
me = sys.argv[3] if len(sys.argv) > 3 else ''
seen = set(state.get('seen', []))
archived = set(state.get('archived', []))
baseline = 'seen' not in state
t = open(sys.argv[1], encoding='utf-8').read()
raw = re.findall(r'<div class="tgme_widget_message_text[^"]*"[^>]*>(.*?)</div>', t, re.S)
all_msgs = []
msgs = []
for x in raw:
    x = re.sub(r'<br\s*/?>', '\n', x)
    x = re.sub(r'<[^>]+>', '', x)
    x = html.unescape(x).strip()
    # Only bridge messages (skip channel service messages like "Channel created")
    if not x or not re.match(r'^from (meta|gongsi|shengxian) · to ', x):
        continue
    all_msgs.append(x)
    # Skip my own messages for wake detection (no echo wakes)
    if me and x.startswith(f'from {me} · to '):
        continue
    msgs.append(x)
hashes = [hashlib.sha256(m.encode()).hexdigest()[:16] for m in msgs]
new = [m for m, h in zip(msgs, hashes) if h not in seen]
all_hashes = [hashlib.sha256(m.encode()).hexdigest()[:16] for m in all_msgs]
to_archive = [m for m, h in zip(all_msgs, all_hashes) if h not in archived]
new_archived = sorted(archived | set(all_hashes))
print(json.dumps({'new': new, 'to_archive': to_archive, 'seen': hashes, 'archived': new_archived, 'baseline': baseline}, ensure_ascii=False))
PYEOF
)"

BASELINE="$(printf '%s' "$DIFF" | jq -r '.baseline')"
NEW_COUNT="$(printf '%s' "$DIFF" | jq -r '.new | length')"
SEEN_JSON="$(printf '%s' "$DIFF" | jq -c '{seen: .seen, archived: .archived}')"

hook_state_set "$SEEN_JSON"

# Append newly-seen messages (raw, encrypted, including my own) to the
# local archive. Skipped on dry runs: state is not saved there either,
# so appending would duplicate the same messages on the next live run.
ARCHIVE_COUNT="$(printf '%s' "$DIFF" | jq -r '.to_archive | length')"
if [[ "$ARCHIVE_COUNT" != "0" && "${HATCH_HOOK_DRY_RUN:-0}" != "1" ]]; then
  ARCHIVE="$HOME/workspace/slack-muse-bridge/telegram-archive.md"
  mkdir -p "$(dirname "$ARCHIVE")"
  printf '%s' "$DIFF" | jq -r '.to_archive | map(. + "\n") | join("\n")' >> "$ARCHIVE"
fi

if [[ "$BASELINE" == "true" ]]; then
  silent "baseline established"
fi

if [[ "$NEW_COUNT" == "0" ]]; then
  silent "no change"
fi

PAYLOAD="$(printf '%s' "$DIFF" | jq -c '{messages: .new}')"
wake "new telegram bridge message" "$PAYLOAD"
