#!/usr/bin/env bash
# Закрепить или открепить сообщение.
#
# В теме форума закрепление показывается вверху именно этой темы, поэтому
# у каждой может быть своё правило в закрепе.
#
# Использование:
#   tg-pin.sh <message_id>            закрепить без уведомления
#   tg-pin.sh <message_id> --notify   закрепить с уведомлением
#   tg-pin.sh <message_id> --unpin    открепить

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/config.sh"

MID="${1:-}"
MODE="${2:-}"
[ -n "$MID" ] || { echo "использование: tg-pin.sh <message_id> [--notify|--unpin]" >&2; exit 1; }

if [ "$MODE" = "--unpin" ]; then
  method=unpinChatMessage
  extra=()
else
  method=pinChatMessage
  # По умолчанию тихо: закрепление правил не повод будить уведомлением.
  if [ "$MODE" = "--notify" ]; then extra=(-d disable_notification=false)
  else extra=(-d disable_notification=true); fi
fi

tg_api "$method" \
  -X POST \
  --data-urlencode "chat_id=${TG_CHAT_ID}" \
  --data-urlencode "message_id=${MID}" \
  "${extra[@]}" \
| python3 -c "
import json,sys
d=json.load(sys.stdin)
if d.get('ok'):
    print('готово')
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
