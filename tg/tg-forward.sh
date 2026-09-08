#!/usr/bin/env bash
# Переслать сообщение группы в её же тему, сохранив вложения и авторство.
#
# Владелец кидает материалы туда, где идёт разговор, а лежать они должны в теме
# своего предмета. Пересылка переносит их как есть — в отличие от повторной
# отправки файлом, которая теряет и подпись «переслано от», и исходный размер.
#
# Использование:
#   tg-forward.sh <topic_id> <message_id…>
#
# Сообщения пересылаются по одному и в том порядке, в каком перечислены:
# forwardMessages пересылает пачкой, но склеивает их в альбом и путает порядок.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/config.sh"

TOPIC="${1:-}"; shift || true
[ -n "$TOPIC" ] && [ "$#" -gt 0 ] || { echo "использование: tg-forward.sh <topic_id> <message_id…>" >&2; exit 1; }

for MID in "$@"; do
  tg_api forwardMessage \
    -X POST \
    --data-urlencode "chat_id=${TG_CHAT_ID}" \
    --data-urlencode "from_chat_id=${TG_CHAT_ID}" \
    --data-urlencode "message_thread_id=${TOPIC}" \
    --data-urlencode "message_id=${MID}" \
  | python3 -c "
import json,sys
d=json.load(sys.stdin)
if d.get('ok'):
    print('#${MID} → тема ${TOPIC}, новое сообщение: %s' % d['result']['message_id'])
else:
    print('#${MID}: ОШИБКА '+str(d.get('description')), file=sys.stderr)
    sys.exit(1)
"
done
