#!/usr/bin/env bash
# Поставить реакцию на сообщение — индикатор состояния задачи.
#
# Бот держит на сообщении ровно одну реакцию, и новая заменяет прежнюю.
# Поэтому реакция работает как статус, а не как накопление меток:
#   👀 увидел · 👨‍💻 в работе · 🤔 нужен ответ · 🏆 готово
#
# Использование:
#   tg-react.sh <message_id> <эмодзи>
#   tg-react.sh <message_id> --clear
#
# Telegram принимает не любые эмодзи, а только из своего набора.
# Недопустимая вернёт REACTION_INVALID.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/config.sh"

MID="${1:-}"
EMOJI="${2:-}"
[ -n "$MID" ] && [ -n "$EMOJI" ] || { echo "использование: tg-react.sh <message_id> <эмодзи|--clear>" >&2; exit 1; }

if [ "$EMOJI" = "--clear" ]; then
  REACTION='[]'
else
  REACTION="$(printf '%s' "$EMOJI" | python3 -c 'import json,sys; print(json.dumps([{"type":"emoji","emoji":sys.stdin.read().strip()}], ensure_ascii=False))')"
fi

tg_api setMessageReaction \
  -X POST \
  --data-urlencode "chat_id=${TG_CHAT_ID}" \
  --data-urlencode "message_id=${MID}" \
  --data-urlencode "reaction=${REACTION}" \
| python3 -c "
import json,sys
d=json.load(sys.stdin)
if d.get('ok'):
    print('ok')
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
