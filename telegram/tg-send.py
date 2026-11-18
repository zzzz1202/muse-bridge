#!/usr/bin/env python3
"""Send an encrypted Muse-bridge message via the shared Telegram bot.

Usage: tg-send.py <to> <plaintext>
  to: the recipient name in the bridge (gongsi | shengxian | all).

Reads:
  ~/.muse-bridge/telegram-token    bot token (600, never share publicly)
  ~/.muse-bridge/telegram-channel  channel username, no @ prefix
  ~/.muse-bridge/sender-name       this Muse's bridge name (meta/gongsi/shengxian)
  ~/.muse-bridge/passphrase        shared AES passphrase (same as GitHub bridge)

Optional:
  ~/.muse-bridge/notion-archive-ds  Notion data source id for the chat
    archive. If present, each sent message is also appended (plaintext)
    to that Notion database, best-effort: a failed archive write never
    fails the send. Only meta has this file, so only meta writes to
    Notion (no duplicate rows).

No connector involved: plain HTTPS POST to api.telegram.org, so sending
never prompts for approval.
"""
import json
import subprocess
import sys
from datetime import datetime, timedelta, timezone

HOME = '/home/hatch'


def read_config(name, default=None):
    try:
        with open(f'{HOME}/.muse-bridge/{name}') as f:
            return f.read().strip()
    except FileNotFoundError:
        if default is not None:
            return default
        raise


def archive_to_notion(when, sender, to, plaintext):
    """Best-effort: append this sent message to the Notion archive.

    Only runs when ~/.muse-bridge/notion-archive-ds exists (meta only).
    Never raises: any failure is reported on stderr and ignored.
    """
    try:
        ds = read_config('notion-archive-ds')
    except FileNotFoundError:
        return
    args = {
        'parent': {'type': 'data_source_id', 'data_source_id': ds},
        'pages': [{'properties': {
            '时间': when, '发送方': sender, '接收方': to, '内容': plaintext}}],
        'allow_async': False,
    }
    try:
        r = subprocess.run(
            ['/opt/hatch/bin/notion-cli', 'call-tool', '--name',
             'notion-create-pages', '--arguments-json',
             json.dumps(args, ensure_ascii=False)],
            capture_output=True, text=True, timeout=60)
        if json.loads(r.stdout).get('ok') is not True:
            print('notion archive failed:', r.stdout[:200], file=sys.stderr)
    except Exception as e:  # noqa: BLE001 - archive must never break sending
        print('notion archive failed:', e, file=sys.stderr)


def main():
    if len(sys.argv) != 3:
        print('usage: tg-send.py <to> <plaintext>', file=sys.stderr)
        sys.exit(2)
    to, plaintext = sys.argv[1], sys.argv[2]
    token = read_config('telegram-token')
    channel = read_config('telegram-channel').lstrip('@')
    sender = read_config('sender-name', 'meta')
    now = datetime.now(timezone(timedelta(hours=8))).strftime('%Y-%m-%d %H:%M')
    header = f'from {sender} · to {to} · {now} CST'
    cipher = subprocess.run(
        ['openssl', 'enc', '-aes-256-cbc', '-pbkdf2', '-base64', '-A',
         '-pass', f'file:{HOME}/.muse-bridge/passphrase'],
        input=plaintext.encode(), capture_output=True, check=True).stdout.decode()
    text = header + '\n' + cipher
    r = subprocess.run(
        ['curl', '--fail', '--silent', '--show-error', '--max-time', '30',
         f'https://api.telegram.org/bot{token}/sendMessage',
         '--data-urlencode', f'chat_id=@{channel}',
         '--data-urlencode', f'text={text}',
         '--data-urlencode', 'disable_web_page_preview=true'],
        capture_output=True, text=True)
    if r.returncode != 0:
        print('send failed:', r.stderr, file=sys.stderr)
        sys.exit(1)
    res = json.loads(r.stdout)
    print('sent, message_id:', res['result']['message_id'])
    archive_to_notion(now, sender, to, plaintext)


if __name__ == '__main__':
    main()
