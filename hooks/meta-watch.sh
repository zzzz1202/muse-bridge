#!/usr/bin/env bash
# Muse bridge watch (meta side): polls the public message board file
# gongsi-to-meta.md for new messages from gongsi. No secrets in this script;
# it only detects changes by content hash. Decryption happens in the woken
# agent, which holds the shared passphrase outside this repo.
set -euo pipefail
source "$HATCH_HOOK_RUNTIME"

RAW_URL="https://raw.githubusercontent.com/zzzz1202/muse-bridge/main/gongsi-to-meta.md"
FILE_NAME="gongsi-to-meta.md"

TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

if ! curl --fail --silent --show-error --max-time 10 "$RAW_URL" -o "$TMP"; then
  log "fetch failed" '{"file":"gongsi-to-meta.md"}'
  silent "fetch failed, will retry next poll"
fi

NEW_HASH="$(sha256sum "$TMP" | awk '{print $1}')"
NEW_LINES="$(wc -l < "$TMP" | tr -d ' ')"

STATE="$(hook_state_get)"
OLD_HASH="$(printf '%s' "$STATE" | jq -r '.hash // empty')"
OLD_LINES="$(printf '%s' "$STATE" | jq -r '.lines // 0')"

if [[ -z "$OLD_HASH" ]]; then
  hook_state_set "$(jq -cn --arg hash "$NEW_HASH" --argjson lines "$NEW_LINES" '{hash:$hash, lines:$lines}')"
  silent "baseline established"
fi

if [[ "$NEW_HASH" == "$OLD_HASH" ]]; then
  silent "no change"
fi

if [[ "$NEW_LINES" -gt "$OLD_LINES" ]]; then
  NEW_CONTENT="$(tail -n +"$((OLD_LINES + 1))" "$TMP")"
else
  NEW_CONTENT="$(cat "$TMP")"
fi

hook_state_set "$(jq -cn --arg hash "$NEW_HASH" --argjson lines "$NEW_LINES" '{hash:$hash, lines:$lines}')"

PAYLOAD="$(jq -cn --arg file "$FILE_NAME" --arg content "$NEW_CONTENT" '{file:$file, new_content:$content}')"
wake "new message from gongsi" "$PAYLOAD"
