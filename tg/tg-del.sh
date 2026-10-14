#!/usr/bin/env bash
# Удалить сообщение бота.
#
# Зачем отдельный скрипт, если есть tg_api: в auto-режиме попытка прочитать
# конфиг или файл токена, чтобы собрать запрос руками, выглядит как извлечение
# секрета — и отклоняется правильно. Токен сессии видеть не нужно: его читает
# функция кита внутри своего подпроцесса. Отдельная команда с понятным именем
# проходит как обычный вызов скрипта проекта.
#
# Ограничения Telegram, не наши:
#   • своё сообщение бот удаляет в первые 48 часов, дальше нельзя;
#   • чужие — только с правом «удалять сообщения», то есть будучи администратором;
#   • служебное сообщение о создании темы не удаляется никогда.
#
# Использование:
#   tg-del.sh <message_id> [<message_id>…]
#   tg-del.sh <message_id> --chat <номер>
#
# Несколько номеров удаляются по одному, а не deleteMessages: пакетный метод
# падает целиком, если хотя бы одно сообщение старше двух суток, и не говорит,
# какое именно. Поштучно видно, что ушло, а что нет.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/config.sh"

MIDS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --chat) TG_CHAT_ID="${2:-}"; shift 2 ;;
    *)      MIDS+=("$1"); shift ;;
  esac
done

[ ${#MIDS[@]} -gt 0 ] || {
  echo "использование: tg-del.sh <message_id> [<message_id>…] [--chat <номер>]" >&2
  exit 1
}

oshibok=0
for mid in "${MIDS[@]}"; do
  otvet="$(tg_api deleteMessage \
    -X POST \
    --data-urlencode "chat_id=${TG_CHAT_ID}" \
    --data-urlencode "message_id=${mid}")" || { oshibok=$((oshibok+1)); continue; }

  printf '%s' "$otvet" | MID="$mid" python3 -c "
import json, os, sys
mid = os.environ['MID']
d = json.load(sys.stdin)
if d.get('ok'):
    print(f'{mid}: удалено')
else:
    pochemu = str(d.get('description'))
    # Самая частая причина — возраст сообщения, и формулировка Telegram
    # («message can't be deleted») этого не называет. Без подсказки время
    # уходит на поиск несуществующей проблемы с правами.
    if \"can't be deleted\" in pochemu:
        pochemu += ' (скорее всего старше 48 часов либо чужое, а прав администратора нет)'
    print(f'{mid}: ОШИБКА: {pochemu}', file=sys.stderr)
    sys.exit(1)
" || oshibok=$((oshibok+1))
done

# Код возврата говорит об итоге: при пакетном удалении одна молча провалившаяся
# строка среди десятка «удалено» проезжает незамеченной.
[ "$oshibok" -eq 0 ] || exit 1
