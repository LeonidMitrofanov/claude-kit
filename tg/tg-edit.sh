#!/usr/bin/env bash
# Изменить текст ранее отправленного сообщения бота.
#
# Главное применение — закреплённое сообщение с правилами темы: оно правится
# на месте, и закрепление не нужно переделывать.
#
# Использование:
#   tg-edit.sh <message_id> <новый текст…>
#   echo "текст" | tg-edit.sh <message_id>
#
# Чужие сообщения править нельзя — только свои.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/config.sh"

MID="${1:-}"; shift || true
[ -n "$MID" ] || { echo "использование: tg-edit.sh <message_id> <текст>" >&2; exit 1; }

TEXT="${*:-}"
[ -n "$TEXT" ] || TEXT="$(cat)"
[ -n "$TEXT" ] || { echo "пустой текст" >&2; exit 1; }

tg_api editMessageText \
  -X POST \
  --data-urlencode "chat_id=${TG_CHAT_ID}" \
  --data-urlencode "message_id=${MID}" \
  --data-urlencode "text=${TEXT}" \
| python3 -c "
import json,sys
d=json.load(sys.stdin)
if d.get('ok'):
    print('изменено')
else:
    # Провал сообщается кодом возврата и stderr, а не строкой в общий поток.
    # Иначе он неотличим от успеха для вызывающего: «скрипт && дальше» идёт
    # дальше, set -e не срабатывает, а при пакетной постановке реакций одна
    # ошибка среди десятка «ok» проезжает незамеченной. На реакциях это дороже
    # всего: реакция — единственный признак, по которому владелец видит, что
    # сообщение дошло, и молча провалившаяся читается им как «не замечено».
    print('ОШИБКА: ' + str(d.get('description')), file=sys.stderr)
    sys.exit(1)
"
