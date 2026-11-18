#!/usr/bin/env python3
"""Read the Telegram bridge local archive, decrypted.

Usage:
    tg-archive-read.py [N]        print the last N messages (default: all)
    tg-archive-read.py --from gongsi [N]
    tg-archive-read.py --to all [N]

The archive is ~/workspace/slack-muse-bridge/telegram-archive.md:
two-line blocks (header + base64 cipher), separated by blank lines.
Decryption uses the shared passphrase in ~/.muse-bridge/passphrase.
"""
import subprocess
import sys
from pathlib import Path

ARCHIVE = Path('/home/hatch/workspace/slack-muse-bridge/telegram-archive.md')
PASSPHRASE = '/home/hatch/.muse-bridge/passphrase'


def decrypt(cipher: str) -> str:
    r = subprocess.run(
        ['openssl', 'enc', '-d', '-aes-256-cbc', '-pbkdf2', '-base64', '-A',
         '-pass', f'file:{PASSPHRASE}'],
        input=cipher.encode(), capture_output=True)
    if r.returncode != 0:
        return '[decrypt failed]'
    return r.stdout.decode('utf-8', errors='replace')


def main() -> None:
    args = sys.argv[1:]
    n = None
    from_filter = None
    to_filter = None
    i = 0
    while i < len(args):
        if args[i] == '--from' and i + 1 < len(args):
            from_filter = args[i + 1]
            i += 2
        elif args[i] == '--to' and i + 1 < len(args):
            to_filter = args[i + 1]
            i += 2
        elif args[i].isdigit():
            n = int(args[i])
            i += 1
        else:
            print(f'unknown argument: {args[i]}', file=sys.stderr)
            sys.exit(2)

    if not ARCHIVE.exists():
        print('archive is empty (no messages archived yet)')
        return

    blocks = [b.strip() for b in ARCHIVE.read_text().split('\n\n') if b.strip()]
    msgs = []
    for b in blocks:
        lines = b.split('\n')
        if len(lines) < 2:
            continue
        header, cipher = lines[0], lines[1]
        if from_filter and not header.startswith(f'from {from_filter} '):
            continue
        if to_filter and f'· to {to_filter} ·' not in header:
            continue
        msgs.append((header, decrypt(cipher)))

    if n is not None:
        msgs = msgs[-n:]

    if not msgs:
        print('no matching messages')
        return
    for header, text in msgs:
        print(header)
        print(text)
        print()


if __name__ == '__main__':
    main()
